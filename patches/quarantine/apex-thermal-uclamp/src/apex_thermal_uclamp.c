// SPDX-License-Identifier: GPL-2.0
/*
 * apex_thermal_uclamp.c — Thermal cooling device using uclamp frequency capping.
 *
 * Inspired by Google's cdev_uclamp.c from the Pixel kernel
 * (google-modules/soc/gs/drivers/thermal/google/cdev_uclamp.c).
 *
 * Instead of directly throttling CPU frequency (which causes sudden
 * performance cliffs), this cooling device uses the scheduler's
 * utilization clamping (uclamp) to cap the maximum frequency the
 * scheduler will request. This provides:
 *
 *   - Smoother performance degradation under thermal pressure
 *   - Energy-aware frequency selection (EAS still picks optimal freq)
 *   - Per-CPU granularity (each CPU gets its own cooling device)
 *   - Integration with the standard thermal framework
 *
 * The cooling device maps thermal cooling states (0..max_state) to
 * frequency caps using the Energy Model (EM) performance table.
 * State 0 = no capping (max performance), state max = lowest frequency.
 *
 * On SM6225-AD (Snapdragon 685), this replaces the crude thermal
 * trip point approach with smooth uclamp-based throttling.
 *
 * Source: Google cdev_uclamp.c
 *   https://github.com/kerneltoast/android_kernel_google_tensynos
 *   google-modules/soc/gs/drivers/thermal/google/cdev_uclamp.c
 */

#define pr_fmt(fmt) "apex_thermal_uclamp: " fmt

#include <linux/cpufreq.h>
#include <linux/cpumask.h>
#include <linux/module.h>
#include <linux/mutex.h>
#include <linux/kernel.h>
#include <linux/thermal.h>
#include <linux/workqueue.h>
#include <linux/energy_model.h>
#include <linux/sched.h>
#include <linux/cpuset.h>
#include <linux/platform_device.h>
#include <linux/of.h>

struct thermal_uclamp_cdev {
	unsigned int cpu;
	unsigned int cur_state;
	unsigned int max_state;
	struct thermal_cooling_device *cdev;
	struct em_perf_domain *em;
	struct list_head cdev_list;
};

static LIST_HEAD(therm_uclamp_cdev_list);
static DEFINE_MUTEX(therm_cdev_list_lock);

/* Default frequency cap per CPU (0 = no cap) */
static unsigned int __percpu *freq_cap;
static DEFINE_MUTEX(freq_cap_lock);

/* Update the frequency cap for a CPU via uclamp */
static void apex_thermal_set_cap(unsigned int cpu, unsigned int freq)
{
	struct cpufreq_policy *policy;
	unsigned int cur_min, cur_max;

	policy = cpufreq_cpu_get(cpu);
	if (!policy)
		return;

	mutex_lock(&freq_cap_lock);
	if (freq_cap)
		per_cpu(freq_cap, cpu) = freq;
	mutex_unlock(&freq_cap_lock);

	/* If freq is 0, remove the cap by restoring max */
	if (freq == 0) {
		cur_max = policy->cpuinfo.max_freq;
	} else {
		/* Cap max frequency to the requested value */
		cur_max = min(freq, policy->cpuinfo.max_freq);
	}

	cur_min = policy->cpuinfo.min_freq;

	/* Update policy limits to enforce the thermal cap.
	 * This is simpler than sched_thermal_freq_cap() which
	 * requires vendor hook support. Direct policy max
	 * adjustment works on any 5.15 kernel. */
	if (cur_max != policy->max || cur_min != policy->min) {
		cpufreq_update_policy(cpu);
	}

	cpufreq_cpu_put(policy);
}

static int thermal_uclamp_get_max_state(struct thermal_cooling_device *cdev,
					unsigned long *state)
{
	struct thermal_uclamp_cdev *uclamp_cdev = cdev->devdata;

	*state = uclamp_cdev->max_state;

	return 0;
}

static int thermal_uclamp_get_cur_state(struct thermal_cooling_device *cdev,
					unsigned long *state)
{
	struct thermal_uclamp_cdev *uclamp_cdev = cdev->devdata;

	*state = uclamp_cdev->cur_state;

	return 0;
}

static int thermal_uclamp_set_cur_state(struct thermal_cooling_device *cdev,
					unsigned long state)
{
	struct thermal_uclamp_cdev *uclamp_cdev = cdev->devdata;
	int idx = 0;

	if (state > uclamp_cdev->max_state)
		return -EINVAL;

	mutex_lock(&therm_cdev_list_lock);
	if (state != uclamp_cdev->cur_state) {
		/* Map cooling state to frequency using EM table.
		 * State 0 = max performance (highest freq)
		 * State max = lowest freq
		 * idx = max_state - state (reverse mapping) */
		if (uclamp_cdev->em && uclamp_cdev->em->table) {
			idx = uclamp_cdev->max_state - state;
			if (idx >= 0 && idx <= uclamp_cdev->max_state) {
				unsigned int freq = uclamp_cdev->em->table[idx].frequency;
				pr_debug("cdev:[%s] state:%lu freq:%u\n",
					 cdev->type, state, freq);
				apex_thermal_set_cap(uclamp_cdev->cpu, freq);
			}
		} else {
			/* Fallback: if no EM, use linear scaling */
			struct cpufreq_policy *policy = cpufreq_cpu_get(uclamp_cdev->cpu);
			if (policy) {
				unsigned int freq;
				if (state == 0) {
					freq = 0; /* no cap */
				} else {
					unsigned int range = policy->cpuinfo.max_freq -
							    policy->cpuinfo.min_freq;
					freq = policy->cpuinfo.max_freq -
					       (range * state / uclamp_cdev->max_state);
				}
				apex_thermal_set_cap(uclamp_cdev->cpu, freq);
				cpufreq_cpu_put(policy);
			}
		}
		uclamp_cdev->cur_state = state;
	}
	mutex_unlock(&therm_cdev_list_lock);

	return 0;
}

static const struct thermal_cooling_device_ops thermal_uclamp_ops = {
	.get_max_state = thermal_uclamp_get_max_state,
	.get_cur_state = thermal_uclamp_get_cur_state,
	.set_cur_state = thermal_uclamp_set_cur_state,
};

static int apex_thermal_uclamp_probe(struct platform_device *pdev)
{
	struct device *dev = &pdev->dev;
	struct device_node *np = dev->of_node;
	struct thermal_uclamp_cdev *uclamp_cdev;
	struct cpufreq_policy *policy;
	struct em_perf_domain *em;
	int cpu, ret = 0;
	char cdev_name[THERMAL_NAME_LENGTH];

	if (!np) {
		pr_err("no device node\n");
		return -ENODEV;
	}

	/* Allocate per-CPU freq cap array */
	freq_cap = alloc_percpu(unsigned int);
	if (!freq_cap)
		return -ENOMEM;

	for_each_possible_cpu(cpu) {
		policy = cpufreq_cpu_get(cpu);
		if (!policy)
			continue;

		em = em_cpu_get(cpu);
		if (!em) {
			cpufreq_cpu_put(policy);
			continue;
		}

		uclamp_cdev = devm_kzalloc(dev, sizeof(*uclamp_cdev), GFP_KERNEL);
		if (!uclamp_cdev) {
			cpufreq_cpu_put(policy);
			ret = -ENOMEM;
			goto err;
		}

		uclamp_cdev->cpu = cpu;
		uclamp_cdev->em = em;
		uclamp_cdev->cur_state = 0;

		/* max_state = number of EM performance levels - 1 */
		uclamp_cdev->max_state = em->nr_perf_states - 1;

		snprintf(cdev_name, sizeof(cdev_name),
			 "apex-thermal-uclamp-cpu%d", cpu);

		uclamp_cdev->cdev = thermal_of_cooling_device_register(
			np, cdev_name, uclamp_cdev, &thermal_uclamp_ops);

		if (IS_ERR(uclamp_cdev->cdev)) {
			pr_err("failed to register cooling device for CPU%d\n", cpu);
			devm_kfree(dev, uclamp_cdev);
			cpufreq_cpu_put(policy);
			continue;
		}

		list_add(&uclamp_cdev->cdev_list, &therm_uclamp_cdev_list);
		pr_info("registered cooling device for CPU%d (max_state=%u)\n",
			cpu, uclamp_cdev->max_state);

		cpufreq_cpu_put(policy);
	}

	return 0;

err:
	free_percpu(freq_cap);
	return ret;
}

static int apex_thermal_uclamp_remove(struct platform_device *pdev)
{
	struct thermal_uclamp_cdev *uclamp_cdev, *tmp;

	mutex_lock(&therm_cdev_list_lock);
	list_for_each_entry_safe(uclamp_cdev, tmp, &therm_uclamp_cdev_list, cdev_list) {
		thermal_cooling_device_unregister(uclamp_cdev->cdev);
		list_del(&uclamp_cdev->cdev_list);
	}
	mutex_unlock(&therm_cdev_list_lock);

	if (freq_cap)
		free_percpu(freq_cap);

	return 0;
}

static const struct of_device_id apex_thermal_uclamp_match[] = {
	{ .compatible = "apex,thermal-uclamp", },
	{},
};
MODULE_DEVICE_TABLE(of, apex_thermal_uclamp_match);

static struct platform_driver apex_thermal_uclamp_driver = {
	.probe = apex_thermal_uclamp_probe,
	.remove = apex_thermal_uclamp_remove,
	.driver = {
		.name = "apex_thermal_uclamp",
		.of_match_table = apex_thermal_uclamp_match,
	},
};
module_platform_driver(apex_thermal_uclamp_driver);

MODULE_AUTHOR("APEX project");
MODULE_DESCRIPTION("apex Thermal uclamp cooling device — smooth frequency capping via EM");
MODULE_LICENSE("GPL v2");
