/*
 * APEX sysfs class — /sys/class/apex/
 *
 * Provides a top-level sysfs interface for APEX kernel features.
 * Default nodes: version, base, enabled_features.
 * Feature modules register themselves under /sys/class/apex/<feature>/.
 *
 * This is the control plane foundation — all APEX features expose
 * their tunables through this class. No feature is actuated by default.
 */

#include <linux/kernel.h>
#include <linux/module.h>
#include <linux/kobject.h>
#include <linux/sysfs.h>
#include <linux/string.h>

#define APEX_VERSION "0.3.0-zepharo"
#define APEX_BASE "5.15.170 Zepharo R9"

static struct kobject *apex_kobj;

static ssize_t version_show(struct kobject *kobj, struct kobj_attribute *attr,
			    char *buf)
{
	return sprintf(buf, "%s\n", APEX_VERSION);
}

static ssize_t base_show(struct kobject *kobj, struct kobj_attribute *attr,
			 char *buf)
{
	return sprintf(buf, "%s\n", APEX_BASE);
}

static ssize_t enabled_features_show(struct kobject *kobj,
				     struct kobj_attribute *attr, char *buf)
{
	/* Features registered under /sys/class/apex/ */
	return sprintf(buf, "sysfs charge\n");
}

static struct kobj_attribute version_attr = __ATTR_RO(version);
static struct kobj_attribute base_attr = __ATTR_RO(base);
static struct kobj_attribute enabled_features_attr = __ATTR_RO(enabled_features);

static struct attribute *apex_attrs[] = {
	&version_attr.attr,
	&base_attr.attr,
	&enabled_features_attr.attr,
	NULL,
};

static struct attribute_group apex_attr_group = {
	.attrs = apex_attrs,
};

static int __init apex_sysfs_init(void)
{
	int ret;

	apex_kobj = kobject_create_and_add("apex", kernel_kobj);
	if (!apex_kobj)
		return -ENOMEM;

	ret = sysfs_create_group(apex_kobj, &apex_attr_group);
	if (ret) {
		kobject_put(apex_kobj);
		return ret;
	}

	pr_info("APEX: sysfs class initialized (%s, %s)\n",
		APEX_VERSION, APEX_BASE);
	return 0;
}

static void __exit apex_sysfs_exit(void)
{
	sysfs_remove_group(apex_kobj, &apex_attr_group);
	kobject_put(apex_kobj);
}

module_init(apex_sysfs_init);
module_exit(apex_sysfs_exit);
MODULE_LICENSE("GPL");
MODULE_DESCRIPTION("APEX kernel sysfs control plane");
MODULE_AUTHOR("APEX");
