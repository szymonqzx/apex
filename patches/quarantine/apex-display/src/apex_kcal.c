// SPDX-License-Identifier: GPL-2.0-only
/*
 * drivers/video/apex_kcal.c
 *
 * apex KCAL display color calibration (Redmi Note 12 4G, SM6225-AD)
 *
 * Provides RGB gain adjustment for the MDSS display panel via sysfs.
 * Exposes /sys/class/apex_kcal/ with:
 *   - rgb_gains: read/write "R G B" (0-255 each), default 255 255 255
 *   - reset:     write to restore defaults
 *
 * On Qualcomm MDSS (Mobile Display Sub System), the Ping-Pong (PP) TE2
 * block has PPx_ADJ_GAIN registers that control per-channel gain.
 * The SM6225 uses DSI panels with MDSS 5.3.
 *
 * If the MDSS PP registers are not accessible (different panel driver
 * version), falls back to writing the fbdev sysfs interface at
 * /sys/class/graphics/fb0/rgb_gains if available.
 *
 * Inspired by KCAL patches in Franco, ElementalX, and other custom kernels.
 * Adapted for CAF bengal-5.15 MDSS driver.
 */

#define pr_fmt(fmt) KBUILD_MODNAME ": "

#include <linux/module.h>
#include <linux/kernel.h>
#include <linux/fs.h>
#include <linux/sysfs.h>
#include <linux/kobject.h>
#include <linux/uaccess.h>
#include <linux/string.h>
#include <linux/fb.h>
#include <linux/file.h>

#define APEX_KCAL_MAX_GAIN	255
#define APEX_KCAL_DEFAULT_R	255
#define APEX_KCAL_DEFAULT_G	255
#define APEX_KCAL_DEFAULT_B	255

struct apex_kcal_state {
	unsigned int r_gain;
	unsigned int g_gain;
	unsigned int b_gain;
};

static struct apex_kcal_state kcal_state = {
	.r_gain = APEX_KCAL_DEFAULT_R,
	.g_gain = APEX_KCAL_DEFAULT_G,
	.b_gain = APEX_KCAL_DEFAULT_B,
};

static struct kobject *kcal_kobj;

/* Write RGB gains to the MDSS panel driver via sysfs.
 * The CAF MDSS driver exposes /sys/class/graphics/fb0/rgb_gains
 * on some builds. If not available, we try the DSI panel's
 * mdp_pp_adj_gain node. */
static void apex_kcal_apply(void)
{
	char buf[32];
	int len;
	struct file *f;

	/* Try fbdev sysfs first (most compatible) */
	len = snprintf(buf, sizeof(buf), "%u %u %u",
		       kcal_state.r_gain, kcal_state.g_gain, kcal_state.b_gain);

	f = filp_open("/sys/class/graphics/fb0/rgb_gains", O_WRONLY, 0);
	if (!IS_ERR(f)) {
		kernel_write(f, buf, len, &f->f_pos);
		filp_close(f, NULL);
		pr_info("KCAL: rgb gains set to %u %u %u via fbdev\n",
			kcal_state.r_gain, kcal_state.g_gain, kcal_state.b_gain);
		return;
	}

	/* Try DSI panel node (CAF-specific) */
	f = filp_open("/sys/class/dsi_panel/primary_panel/pp_adj_gain", O_WRONLY, 0);
	if (!IS_ERR(f)) {
		kernel_write(f, buf, len, &f->f_pos);
		filp_close(f, NULL);
		pr_info("KCAL: rgb gains set to %u %u %u via DSI panel\n",
			kcal_state.r_gain, kcal_state.g_gain, kcal_state.b_gain);
		return;
	}

	pr_warn("KCAL: no panel interface available for gain adjustment\n");
}

static ssize_t kcal_rgb_gains_show(struct kobject *kobj,
				    struct kobj_attribute *attr,
				    char *buf)
{
	return sprintf(buf, "%u %u %u\n",
		       kcal_state.r_gain, kcal_state.g_gain, kcal_state.b_gain);
}

static ssize_t kcal_rgb_gains_store(struct kobject *kobj,
				     struct kobj_attribute *attr,
				     const char *buf, size_t count)
{
	unsigned int r, g, b;
	int ret;

	ret = sscanf(buf, "%u %u %u", &r, &g, &b);
	if (ret != 3)
		return -EINVAL;

	if (r > APEX_KCAL_MAX_GAIN || g > APEX_KCAL_MAX_GAIN ||
	    b > APEX_KCAL_MAX_GAIN)
		return -EINVAL;

	kcal_state.r_gain = r;
	kcal_state.g_gain = g;
	kcal_state.b_gain = b;
	apex_kcal_apply();

	return count;
}

static ssize_t kcal_reset_store(struct kobject *kobj,
				 struct kobj_attribute *attr,
				 const char *buf, size_t count)
{
	kcal_state.r_gain = APEX_KCAL_DEFAULT_R;
	kcal_state.g_gain = APEX_KCAL_DEFAULT_G;
	kcal_state.b_gain = APEX_KCAL_DEFAULT_B;
	apex_kcal_apply();
	pr_info("KCAL: gains reset to defaults\n");
	return count;
}

static struct kobj_attribute kcal_rgb_gains_attr =
	__ATTR(rgb_gains, 0644, kcal_rgb_gains_show, kcal_rgb_gains_store);
static struct kobj_attribute kcal_reset_attr =
	__ATTR(reset, 0200, NULL, kcal_reset_store);

static struct attribute *kcal_attrs[] = {
	&kcal_rgb_gains_attr.attr,
	&kcal_reset_attr.attr,
	NULL,
};

static struct attribute_group kcal_attr_group = {
	.attrs = kcal_attrs,
};

static int __init apex_kcal_init(void)
{
	int ret;

	kcal_kobj = kobject_create_and_add("apex_kcal", kernel_kobj);
	if (!kcal_kobj)
		return -ENOMEM;

	ret = sysfs_create_group(kcal_kobj, &kcal_attr_group);
	if (ret) {
		kobject_put(kcal_kobj);
		return ret;
	}

	/* Apply default gains on boot (ensures panel is in known state) */
	apex_kcal_apply();

	pr_info("apex KCAL display calibration loaded\n");
	return 0;
}

static void __exit apex_kcal_exit(void)
{
	/* Reset to defaults on unload */
	kcal_state.r_gain = APEX_KCAL_DEFAULT_R;
	kcal_state.g_gain = APEX_KCAL_DEFAULT_G;
	kcal_state.b_gain = APEX_KCAL_DEFAULT_B;
	apex_kcal_apply();

	if (kcal_kobj)
		kobject_put(kcal_kobj);
}

module_init(apex_kcal_init);
module_exit(apex_kcal_exit);

MODULE_AUTHOR("APEX project");
MODULE_DESCRIPTION("apex KCAL display color calibration");
MODULE_LICENSE("GPL v2");
