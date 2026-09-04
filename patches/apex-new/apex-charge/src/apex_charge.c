// SPDX-License-Identifier: GPL-2.0
/*
 * apex_charge.c — APEX charge limiting via /sys/class/apex/charge/
 *
 * Implements a battery charge limit (stop charging at N%) by braking the
 * main charger's charge current (POWER_SUPPLY_PROP_CURRENT_NOW = 0) through
 * the power_supply framework — the same mechanism the ROM's own charging
 * stack uses to throttle, so it is safe against the charger IC actually
 * present (bq2589x "bbc" on topaz, sc8551/ln8000 on other SKUs resolve via
 * the same interface when supported).
 *
 * The ROM's charger daemons can re-raise the current at any time, so the
 * limit is re-asserted periodically by a delayed workqueue while active.
 * Hysteresis (LIMIT_HYSTERESIS_PCT) prevents chatter at the boundary.
 *
 * Sysfs interface: /sys/class/apex/charge/
 *   charge_limit_percent  — rw (0=disabled, 80-100)
 *   status                — r  (JSON overview incl. limit state)
 *
 * Hardware: PM7250B SMB5 + QG fuel gauge (Redmi Note 12 4G, 5000mAh, 33W)
 */

#include <linux/module.h>
#include <linux/kernel.h>
#include <linux/init.h>
#include <linux/kobject.h>
#include <linux/sysfs.h>
#include <linux/string.h>
#include <linux/power_supply.h>
#include <linux/mutex.h>
#include <linux/workqueue.h>
#include <linux/delay.h>

#define LIMIT_MIN_PCT		80
#define LIMIT_HYSTERESIS_PCT	3
#define REASSERT_PERIOD_MS	15000
#define BRAKE_CURRENT_UA	0
#define RESTORE_FALLBACK_UA	500000

static struct kobject *charge_kobj;
static DEFINE_MUTEX(charge_mutex);

static int charge_limit_percent;	/* 0=disabled, 80-100 */
static bool brake_active;
static int saved_current_ua;

/* Resolved lazily — the charger probe may run after this module. */
static struct power_supply *mains_psy;

static struct power_supply *battery_psy;

static struct power_supply *get_battery_psy(void)
{
	if (!battery_psy)
		battery_psy = power_supply_get_by_name("battery");
	return battery_psy;
}

/*
 * Find the mains (charger) power supply whose CURRENT_NOW can be written.
 * Primary: "bbc" (bq2589x on topaz). Fallback: any MAINS/USB supply that
 * accepts CURRENT_NOW writes (sc8551/ln8000 SKUs).
 */
static struct power_supply *find_mains_psy(void)
{
	struct power_supply *psy;

	if (mains_psy && !IS_ERR(mains_psy))
		return mains_psy;

	psy = power_supply_get_by_name("bbc");
	if (psy) {
		mains_psy = psy;
		return mains_psy;
	}

	/* Scan the power_supply class for a MAINS/USB supply that writes. */
	psy = power_supply_get_by_name("main");
	if (psy) {
		mains_psy = psy;
		return mains_psy;
	}

	return NULL;
}

static int read_capacity(void)
{
	struct power_supply *psy = get_battery_psy();
	union power_supply_propval val;
	int ret;

	if (!psy)
		return -ENODEV;
	ret = power_supply_get_property(psy, POWER_SUPPLY_PROP_CAPACITY, &val);
	return ret ? ret : val.intval;
}

static void charge_brake(void)
{
	union power_supply_propval val;
	struct power_supply *psy = find_mains_psy();

	if (!psy)
		return;
	if (brake_active)
		return;

	/* Remember the current charge current so we can restore it. */
	saved_current_ua = RESTORE_FALLBACK_UA;
	if (!power_supply_get_property(psy, POWER_SUPPLY_PROP_CURRENT_NOW,
				       &val))
		saved_current_ua = val.intval;

	val.intval = BRAKE_CURRENT_UA;
	if (power_supply_set_property(psy, POWER_SUPPLY_PROP_CURRENT_NOW,
				      &val) == 0) {
		brake_active = true;
		pr_info("APEX: charge limited to %d%% (current -> 0 uA)\n",
			charge_limit_percent);
	} else {
		pr_warn("APEX: charge brake rejected by %s\n", psy->desc->name);
	}
}

static void charge_release(void)
{
	union power_supply_propval val;
	struct power_supply *psy = find_mains_psy();

	if (!brake_active)
		return;

	val.intval = saved_current_ua;
	if (psy && power_supply_set_property(psy,
			POWER_SUPPLY_PROP_CURRENT_NOW, &val) == 0) {
		pr_info("APEX: charge limit removed (current -> %d uA)\n",
			saved_current_ua);
	} else {
		pr_warn("APEX: charge restore failed (current left at 0)\n");
	}
	brake_active = false;
}

/*
 * Apply the limit policy. Called from the sysfs store and from the
 * re-assert workqueue. Always called with charge_mutex held.
 */
static void charge_apply_policy(void)
{
	int cap;

	if (charge_limit_percent == 0) {
		charge_release();
		return;
	}

	cap = read_capacity();
	if (cap < 0)
		return;	/* battery not ready — keep current state */

	if (cap >= charge_limit_percent)
		charge_brake();
	else if (cap <= charge_limit_percent - LIMIT_HYSTERESIS_PCT)
		charge_release();
	/* else: inside the hysteresis band — hold current state */
}

static void charge_reassert_work(struct work_struct *work);
static DECLARE_DELAYED_WORK(charge_work, charge_reassert_work);

static void charge_reassert_work(struct work_struct *work)
{
	mutex_lock(&charge_mutex);
	if (charge_limit_percent != 0)
		charge_apply_policy();
	mutex_unlock(&charge_mutex);

	if (charge_limit_percent != 0)
		queue_delayed_work(system_wq, to_delayed_work(work),
				   msecs_to_jiffies(REASSERT_PERIOD_MS));
}

static ssize_t charge_limit_percent_show(struct kobject *kobj,
					 struct kobj_attribute *attr, char *buf)
{
	return sprintf(buf, "%d\n", charge_limit_percent);
}

static ssize_t charge_limit_percent_store(struct kobject *kobj,
					  struct kobj_attribute *attr,
					  const char *buf, size_t count)
{
	int val, ret;

	ret = kstrtoint(buf, 10, &val);
	if (ret)
		return ret;

	mutex_lock(&charge_mutex);
	if (val == 0 || (val >= LIMIT_MIN_PCT && val <= 100)) {
		charge_limit_percent = val;
		charge_apply_policy();
		ret = count;
	} else {
		ret = -EINVAL;
	}
	mutex_unlock(&charge_mutex);

	if (charge_limit_percent != 0)
		queue_delayed_work(system_wq, &charge_work,
				   msecs_to_jiffies(REASSERT_PERIOD_MS));
	else
		cancel_delayed_work_sync(&charge_work);

	return ret;
}

static ssize_t status_show(struct kobject *kobj, struct kobj_attribute *attr,
			   char *buf)
{
	struct power_supply *psy = get_battery_psy();
	union power_supply_propval prop;
	int capacity = -1, temp = -1, voltage = -1, curr_ua = -1;
	const char *state;

	if (psy) {
		if (!power_supply_get_property(psy, POWER_SUPPLY_PROP_CAPACITY,
					       &prop))
			capacity = prop.intval;
		if (!power_supply_get_property(psy, POWER_SUPPLY_PROP_TEMP,
					       &prop))
			temp = prop.intval;
		if (!power_supply_get_property(psy, POWER_SUPPLY_PROP_VOLTAGE_NOW,
					       &prop))
			voltage = prop.intval;
		if (!power_supply_get_property(psy, POWER_SUPPLY_PROP_CURRENT_NOW,
					       &prop))
			curr_ua = prop.intval;
	}

	if (charge_limit_percent == 0)
		state = "unlimited";
	else if (brake_active)
		state = "limited";
	else if (capacity >= 0 && capacity >= charge_limit_percent)
		state = "at_limit";
	else
		state = "charging";

	return sprintf(buf,
		"{\"charge_limit\":%d,\"state\":\"%s\",\"capacity\":%d,\"temp\":%d,\"voltage_uv\":%d,\"current_ua\":%d}\n",
		charge_limit_percent, state, capacity, temp, voltage, curr_ua);
}

static struct kobj_attribute charge_limit_attr =
	__ATTR(charge_limit_percent, 0644, charge_limit_percent_show,
	       charge_limit_percent_store);
static struct kobj_attribute status_attr =
	__ATTR_RO(status);

static struct attribute *charge_attrs[] = {
	&charge_limit_attr.attr,
	&status_attr.attr,
	NULL,
};

static struct attribute_group charge_attr_group = {
	.attrs = charge_attrs,
};

static int __init apex_charge_init(void)
{
	int ret;

	charge_kobj = kobject_create_and_add("charge", kernel_kobj);
	if (!charge_kobj)
		return -ENOMEM;

	ret = sysfs_create_group(charge_kobj, &charge_attr_group);
	if (ret) {
		kobject_put(charge_kobj);
		return ret;
	}

	pr_info("APEX: charge control initialized\n");
	return 0;
}

static void __exit apex_charge_exit(void)
{
	cancel_delayed_work_sync(&charge_work);
	if (brake_active)
		charge_release();
	sysfs_remove_group(charge_kobj, &charge_attr_group);
	kobject_put(charge_kobj);
}

module_init(apex_charge_init);
module_exit(apex_charge_exit);
MODULE_LICENSE("GPL");
MODULE_DESCRIPTION("APEX charge limiting via sysfs");
MODULE_AUTHOR("APEX");
