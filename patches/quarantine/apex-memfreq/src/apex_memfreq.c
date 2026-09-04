// SPDX-License-Identifier: GPL-2.0-only
/*
 * drivers/devfreq/apex_memfreq.c
 *
 * apex memory bandwidth DEVFREQ driver (Redmi Note 12 4G, SM6225-AD)
 *
 * Sultan Kernel's "Tensor AIO" custom DEVFREQ for RAM/L3-cache was a
 * key innovation: it clocks down RAM/L3 cache faster when not needed,
 * saving idle battery. On SM6225, LPDDR4X is controlled by RPM via
 * SMD-RPM bus voting through the interconnect framework.
 *
 * This driver monitors memory access patterns and votes for lower
 * bandwidth through the interconnect framework when CPU/GPU are idle.
 * When active, it votes for higher bandwidth to reduce latency.
 *
 * The driver uses the existing interconnect paths (already enabled via
 * CONFIG_INTERCONNECT_QCOM_BENGAL) and adds a DEVFREQ-style monitoring
 * layer on top.
 *
 * Status: SKELETON — needs platform-specific interconnect path names
 * and bandwidth vote values from the SM6225 device tree.
 */

#define pr_fmt(fmt) KBUILD_MODNAME ": "

#include <linux/module.h>
#include <linux/kernel.h>
#include <linux/devfreq.h>
#include <linux/interconnect.h>
#include <linux/slab.h>
#include <linux/math64.h>
#include <linux/jiffies.h>
#include <linux/cpufreq.h>
#include <linux/cpumask.h>
#include <linux/topology.h>

/* Polling interval in ms (0 = disabled, use manual triggers) */
#define APEX_MEMFREQ_POLL_MS		100

/* Bandwidth levels (in kBps) — from SM6225-AD device tree.
 * Source: xiaomi-6225-AD/android_kernel_xiaomi_sm6225-devicetrees
 *   qcom/khaje.dtsi: ddr_freq_table = 200, 547, 768, 1017, 1555, 1804, 2092 (MT/s)
 *   qcom/graphics/gpu/khaje-gpu.dtsi: MHZ_TO_KBPS(mhz, 8) = (mhz * 1e6 * 8) / 1024
 * Interconnect provider: bimc @ 0x04480000, compatible "qcom,bengal-bimc"
 * Path: MASTER_AMPSS_M0 (0) -> SLAVE_EBI_CH0 (512)
 * Header: include/dt-bindings/interconnect/qcom,bengal.h
 *
 * LPDDR4X bus width = 8 bytes (64-bit AXI, 2x16-bit DDR channels)
 * BW = DDR_rate * 1e6 * 8 / 1024 kBps */
#define APEX_MEMFREQ_BW_IDLE		1562500		/* 200 MT/s — screen off / idle */
#define APEX_MEMFREQ_BW_NORMAL		6000000		/* 768 MT/s — normal use */
#define APEX_MEMFREQ_BW_GAMING		12148437	/* 1555 MT/s — gaming */
#define APEX_MEMFREQ_BW_MAX		16343750	/* 2092 MT/s — burst / max */

/* Interconnect IDs from qcom,bengal.h */
#define BENGAL_MASTER_AMPSS_M0		0
#define BENGAL_SLAVE_EBI_CH0		512

/* CPU utilization threshold for bandwidth scaling */
#define APEX_MEMFREQ_CPU_IDLE_THRESH	10	/* % */
#define APEX_MEMFREQ_CPU_ACTIVE_THRESH	60	/* % */

struct apex_memfreq_data {
	struct devfreq *df;
	struct icc_path *mem_path;	/* memory interconnect path */
	unsigned long current_bw;	/* current bandwidth vote (kbps) */
	unsigned long target_bw;	/* target bandwidth (kbps) */
};

static struct apex_memfreq_data *mf_data;

/* Read average CPU utilization across all clusters */
static unsigned int apex_memfreq_cpu_util(void)
{
	unsigned int total_util = 0;
	unsigned int cpu_count = 0;
	int cpu;

	for_each_online_cpu(cpu) {
		struct cpufreq_policy *policy = cpufreq_cpu_get(cpu);
		if (!policy)
			continue;

		unsigned int max = policy->cpuinfo.max_freq;
		unsigned int cur = policy->cur;
		if (max > 0)
			total_util += (cur * 100) / max;
		cpu_count++;
		cpufreq_cpu_put(policy);
	}

	return cpu_count > 0 ? total_util / cpu_count : 0;
}

/* DEVFREQ target function: set the memory bandwidth vote */
static int apex_memfreq_target(struct device *dev,
				unsigned long *freq, u32 flags)
{
	struct apex_memfreq_data *data = dev_get_drvdata(dev);
	unsigned long target_bw;
	int ret;

	if (!data || !data->mem_path)
		return -EINVAL;

	target_bw = *freq;

	/* Vote for bandwidth through interconnect framework */
	ret = icc_set_bw(data->mem_path, target_bw, target_bw);
	if (ret) {
		pr_warn("failed to set memory bandwidth: %d\n", ret);
		return ret;
	}

	data->current_bw = target_bw;
	*freq = target_bw;

	return 0;
}

/* DEVFREQ get_dev_status: read current CPU utilization as the
 * "device" status. The governor uses this to decide target frequency. */
static int apex_memfreq_get_dev_status(struct device *dev,
					struct devfreq_dev_status *stat)
{
	stat->busy_time = apex_memfreq_cpu_util();
	stat->total_time = 100;
	stat->current_frequency = mf_data ? mf_data->current_bw : 0;
	return 0;
}

/* Simple governor: map CPU utilization to memory bandwidth */
static int apex_memfreq_gov_func(struct devfreq *df,
				  unsigned long *freq)
{
	unsigned int cpu_util = apex_memfreq_cpu_util();

	if (cpu_util < APEX_MEMFREQ_CPU_IDLE_THRESH)
		*freq = APEX_MEMFREQ_BW_IDLE;
	else if (cpu_util < APEX_MEMFREQ_CPU_ACTIVE_THRESH)
		*freq = APEX_MEMFREQ_BW_NORMAL;
	else
		*freq = APEX_MEMFREQ_BW_GAMING;

	return 0;
}

static struct devfreq_governor apex_memfreq_gov = {
	.name = "apex_memfreq",
	.get_target_freq = apex_memfreq_gov_func,
	.event_handler = NULL, /* no special events needed */
};

/* DEVFREQ profile */
static struct devfreq_dev_profile apex_memfreq_profile = {
	.target = apex_memfreq_target,
	.get_dev_status = apex_memfreq_get_dev_status,
	.polling_ms = APEX_MEMFREQ_POLL_MS,
};

static struct device apex_memfreq_dev = {
	.init_name = "apex-memfreq",
};

static int __init apex_memfreq_init(void)
{
	int ret;

	mf_data = kzalloc(sizeof(*mf_data), GFP_KERNEL);
	if (!mf_data)
		return -ENOMEM;

	/* Get the memory interconnect path.
	 * On SM6225-AD (bengal), the BIMC interconnect provider is at
	 * 0x04480000 (compatible "qcom,bengal-bimc").
	 * The CPU→DDR path uses MASTER_AMPSS_M0 (0) → SLAVE_EBI_CH0 (512)
	 * from include/dt-bindings/interconnect/qcom,bengal.h.
	 *
	 * Source: xiaomi-6225-AD/android_kernel_xiaomi_sm6225-devicetrees
	 *   qcom/khaje.dtsi lines 1946, 1972, 3530
	 *   qcom/khaje.dtsi: ddr_dcvs_sp interconnects = <&bimc MASTER_AMPSS_M0 &bimc SLAVE_EBI_CH0>
	 */
	mf_data->mem_path = icc_get(&apex_memfreq_dev,
				     BENGAL_MASTER_AMPSS_M0,
				     BENGAL_SLAVE_EBI_CH0);
	if (IS_ERR(mf_data->mem_path)) {
		pr_warn("memory interconnect path not available: %ld\n",
			PTR_ERR(mf_data->mem_path));
		mf_data->mem_path = NULL;
		/* Continue without interconnect — driver is a no-op */
	}

	/* Register the custom governor */
	ret = devfreq_add_governor(&apex_memfreq_gov);
	if (ret) {
		pr_warn("failed to add memfreq governor: %d\n", ret);
		goto err_free;
	}

	/* Register DEVFREQ device */
	dev_set_drvdata(&apex_memfreq_dev, mf_data);
	mf_data->df = devfreq_add_device(&apex_memfreq_dev,
					  &apex_memfreq_profile,
					  "apex_memfreq", NULL);
	if (IS_ERR(mf_data->df)) {
		pr_warn("failed to add memfreq devfreq device: %ld\n",
			PTR_ERR(mf_data->df));
		ret = PTR_ERR(mf_data->df);
		goto err_gov;
	}

	pr_info("apex memory DEVFREQ loaded (poll=%dms)\n",
		APEX_MEMFREQ_POLL_MS);
	return 0;

err_gov:
	devfreq_remove_governor(&apex_memfreq_gov);
err_free:
	if (mf_data->mem_path)
		icc_put(mf_data->mem_path);
	kfree(mf_data);
	mf_data = NULL;
	return ret;
}

static void __exit apex_memfreq_exit(void)
{
	if (!mf_data)
		return;

	if (mf_data->df)
		devfreq_remove_device(mf_data->df);

	devfreq_remove_governor(&apex_memfreq_gov);

	if (mf_data->mem_path)
		icc_put(mf_data->mem_path);

	kfree(mf_data);
	mf_data = NULL;
}

module_init(apex_memfreq_init);
module_exit(apex_memfreq_exit);

MODULE_AUTHOR("APEX project");
MODULE_DESCRIPTION("apex memory bandwidth DEVFREQ driver");
MODULE_LICENSE("GPL v2");
