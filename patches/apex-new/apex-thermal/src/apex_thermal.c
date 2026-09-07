// SPDX-License-Identifier: GPL-2.0
/*
 * APEX thermal learner — thermal history ring buffer + tunable trips
 *
 * Samples the primary thermal zone every sample_interval seconds and keeps
 * a 7-day ring buffer (10080 slots at 60 s) exposed via:
 *   /proc/apex/thermal_history          one "ts temp_mdeg" line per sample
 *   /sys/class/apex/thermal/current_temp   last sample, millidegrees
 *   /sys/class/apex/thermal/rolling_avg    7-day rolling average (mdeg)
 *   /sys/class/apex/thermal/zone           resolved thermal zone name
 *   /sys/class/apex/thermal/sample_count   samples collected
 *   /sys/class/apex/thermal/trip_low|mid|high   learner trips (mdeg, writable)
 *
 * The 7-day learning itself lives in userspace (apex_thermal_learner.sh):
 * it reads the history, computes the rolling average, and writes adjusted
 * trips (defaults 45/55/65 C, shift capped at +/-2 C). The kernel side is
 * deliberately dumb: sample, store, expose.
 *
 * The zone is resolved by trying zone_names in order (module parameter),
 * so vendor DTB naming differences are handled without code changes.
 */

#include <linux/kernel.h>
#include <linux/module.h>
#include <linux/proc_fs.h>
#include <linux/seq_file.h>
#include <linux/kobject.h>
#include <linux/sysfs.h>
#include <linux/mutex.h>
#include <linux/thermal.h>
#include <linux/workqueue.h>
#include <linux/timekeeping.h>
#include <linux/delay.h>

#define APEX_THERMAL_SLOTS		10080	/* 7 days at 60 s */
#define APEX_THERMAL_DEFAULT_TRIP_LOW	45000
#define APEX_THERMAL_DEFAULT_TRIP_MID	55000
#define APEX_THERMAL_DEFAULT_TRIP_HIGH	65000

struct apex_thermal_sample {
	s64 ts;
	s32 temp;	/* millidegrees C */
};

static struct apex_thermal_sample apex_history[APEX_THERMAL_SLOTS];
static unsigned int apex_history_wr;
static unsigned int apex_history_count;
static struct mutex apex_thermal_lock;

static struct thermal_zone_device *apex_tz;
static char apex_tz_name[THERMAL_NAME_LENGTH];

static unsigned int sample_interval = 60;
module_param(sample_interval, uint, 0644);
MODULE_PARM_DESC(sample_interval, "sampling interval in seconds (default 60)");

static char *zone_names = "pm6125-tz,cpu-0-0-usr,apc-therm-usr,quiet-therm-usr,back-therm-usr,soc-therm-usr,tsens_tz_sensor0";
module_param(zone_names, charp, 0644);
MODULE_PARM_DESC(zone_names, "comma-separated thermal zone names to try");

/* sysfs trips — written by the userspace learner */
static s32 trip_low = APEX_THERMAL_DEFAULT_TRIP_LOW;
static s32 trip_mid = APEX_THERMAL_DEFAULT_TRIP_MID;
static s32 trip_high = APEX_THERMAL_DEFAULT_TRIP_HIGH;

extern struct kobject *apex_kobj;	/* from apex_sysfs */

static struct delayed_work apex_thermal_work;
static struct kobject *apex_thermal_kobj;

/* ------------------------------------------------------------------ */

static void apex_thermal_resolve_zone(void)
{
	char buf[THERMAL_NAME_LENGTH];
	char *p, *name;
	struct thermal_zone_device *tz;

	strscpy(buf, zone_names, sizeof(buf));
	p = buf;
	while (p && *p) {
		name = strsep(&p, ",");
		if (!name || !*name)
			continue;
		tz = thermal_zone_get_zone_by_name(name);
		if (IS_ERR(tz))
			continue;
		mutex_lock(&apex_thermal_lock);
		if (apex_tz)
			put_device(&apex_tz->device);
		apex_tz = tz;
		strscpy(apex_tz_name, name, THERMAL_NAME_LENGTH);
		mutex_unlock(&apex_thermal_lock);
		pr_info("apex_thermal: using zone '%s'\n", name);
		return;
	}
	pr_warn_once("apex_thermal: no thermal zone matched (%s)\n", zone_names);
}

static void apex_thermal_sample_work(struct work_struct *work)
{
	struct thermal_zone_device *tz;
	int temp = 0;

	mutex_lock(&apex_thermal_lock);
	tz = apex_tz;
	mutex_unlock(&apex_thermal_lock);

	if (!tz)
		apex_thermal_resolve_zone();
	else if (thermal_zone_get_temp(tz, &temp)) {
		/* zone vanished or is unavailable — re-resolve next round */
		mutex_lock(&apex_thermal_lock);
		if (apex_tz) {
			put_device(&apex_tz->device);
			apex_tz = NULL;
		}
		mutex_unlock(&apex_thermal_lock);
		apex_thermal_resolve_zone();
	}

	if (tz || apex_tz) {
		mutex_lock(&apex_thermal_lock);
		tz = apex_tz;
		if (tz && !thermal_zone_get_temp(tz, &temp)) {
			struct timespec64 ts;

			ktime_get_real_ts64(&ts);
			apex_history[apex_history_wr].ts = ts.tv_sec;
			apex_history[apex_history_wr].temp = temp;
			apex_history_wr = (apex_history_wr + 1) % APEX_THERMAL_SLOTS;
			if (apex_history_count < APEX_THERMAL_SLOTS)
				apex_history_count++;
		}
		mutex_unlock(&apex_thermal_lock);
	}

	schedule_delayed_work(&apex_thermal_work,
			      msecs_to_jiffies(sample_interval * 1000));
}

/* ------------------------------------------------------------------ */
/* proc: /proc/apex/thermal_history                                    */

static void *apex_thermal_seq_start(struct seq_file *m, loff_t *pos)
{
	mutex_lock(&apex_thermal_lock);
	if (*pos >= apex_history_count)
		return NULL;
	return (void *)((unsigned long)*pos + 1);
}

static void *apex_thermal_seq_next(struct seq_file *m, void *v, loff_t *pos)
{
	(*pos)++;
	if (*pos >= apex_history_count)
		return NULL;
	return (void *)((unsigned long)*pos + 1);
}

static void apex_thermal_seq_stop(struct seq_file *m, void *v)
{
	mutex_unlock(&apex_thermal_lock);
}

static int apex_thermal_seq_show(struct seq_file *m, void *v)
{
	unsigned int i = (unsigned long)v - 1;
	unsigned int idx;

	idx = (apex_history_wr + APEX_THERMAL_SLOTS -
	       apex_history_count + i) % APEX_THERMAL_SLOTS;
	seq_printf(m, "%lld %d\n", apex_history[idx].ts,
		   apex_history[idx].temp);
	return 0;
}

static const struct seq_operations apex_thermal_seq_ops = {
	.start = apex_thermal_seq_start,
	.next = apex_thermal_seq_next,
	.stop = apex_thermal_seq_stop,
	.show = apex_thermal_seq_show,
};

static int apex_thermal_proc_open(struct inode *inode, struct file *file)
{
	return seq_open(file, &apex_thermal_seq_ops);
}

static const struct proc_ops apex_thermal_proc_ops = {
	.proc_open = apex_thermal_proc_open,
	.proc_read = seq_read,
	.proc_lseek = seq_lseek,
	.proc_release = seq_release,
};

/* ------------------------------------------------------------------ */
/* sysfs: /sys/class/apex/thermal/                                     */

static s32 apex_thermal_rolling_avg(void)
{
	s64 sum = 0;
	unsigned int i;

	if (!apex_history_count)
		return 0;
	for (i = 0; i < apex_history_count; i++) {
		unsigned int idx = (apex_history_wr + APEX_THERMAL_SLOTS -
				    apex_history_count + i) % APEX_THERMAL_SLOTS;
		sum += apex_history[idx].temp;
	}
	return div_s64(sum, apex_history_count);
}

static ssize_t current_temp_show(struct kobject *kobj,
				 struct kobj_attribute *attr, char *buf)
{
	s32 temp = 0;

	mutex_lock(&apex_thermal_lock);
	if (apex_history_count)
		temp = apex_history[(apex_history_wr + APEX_THERMAL_SLOTS - 1) %
				    APEX_THERMAL_SLOTS].temp;
	mutex_unlock(&apex_thermal_lock);
	return sysfs_emit(buf, "%d\n", temp);
}

static ssize_t rolling_avg_show(struct kobject *kobj,
				struct kobj_attribute *attr, char *buf)
{
	s32 avg;

	mutex_lock(&apex_thermal_lock);
	avg = apex_thermal_rolling_avg();
	mutex_unlock(&apex_thermal_lock);
	return sysfs_emit(buf, "%d\n", avg);
}

static ssize_t zone_show(struct kobject *kobj, struct kobj_attribute *attr,
			 char *buf)
{
	ssize_t n;

	mutex_lock(&apex_thermal_lock);
	if (!apex_tz_name[0])
		strscpy(apex_tz_name, "(none)", THERMAL_NAME_LENGTH);
	n = sysfs_emit(buf, "%s\n", apex_tz_name);
	mutex_unlock(&apex_thermal_lock);
	return n;
}

static ssize_t sample_count_show(struct kobject *kobj,
				 struct kobj_attribute *attr, char *buf)
{
	unsigned int n;

	mutex_lock(&apex_thermal_lock);
	n = apex_history_count;
	mutex_unlock(&apex_thermal_lock);
	return sysfs_emit(buf, "%u\n", n);
}

static struct kobj_attribute current_temp_attr = __ATTR_RO(current_temp);
static struct kobj_attribute rolling_avg_attr = __ATTR_RO(rolling_avg);
static struct kobj_attribute zone_attr = __ATTR_RO(zone);
static struct kobj_attribute sample_count_attr = __ATTR_RO(sample_count);

#define APEX_TRIP_ATTR(_name)						\
static ssize_t _name##_show(struct kobject *kobj,				\
			    struct kobj_attribute *attr, char *buf)	\
{									\
	s32 v;								\
	mutex_lock(&apex_thermal_lock);					\
	v = _name;							\
	mutex_unlock(&apex_thermal_lock);				\
	return sysfs_emit(buf, "%d\n", v);				\
}									\
static ssize_t _name##_store(struct kobject *kobj,				\
			     struct kobj_attribute *attr, const char *buf,	\
			     size_t count)					\
{									\
	s32 v;								\
	if (kstrtos32(buf, 10, &v) || v < 0 || v > 120000)		\
		return -EINVAL;						\
	mutex_lock(&apex_thermal_lock);					\
	_name = v;							\
	mutex_unlock(&apex_thermal_lock);				\
	return count;							\
}									\
static struct kobj_attribute _name##_attr = __ATTR_RW(_name)

APEX_TRIP_ATTR(trip_low);
APEX_TRIP_ATTR(trip_mid);
APEX_TRIP_ATTR(trip_high);

static struct attribute *apex_thermal_attrs[] = {
	&current_temp_attr.attr,
	&rolling_avg_attr.attr,
	&zone_attr.attr,
	&sample_count_attr.attr,
	&trip_low_attr.attr,
	&trip_mid_attr.attr,
	&trip_high_attr.attr,
	NULL,
};

static struct attribute_group apex_thermal_attr_group = {
	.attrs = apex_thermal_attrs,
};

/* ------------------------------------------------------------------ */

static int __init apex_thermal_init(void)
{
	struct proc_dir_entry *apex_dir;

	mutex_init(&apex_thermal_lock);
	INIT_DELAYED_WORK(&apex_thermal_work, apex_thermal_sample_work);

	if (!apex_kobj) {
		pr_err("apex_thermal: apex sysfs class not available\n");
		return -ENODEV;
	}
	apex_thermal_kobj = kobject_create_and_add("thermal", apex_kobj);
	if (!apex_thermal_kobj) {
		pr_err("apex_thermal: failed to create sysfs kobject\n");
		return -ENOMEM;
	}
	if (sysfs_create_group(apex_thermal_kobj, &apex_thermal_attr_group)) {
		pr_err("apex_thermal: failed to create sysfs group\n");
		kobject_put(apex_thermal_kobj);
		return -ENOMEM;
	}

	apex_dir = proc_mkdir("apex", NULL);
	if (apex_dir)
		proc_create("thermal_history", 0444, apex_dir,
			    &apex_thermal_proc_ops);

	apex_thermal_resolve_zone();
	schedule_delayed_work(&apex_thermal_work,
			      msecs_to_jiffies(sample_interval * 1000));
	pr_info("apex_thermal: initialized (interval %us, %d slots)\n",
		sample_interval, APEX_THERMAL_SLOTS);
	return 0;
}

static void __exit apex_thermal_exit(void)
{
	cancel_delayed_work_sync(&apex_thermal_work);
	remove_proc_entry("thermal_history", NULL);
	remove_proc_entry("apex", NULL);
	if (apex_thermal_kobj) {
		sysfs_remove_group(apex_thermal_kobj, &apex_thermal_attr_group);
		kobject_put(apex_thermal_kobj);
	}
	mutex_lock(&apex_thermal_lock);
	if (apex_tz) {
		put_device(&apex_tz->device);
		apex_tz = NULL;
	}
	mutex_unlock(&apex_thermal_lock);
}

module_init(apex_thermal_init);
module_exit(apex_thermal_exit);

MODULE_LICENSE("GPL");
MODULE_DESCRIPTION("APEX thermal learner: history ring buffer + tunable trips");
MODULE_VERSION("1.0.0");
