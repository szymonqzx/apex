/*
 * apex_charge.c — APEX Charge Control via /sys/class/apex/charge/
 *
 * Minimal charge control module for the Zepharo R9 base.
 * Provides sysfs tunables for charge limiting and monitoring.
 * Registers under the APEX sysfs class.
 *
 * Sysfs interface: /sys/class/apex/charge/
 *   charge_limit_percent    — rw (80-100, 0=disabled)
 *   charge_mode             — rw (0=auto, 1=fast, 2=balanced, 3=eco)
 *   bypass_charging         — rw (0=off, 1=on)
 *   status                  — r (JSON overview)
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

static struct kobject *charge_kobj;
static DEFINE_MUTEX(charge_mutex);

static int charge_limit_percent = 0;  /* 0=disabled, 80-100 */
static int charge_mode = 0;           /* 0=auto, 1=fast, 2=balanced, 3=eco */
static int bypass_charging = 0;       /* 0=off, 1=on */

static struct power_supply *get_battery_psy(void)
{
	static struct power_supply *cached_psy;
	if (!cached_psy)
		cached_psy = power_supply_get_by_name("battery");
	return cached_psy;
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
	if (val == 0 || (val >= 80 && val <= 100))
		charge_limit_percent = val;
	else
		ret = -EINVAL;
	mutex_unlock(&charge_mutex);

	return ret ? ret : count;
}

static ssize_t charge_mode_show(struct kobject *kobj,
				struct kobj_attribute *attr, char *buf)
{
	return sprintf(buf, "%d\n", charge_mode);
}

static ssize_t charge_mode_store(struct kobject *kobj,
				 struct kobj_attribute *attr,
				 const char *buf, size_t count)
{
	int val, ret;

	ret = kstrtoint(buf, 10, &val);
	if (ret)
		return ret;

	if (val < 0 || val > 3)
		return -EINVAL;

	mutex_lock(&charge_mutex);
	charge_mode = val;
	mutex_unlock(&charge_mutex);

	return count;
}

static ssize_t bypass_charging_show(struct kobject *kobj,
				    struct kobj_attribute *attr, char *buf)
{
	return sprintf(buf, "%d\n", bypass_charging);
}

static ssize_t bypass_charging_store(struct kobject *kobj,
				     struct kobj_attribute *attr,
				     const char *buf, size_t count)
{
	int val, ret;

	ret = kstrtoint(buf, 10, &val);
	if (ret)
		return ret;

	if (val != 0 && val != 1)
		return -EINVAL;

	mutex_lock(&charge_mutex);
	bypass_charging = val;
	mutex_unlock(&charge_mutex);

	return count;
}

static ssize_t status_show(struct kobject *kobj, struct kobj_attribute *attr,
			   char *buf)
{
	struct power_supply *psy = get_battery_psy();
	union power_supply_propval prop;
	int capacity = 0, temp = 0, voltage = 0, curr_ua = 0;

	if (psy) {
		if (!power_supply_get_property(psy, POWER_SUPPLY_PROP_CAPACITY, &prop))
			capacity = prop.intval;
		if (!power_supply_get_property(psy, POWER_SUPPLY_PROP_TEMP, &prop))
			temp = prop.intval;
		if (!power_supply_get_property(psy, POWER_SUPPLY_PROP_VOLTAGE_NOW, &prop))
			voltage = prop.intval;
		if (!power_supply_get_property(psy, POWER_SUPPLY_PROP_CURRENT_NOW, &prop))
			curr_ua = prop.intval;
	}

	return sprintf(buf,
		"{\"charge_limit\":%d,\"mode\":%d,\"bypass\":%d,"
		"\"capacity\":%d,\"temp\":%d,\"voltage_uv\":%d,\"current_ua\":%d}\n",
		charge_limit_percent, charge_mode, bypass_charging,
		capacity, temp, voltage, curr_ua);
}

static struct kobj_attribute charge_limit_attr =
	__ATTR(charge_limit_percent, 0644, charge_limit_percent_show, charge_limit_percent_store);
static struct kobj_attribute charge_mode_attr =
	__ATTR(charge_mode, 0644, charge_mode_show, charge_mode_store);
static struct kobj_attribute bypass_attr =
	__ATTR(bypass_charging, 0644, bypass_charging_show, bypass_charging_store);
static struct kobj_attribute status_attr =
	__ATTR_RO(status);

static struct attribute *charge_attrs[] = {
	&charge_limit_attr.attr,
	&charge_mode_attr.attr,
	&bypass_attr.attr,
	&status_attr.attr,
	NULL,
};

static struct attribute_group charge_attr_group = {
	.attrs = charge_attrs,
};

static int __init apex_charge_init(void)
{
	int ret;

	/* Register under /sys/class/apex/charge/ */
	charge_kobj = kobject_create_and_add("charge", kernel_kobj);
	if (!charge_kobj)
		return -ENOMEM;

	/* Actually register under /sys/kernel/apex/charge/ —
	 * the apex_sysfs module creates /sys/class/apex/ via kobject_create_and_add
	 * on kernel_kobj, so we nest under the same parent */
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
	sysfs_remove_group(charge_kobj, &charge_attr_group);
	kobject_put(charge_kobj);
}

module_init(apex_charge_init);
module_exit(apex_charge_exit);
MODULE_LICENSE("GPL");
MODULE_DESCRIPTION("APEX charge control via sysfs");
MODULE_AUTHOR("APEX");
