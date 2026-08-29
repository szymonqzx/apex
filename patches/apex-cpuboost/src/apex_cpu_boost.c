// SPDX-License-Identifier: GPL-2.0-only
/*
 * drivers/cpufreq/apex_cpu_boost.c
 *
 * apex CPU Boost — input-driven CPU frequency booster.
 *
 * Inspired by Qualcomm's cpu-boost driver (LSF/CAF) as used in
 * the Eva kernel (mvaisakh/oneplus7) and many CAF kernels.
 *
 * This driver hooks into the input subsystem to detect touch events
 * and temporarily raises the minimum CPU frequency (policy->min) for
 * a configurable duration. This provides immediate responsiveness on
 * touch, independent of the governor's sampling rate.
 *
 * Key features:
 *   - Per-CPU configurable boost frequency
 *   - Configurable boost duration (ms)
 *   - Minimum input interval rate-limiting (150ms)
 *   - High-priority workqueue for immediate boost
 *   - Scheduler boost integration (optional, via sched_set_boost)
 *   - Touchscreen + keypad + touchpad input matching
 *
 * The driver uses CPUFREQ_ADJUST notifier to override policy min,
 * which is the standard cpufreq policy adjustment path.
 *
 * Source: Qualcomm cpu-boost driver (drivers/cpufreq/cpu-boost.c)
 *   as used in Eva kernel: https://github.com/mvaisakh/oneplus7
 */

#define pr_fmt(fmt) "apex-cpu-boost: " fmt

#include <linux/kernel.h>
#include <linux/init.h>
#include <linux/cpufreq.h>
#include <linux/cpu.h>
#include <linux/sched.h>
#include <linux/moduleparam.h>
#include <linux/slab.h>
#include <linux/input.h>
#include <linux/time.h>
#include <linux/workqueue.h>
#include <linux/module.h>

struct cpu_sync {
	int cpu;
	unsigned int input_boost_min;
	unsigned int input_boost_freq;
};

static DEFINE_PER_CPU(struct cpu_sync, sync_info);
static struct workqueue_struct *cpu_boost_wq;

static struct work_struct input_boost_work;
static struct delayed_work input_boost_rem;

static bool input_boost_enabled;

static unsigned int input_boost_ms = 40;
module_param(input_boost_ms, uint, 0644);

static unsigned int sched_boost_on_input;
module_param(sched_boost_on_input, uint, 0644);

static bool sched_boost_active;

static u64 last_input_time;
#define MIN_INPUT_INTERVAL (150 * USEC_PER_MSEC)

/* Default boost frequencies (kHz) — tuned for SM6225-AD
 * Little cluster (A53): boost to 1.4 GHz
 * Big cluster (A73): boost to 1.8 GHz
 * These are conservative — below max to avoid sudden power spikes */
#define DEFAULT_BOOST_FREQ_LITTLE	1400000
#define DEFAULT_BOOST_FREQ_BIG		1800000
#define BIG_CLUSTER_THRESHOLD		2000000

static int set_input_boost_freq(const char *buf, const struct kernel_param *kp)
{
	int i, ntokens = 0;
	unsigned int val, cpu;
	const char *cp = buf;
	bool enabled = false;

	while ((cp = strpbrk(cp + 1, " :")))
		ntokens++;

	/* single number: apply to all CPUs */
	if (!ntokens) {
		if (sscanf(buf, "%u\n", &val) != 1)
			return -EINVAL;
		for_each_possible_cpu(i)
			per_cpu(sync_info, i).input_boost_freq = val;
		goto check_enable;
	}

	/* CPU:value pair */
	if (!(ntokens % 2))
		return -EINVAL;

	cp = buf;
	for (i = 0; i < ntokens; i += 2) {
		if (sscanf(cp, "%u:%u", &cpu, &val) != 2)
			return -EINVAL;
		if (cpu >= num_possible_cpus())
			return -EINVAL;

		per_cpu(sync_info, cpu).input_boost_freq = val;
		cp = strnchr(cp, PAGE_SIZE - (cp - buf), ' ');
		cp++;
	}

check_enable:
	for_each_possible_cpu(i) {
		if (per_cpu(sync_info, i).input_boost_freq) {
			enabled = true;
			break;
		}
	}
	input_boost_enabled = enabled;

	return 0;
}

static int get_input_boost_freq(char *buf, const struct kernel_param *kp)
{
	int cnt = 0, cpu;
	struct cpu_sync *s;

	for_each_possible_cpu(cpu) {
		s = &per_cpu(sync_info, cpu);
		cnt += snprintf(buf + cnt, PAGE_SIZE - cnt,
				"%d:%u ", cpu, s->input_boost_freq);
	}
	cnt += snprintf(buf + cnt, PAGE_SIZE - cnt, "\n");
	return cnt;
}

static const struct kernel_param_ops param_ops_input_boost_freq = {
	.set = set_input_boost_freq,
	.get = get_input_boost_freq,
};
module_param_cb(input_boost_freq, &param_ops_input_boost_freq, NULL, 0644);

/*
 * The CPUFREQ_ADJUST notifier is used to override the current policy min to
 * make sure policy min >= boost_min. The cpufreq framework then does the job
 * of enforcing the new policy.
 */
static int boost_adjust_notify(struct notifier_block *nb, unsigned long val,
			       void *data)
{
	struct cpufreq_policy *policy = data;
	unsigned int cpu = policy->cpu;
	struct cpu_sync *s = &per_cpu(sync_info, cpu);
	unsigned int ib_min = s->input_boost_min;

	switch (val) {
	case CPUFREQ_ADJUST:
		if (!ib_min)
			break;

		cpufreq_verify_within_limits(policy, ib_min, UINT_MAX);
		break;
	}

	return NOTIFY_OK;
}

static struct notifier_block boost_adjust_nb = {
	.notifier_call = boost_adjust_notify,
};

static void update_policy_online(void)
{
	unsigned int i;

	get_online_cpus();
	for_each_online_cpu(i) {
		cpufreq_update_policy(i);
	}
	put_online_cpus();
}

static void do_input_boost_rem(struct work_struct *work)
{
	unsigned int i;
	struct cpu_sync *i_sync_info;

	/* Reset the input_boost_min for all CPUs */
	for_each_possible_cpu(i) {
		i_sync_info = &per_cpu(sync_info, i);
		i_sync_info->input_boost_min = 0;
	}

	/* Update policies for all online CPUs */
	update_policy_online();

	if (sched_boost_active) {
		sched_set_boost(0);
		sched_boost_active = false;
	}
}

static void do_input_boost(struct work_struct *work)
{
	unsigned int i;
	struct cpu_sync *i_sync_info;

	cancel_delayed_work_sync(&input_boost_rem);

	if (sched_boost_active) {
		sched_set_boost(0);
		sched_boost_active = false;
	}

	/* Set the input_boost_min for all CPUs */
	for_each_possible_cpu(i) {
		i_sync_info = &per_cpu(sync_info, i);
		i_sync_info->input_boost_min = i_sync_info->input_boost_freq;
	}

	/* Update policies for all online CPUs */
	update_policy_online();

	/* Enable scheduler boost to migrate tasks to big cluster */
	if (sched_boost_on_input > 0) {
		int ret = sched_set_boost(sched_boost_on_input);
		if (ret)
			pr_err("sched boost enable failed\n");
		else
			sched_boost_active = true;
	}

	queue_delayed_work(cpu_boost_wq, &input_boost_rem,
			   msecs_to_jiffies(input_boost_ms));
}

static void cpuboost_input_event(struct input_handle *handle,
				 unsigned int type, unsigned int code,
				 int value)
{
	u64 now;

	if (!input_boost_enabled)
		return;

	now = ktime_to_us(ktime_get());
	if (now - last_input_time < MIN_INPUT_INTERVAL)
		return;

	if (work_pending(&input_boost_work))
		return;

	queue_work(cpu_boost_wq, &input_boost_work);
	last_input_time = ktime_to_us(ktime_get());
}

static int cpuboost_input_connect(struct input_handler *handler,
				  struct input_dev *dev,
				  const struct input_device_id *id)
{
	struct input_handle *handle;
	int error;

	handle = kzalloc(sizeof(*handle), GFP_KERNEL);
	if (!handle)
		return -ENOMEM;

	handle->dev = dev;
	handle->handler = handler;
	handle->name = "apex-cpuboost";

	error = input_register_handle(handle);
	if (error)
		goto err2;

	error = input_open_device(handle);
	if (error)
		goto err1;

	return 0;
err1:
	input_unregister_handle(handle);
err2:
	kfree(handle);
	return error;
}

static void cpuboost_input_disconnect(struct input_handle *handle)
{
	input_close_device(handle);
	input_unregister_handle(handle);
	kfree(handle);
}

static const struct input_device_id cpuboost_ids[] = {
	/* multi-touch touchscreen */
	{
		.flags = INPUT_DEVICE_ID_MATCH_EVBIT |
			INPUT_DEVICE_ID_MATCH_ABSBIT,
		.evbit = { BIT_MASK(EV_ABS) },
		.absbit = { [BIT_WORD(ABS_MT_POSITION_X)] =
			BIT_MASK(ABS_MT_POSITION_X) |
			BIT_MASK(ABS_MT_POSITION_Y) },
	},
	/* touchpad */
	{
		.flags = INPUT_DEVICE_ID_MATCH_KEYBIT |
			INPUT_DEVICE_ID_MATCH_ABSBIT,
		.keybit = { [BIT_WORD(BTN_TOUCH)] = BIT_MASK(BTN_TOUCH) },
		.absbit = { [BIT_WORD(ABS_X)] =
			BIT_MASK(ABS_X) | BIT_MASK(ABS_Y) },
	},
	/* Keypad */
	{
		.flags = INPUT_DEVICE_ID_MATCH_EVBIT,
		.evbit = { BIT_MASK(EV_KEY) },
	},
	{ },
};

static struct input_handler cpuboost_input_handler = {
	.event		= cpuboost_input_event,
	.connect	= cpuboost_input_connect,
	.disconnect	= cpuboost_input_disconnect,
	.name		= "apex-cpuboost",
	.id_table	= cpuboost_ids,
};

static int __init apex_cpu_boost_init(void)
{
	int cpu, ret;
	struct cpu_sync *s;
	struct cpufreq_policy *policy;

	cpu_boost_wq = alloc_workqueue("apex_cpuboost_wq", WQ_HIGHPRI, 0);
	if (!cpu_boost_wq)
		return -EFAULT;

	INIT_WORK(&input_boost_work, do_input_boost);
	INIT_DELAYED_WORK(&input_boost_rem, do_input_boost_rem);

	for_each_possible_cpu(cpu) {
		s = &per_cpu(sync_info, cpu);
		s->cpu = cpu;

		/* Set default boost frequency based on cluster */
		policy = cpufreq_cpu_get(cpu);
		if (policy) {
			if (policy->cpuinfo.max_freq >= BIG_CLUSTER_THRESHOLD)
				s->input_boost_freq = DEFAULT_BOOST_FREQ_BIG;
			else
				s->input_boost_freq = DEFAULT_BOOST_FREQ_LITTLE;
			cpufreq_cpu_put(policy);
		}
	}

	cpufreq_register_notifier(&boost_adjust_nb, CPUFREQ_POLICY_NOTIFIER);

	ret = input_register_handler(&cpuboost_input_handler);
	if (ret) {
		pr_err("failed to register input handler\n");
		destroy_workqueue(cpu_boost_wq);
		return ret;
	}

	pr_info("apex CPU boost loaded (boost_ms=%u, little=%u, big=%u)\n",
		input_boost_ms, DEFAULT_BOOST_FREQ_LITTLE, DEFAULT_BOOST_FREQ_BIG);
	return 0;
}
late_initcall(apex_cpu_boost_init);

static void __exit apex_cpu_boost_exit(void)
{
	input_unregister_handler(&cpuboost_input_handler);
	cpufreq_unregister_notifier(&boost_adjust_nb, CPUFREQ_POLICY_NOTIFIER);
	destroy_workqueue(cpu_boost_wq);
}
module_exit(apex_cpu_boost_exit);

MODULE_AUTHOR("APEX project");
MODULE_DESCRIPTION("apex CPU Boost — input-driven frequency booster for SM6225-AD");
MODULE_LICENSE("GPL v2");
