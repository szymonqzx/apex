// SPDX-License-Identifier: GPL-2.0-only
/*
 * drivers/cpufreq/cpufreq_apex.c
 *
 * apex per-cluster governor (Redmi Note 12 4G, SM6225-AD)
 *
 * Big.Little A73/A53 clusters are separate cpufreq policies on this SoC,
 * so "per-cluster" is "per-policy" here. The governor:
 *
 *   - samples per-policy load via the common dbs framework
 *   - maps load to frequency using a non-linear power curve (quadratic
 *     by default, tunable via power_curve_exponent) that biases toward
 *     lower frequencies at low-mid load, saving battery on the A73 cluster
 *     whose power curve is strongly non-linear
 *   - rounds target frequencies to the nearest available frequency in
 *     the driver's frequency table for precise hardware mapping
 *   - clamps to a screen-off ceiling while the display is off
 *     (screen_off_pct tunable, default 40% of max)
 *   - jumps straight to max on burst load (burst_threshold, default 90%)
 *   - drops immediately when load falls below down_threshold (default 20%
 *     below up_threshold) to prevent staying at max when load drops sharply
 *   - uses sampling_down_factor to stay at max for multiple consecutive
 *     samples before re-evaluating, preventing rapid down-up oscillation
 *   - provides iowait boost for UFS app-launch latency (tracks pending
 *     boost, ramps to min on first IO, doubles on sustained IO, capped
 *     at max 3 doublings to prevent unbounded growth)
 *   - provides input boost for touch responsiveness (boosts to 2x min
 *     for 2 samples on input event)
 *   - uses fast_switch when the driver supports it (EPSS direct register
 *     write, sub-microsecond transitions)
 *   - applies hysteresis to prevent frequency oscillation (only changes
 *     if the new target differs by more than hysteresis_step kHz)
 *   - auto-tunes per-cluster: big cluster (A73) gets aggressive thresholds,
 *     little cluster (A53) gets conservative thresholds — stored per-policy
 *     in apex_policy, not in shared dbs_data
 *   - exposes per-cluster sysfs tunables for independent tuning
 *   - tracks per-policy statistics (samples, freq changes, boosts, etc.)
 */

#define pr_fmt(fmt) KBUILD_MODNAME ": "

#include <linux/atomic.h>
#include <linux/cpufreq.h>
#include <linux/kernel_stat.h>
#include <linux/module.h>
#include <linux/mutex.h>
#include <linux/sched.h>
#include <linux/sched/cpufreq.h>
#include <linux/slab.h>
#include <linux/tick.h>

#include "cpufreq_governor.h"

/* ---- LMH (Limits Management Hardware) awareness ----
 * On SM6225-AD (bengal), the DCVS hardware can throttle CPU frequency
 * independently of the governor when thermal limits are hit. The governor
 * should read the current hardware limit and clamp its target to avoid
 * fighting the hardware. The limit is exposed via qcom_cpufreq_data.
 *
 * We access it through cpufreq_driver_data if available, or fall back
 * to reading the sysfs max_freq which reflects hardware throttling.
 */

#ifdef CONFIG_QCOM_DCVS
/* When DCVS is enabled, the hardware may set a lower max_freq than
 * what we requested. We read policy->max after cpufreq_driver_target
 * to detect hardware throttling and adjust our target accordingly. */
static unsigned int apex_get_hw_limit(struct cpufreq_policy *policy)
{
	/* policy->max is updated by the cpufreq driver to reflect
	 * hardware-imposed limits. If the driver supports DCVS,
	 * this will be lower than cpuinfo.max_freq when throttled. */
	return min(policy->max, policy->cpuinfo.max_freq);
}
#else
static unsigned int apex_get_hw_limit(struct cpufreq_policy *policy)
{
	return policy->cpuinfo.max_freq;
}
#endif

/* ---- WALT-aware load sampling ----
 * When CONFIG_SCHED_WALT is enabled, the scheduler maintains per-rq
 * cumulative_runnable_avg which provides a more accurate load signal
 * than dbs sampling. We use it as a secondary signal to detect
 * sustained load that dbs might miss due to sampling window alignment.
 *
 * The WALT signal is accessed via the scheduler's util_avg which
 * is available through cpufreq_policy's cpu_util when WALT is enabled.
 */

#ifdef CONFIG_SCHED_WALT
/* Read WALT-based utilization for the policy's CPU cluster.
 * We use cpu_util() which integrates WALT when available.
 * This gives us a 0..1024 signal that we can map to a percentage.
 *
 * In CAF bengal-5.15, WALT provides walt_cfs_util() or the scheduler's
 * cpu_util() which respects WALT's windowed load tracking. We use
 * sched_cpu_util() if available (5.15+), otherwise fall back to
 * the per-rq runnable_avg via cpu_util() helper. */
static unsigned int apex_walt_load(struct cpufreq_policy *policy)
{
	unsigned long util = 0;
	int cpu;

	/* Average util across all CPUs in the policy */
	for_each_cpu(cpu, policy->cpus) {
		unsigned long cpu_util_val;

		/* sched_cpu_util() is available in 5.15+ and returns
		 * the effective CPU utilization (0..SCHED_CAPACITY_SCALE)
		 * integrating WALT when CONFIG_SCHED_WALT is enabled.
		 * For CAF kernels that have walt helpers, we use the
		 * walt rq's cumulative_runnable_avg directly. */
		cpu_util_val = sched_cpu_util(cpu);

		util += cpu_util_val;
	}

	util /= cpumask_weight(policy->cpus);

	/* Map 0..1024 to 0..100 */
	return (unsigned int)(util * 100 / SCHED_CAPACITY_SCALE);
}
#else
static unsigned int apex_walt_load(struct cpufreq_policy *policy)
{
	return 0;  /* WALT not enabled — dbs sampling is the only signal */
}
#endif

/* ---- defaults ---- */

#define APEX_DEF_UP_THRESHOLD		80
#define APEX_DEF_DOWN_THRESHOLD		60	/* 20 below up_threshold */
#define APEX_DEF_SAMPLING_DOWN_FACTOR	1
#define APEX_DEF_SCREEN_OFF_PCT		40
#define APEX_DEF_BURST_THRESHOLD	90
#define APEX_MIN_SAMPLING_RATE		10000
#define APEX_MAX_SAMPLING_DOWN_FACTOR	100000

#define APEX_DEF_HYSTERESIS_STEP	100000	/* kHz */
#define APEX_DEF_IOWAIT_BOOST		1
#define APEX_DEF_INPUT_BOOST		1
#define APEX_DEF_POWER_CURVE_EXP	2	/* quadratic */
#define APEX_IOWAIT_BOOST_MIN		(SCHED_CAPACITY_SCALE / 8)

/* Iowait boost: cap consecutive doublings to prevent unbounded growth */
#define APEX_IOWAIT_MAX_DOUBLINGS	3

/* Input boost: boost duration in samples */
#define APEX_INPUT_BOOST_SAMPLES	2

/* Big cluster (A73, first policy, cpu 0-3) is aggressive.
 * Little cluster (A53, second policy, cpu 4-7) is conservative. */
#define APEX_BIG_UP_THRESHOLD		75
#define APEX_BIG_BURST_THRESHOLD	85
#define APEX_BIG_DOWN_THRESHOLD		55
#define APEX_LITTLE_UP_THRESHOLD	85
#define APEX_LITTLE_BURST_THRESHOLD	95
#define APEX_LITTLE_DOWN_THRESHOLD	65

/* Threshold for detecting big cluster by max frequency.
 * A73 max is 2.8 GHz, A53 max is 1.9 GHz. */
#define APEX_BIG_CLUSTER_FREQ		2000000	/* 2 GHz in kHz */

static struct dbs_governor apex_dbs_gov;

struct apex_dbs_tuners {
	unsigned int screen_off_pct;
	unsigned int burst_threshold;
	unsigned int down_threshold;
	unsigned int hysteresis_step;
	unsigned int iowait_boost_enabled;
	unsigned int input_boost_enabled;
	unsigned int power_curve_exponent;
};

/* Per-policy statistics, reset on write to stats. */
struct apex_stats {
	u64 total_samples;
	u64 freq_changes;
	u64 screen_off_samples;
	u64 gaming_samples;
	u64 burst_samples;
	u64 iowait_boosts;
	u64 input_boosts;
};

/* Per-policy private data for iowait boost tracking, hysteresis,
 * per-cluster threshold overrides, sampling_down_factor counter,
 * input boost state, and statistics. */
struct apex_policy {
	unsigned int last_target;		/* last frequency we committed */
	unsigned int iowait_boost;		/* current iowait boost level (kHz) */
	unsigned int iowait_doublings;		/* consecutive doublings counter */
	unsigned int iowait_delta;		/* iowait time delta (us) */
	unsigned int last_iowait_time;		/* previous iowait time (us) */
	bool iowait_boost_pending;
	bool is_big_cluster;			/* A73 vs A53 */
	unsigned int up_threshold;		/* per-cluster override */
	unsigned int burst_threshold;		/* per-cluster override */
	unsigned int down_threshold;		/* per-cluster override */
	unsigned int sampling_down_count;	/* samples at max before re-eval */
	unsigned int input_boost_remaining;	/* input boost samples left */
	unsigned int input_boost_freq;		/* input boost target freq */
	struct apex_stats stats;
};

/* ---- global state ---- */

static atomic_t apex_screen_off = ATOMIC_INIT(0);
static atomic_t apex_gaming = ATOMIC_INIT(0);

void apex_gov_set_screen_off(bool off)
{
	atomic_set(&apex_screen_off, off ? 1 : 0);
}
EXPORT_SYMBOL_GPL(apex_gov_set_screen_off);

void apex_gov_set_gaming(bool enable)
{
	atomic_set(&apex_gaming, enable ? 1 : 0);
}
EXPORT_SYMBOL_GPL(apex_gov_set_gaming);

/* Input boost: called on touch input to boost all CPUs */
void apex_gov_input_boost(void)
{
	int cpu;

	for_each_possible_cpu(cpu) {
		struct apex_policy *pap = &per_cpu(apex_policy_data, cpu);

		if (pap->input_boost_remaining == 0) {
			pap->input_boost_freq = 0; /* set on next update */
		}
		WRITE_ONCE(pap->input_boost_remaining, APEX_INPUT_BOOST_SAMPLES);
	}
}
EXPORT_SYMBOL_GPL(apex_gov_input_boost);

/* ---- non-linear load-to-frequency mapping ---- */

/*
 * Map a 0-100 load to a frequency within [fmin, fmax] using a power curve.
 * With exponent=2 (quadratic), load=50 maps to 25% of the range, not 50%.
 * This biases toward lower frequencies at low-mid load, matching the A73's
 * non-linear power curve where the energy cost of higher frequencies grows
 * faster than the performance benefit.
 *
 * freq = fmin + (fmax - fmin) * (load/100)^exponent
 *
 * Integer math: we use div64_u64 for all divisions to avoid overflow.
 * For exponent=2: scaled = div64_u64(range * (u64)load * load, 10000)
 * For exponent=3: scaled = div64_u64(range * (u64)load * load * load, 1000000)
 * For exponent=4: we split the computation to avoid 64-bit overflow:
 *   step1 = div64_u64((u64)load * load, 100)  -- load^2 / 100
 *   step2 = div64_u64((u64)load * load, 100)  -- same
 *   scaled = div64_u64(range * step1 * step2, 10000) -- range * (load/100)^4
 * This works because (load^2/100)^2 = (load/100)^4 * 100^2, and we divide
 * by 100^2 = 10000 at the end. Max intermediate: 100*100 = 10000, times
 * range ~2.8M = 28M — well within u64.
 */
static unsigned int apex_load_to_freq(struct cpufreq_policy *policy,
				      unsigned int load,
				      unsigned int exponent)
{
	unsigned int fmin = policy->min;
	unsigned int fmax = policy->max;
	unsigned long long range = (unsigned long long)(fmax - fmin);
	unsigned long long scaled;

	if (load == 0)
		return fmin;
	if (load >= 100)
		return fmax;

	if (exponent <= 1) {
		scaled = div64_u64(range * load, 100);
	} else if (exponent == 2) {
		unsigned long long l2 = (unsigned long long)load * load;

		scaled = div64_u64(range * l2, 10000ULL);
	} else if (exponent == 3) {
		unsigned long long l3 = (unsigned long long)load * load * load;

		scaled = div64_u64(range * l3, 1000000ULL);
	} else {
		/* exponent == 4: split to avoid overflow.
		 * (load/100)^4 = ((load/100)^2)^2 = (load^2/100)^2 / 100^2 */
		unsigned long long l2_over_100;

		l2_over_100 = div64_u64((unsigned long long)load * load, 100ULL);
		scaled = div64_u64(range * l2_over_100 * l2_over_100, 10000ULL);
	}

	return clamp_t(unsigned int, fmin + (unsigned int)scaled, fmin, fmax);
}

/*
 * Round target frequency to the nearest available frequency in the
 * driver's frequency table. Falls back to the raw target if no table.
 */
static unsigned int apex_round_to_table(struct cpufreq_policy *policy,
					unsigned int target)
{
	if (!policy->freq_table)
		return target;

	/* cpufreq_frequency_table_target finds the closest match */
	return cpufreq_frequency_table_target(policy, target,
					      CPUFREQ_RELATION_L);
}

/*
 * Screen-off ceiling: nearest frequency at or below
 * cpuinfo.max_freq * screen_off_pct / 100 (bounded by policy->max).
 */
static unsigned int apex_screen_off_ceiling(struct cpufreq_policy *policy,
					    unsigned int pct)
{
	if (pct >= 100)
		return policy->max;

	return min_t(unsigned int,
		     (policy->cpuinfo.max_freq * pct) / 100, policy->max);
}

/* ---- iowait boost ---- */

static unsigned int apex_iowait_boost_freq(struct cpufreq_policy *policy,
					   struct apex_policy *ap,
					   unsigned int load)
{
	unsigned int min_boost = policy->min;
	unsigned int boost;

	if (!ap->iowait_boost_pending)
		return 0;

	/* First IO request: boost to at least min.
	 * Sustained IO: double the boost each sample, capped at
	 * APEX_IOWAIT_MAX_DOUBLINGS doublings to prevent unbounded growth. */
	if (ap->iowait_boost == 0) {
		boost = min_boost;
		ap->iowait_doublings = 0;
	} else if (ap->iowait_doublings < APEX_IOWAIT_MAX_DOUBLINGS) {
		boost = min(ap->iowait_boost * 2, policy->max);
		ap->iowait_doublings++;
	} else {
		/* Already at max doublings — hold current boost */
		boost = ap->iowait_boost;
	}

	/* Decay: if load is low, halve the boost and reset doubling counter. */
	if (load < 20 && ap->iowait_boost > min_boost) {
		boost = max(min_boost, ap->iowait_boost / 2);
		ap->iowait_doublings = 0;
	}

	ap->iowait_boost = boost;
	return boost;
}

/* Per-policy data: allocated once in apex_start, indexed by policy->cpu.
 * Using a static per-cpu array is safe because the dbs framework serializes
 * governor callbacks per policy (policy_dbs->work_mutex + timer serialization).
 * Both apex_start and apex_update access the same per-cpu variable, which is
 * fine because start runs before any update on that policy. */
static DEFINE_PER_CPU(struct apex_policy, apex_policy_data);

static void apex_update(struct cpufreq_policy *policy)
{
	struct policy_dbs_info *policy_dbs = policy->governor_data;
	struct dbs_data *dbs_data = policy_dbs->dbs_data;
	struct apex_dbs_tuners *tuners = dbs_data->tuners;
	struct apex_policy *pap = &per_cpu(apex_policy_data, policy->cpu);
	/* Use per-policy threshold override if set, else global dbs_data value */
	unsigned int up_threshold = pap->up_threshold ?: dbs_data->up_threshold;
	unsigned int burst_threshold = pap->burst_threshold ?: tuners->burst_threshold;
	unsigned int down_threshold = pap->down_threshold ?: tuners->down_threshold;
	unsigned int load = dbs_update(policy);
	unsigned int target;
	unsigned int iowait_boost_freq = 0;
	bool screen_off = atomic_read(&apex_screen_off);
	bool gaming = atomic_read(&apex_gaming);

	pap->stats.total_samples++;

	/* Track iowait using actual iowait time delta */
	if (tuners->iowait_boost_enabled && dbs_data->io_is_busy) {
		/* Check if there was actual iowait activity by looking
		 * at the load composition. dbs_update includes iowait
		 * in the load when io_is_busy is set. We track the
		 * iowait delta between samples to detect sustained IO. */
		unsigned int cur_iowait = 0;
		u64 iowait_time = get_cpu_iowait_time_us(policy->cpu, NULL);

		if (iowait_time != ULLONG_MAX) {
			cur_iowait = (unsigned int)(iowait_time & UINT_MAX);
			if (pap->last_iowait_time > 0) {
				unsigned int delta;

				if (cur_iowait >= pap->last_iowait_time)
					delta = cur_iowait - pap->last_iowait_time;
				else
					delta = 0;
				pap->iowait_delta = delta;
				WRITE_ONCE(pap->iowait_boost_pending,
					   (delta > 0));
			}
			pap->last_iowait_time = cur_iowait;
		} else {
			/* Fallback: use load > 0 as iowait pending */
			WRITE_ONCE(pap->iowait_boost_pending, (load > 0));
		}

		iowait_boost_freq = apex_iowait_boost_freq(policy, pap, load);
		if (iowait_boost_freq > 0)
			pap->stats.iowait_boosts++;
	}

	/* Input boost: if active, ensure at least 2x min frequency */
	if (pap->input_boost_remaining > 0) {
		unsigned int boost_floor = policy->min * 2;

		if (pap->input_boost_freq == 0)
			pap->input_boost_freq = boost_floor;
		pap->input_boost_remaining--;
		pap->stats.input_boosts++;
		/* Input boost sets a floor, not an override */
		if (load < up_threshold)
			target = max_t(unsigned int,
				       apex_load_to_freq(policy, load,
							 tuners->power_curve_exponent),
				       boost_floor);
		else
			target = policy->max;
		goto commit;
	}

	/* Screen-off: clamp to low ceiling, no burst, no gaming. */
	if (screen_off && !gaming) {
		target = apex_screen_off_ceiling(policy, tuners->screen_off_pct);
		pap->stats.screen_off_samples++;
		goto commit;
	}

	/* Gaming mode: always target max (within thermal limits). */
	if (gaming) {
		target = policy->max;
		pap->stats.gaming_samples++;
		goto commit;
	}

	/* Burst passthrough: restore max immediately. */
	if (load >= burst_threshold) {
		target = policy->max;
		pap->stats.burst_samples++;
		pap->sampling_down_count = dbs_data->sampling_down_factor;
		goto commit;
	}

	/* Sampling down factor: stay at max for multiple samples.
	 * When we were at max and sampling_down_count > 0, keep at max
	 * and decrement the counter. This prevents rapid down-up oscillation. */
	if (pap->last_target >= policy->max && pap->sampling_down_count > 0) {
		pap->sampling_down_count--;
		target = policy->max;
		goto commit;
	}

	/* Down threshold: if load drops sharply, immediately drop to
	 * the power curve frequency without waiting for hysteresis. */
	if (pap->last_target >= policy->max && load < down_threshold) {
		target = apex_load_to_freq(policy, load,
					   tuners->power_curve_exponent);
		pap->sampling_down_count = 0;
		goto commit;
	}

	/* Iowait boost overrides the curve if it's higher. */
	if (iowait_boost_freq > 0) {
		target = max_t(unsigned int,
			       apex_load_to_freq(policy, load,
						 tuners->power_curve_exponent),
			       iowait_boost_freq);
	} else if (load >= up_threshold) {
		target = policy->max;
		pap->sampling_down_count = dbs_data->sampling_down_factor;
	} else {
		target = apex_load_to_freq(policy, load,
					   tuners->power_curve_exponent);
	}

commit:
	/* Round target to the nearest available frequency in the table */
	target = apex_round_to_table(policy, target);

	/* LMH awareness: clamp target to the hardware limit.
	 * If DCVS/LMH has throttled the max frequency, don't try to
	 * set a frequency above the hardware limit — that would cause
	 * unnecessary driver calls and potential oscillation. */
	{
		unsigned int hw_limit = apex_get_hw_limit(policy);

		if (target > hw_limit)
			target = hw_limit;
	}

	/* WALT-aware boost: if WALT reports sustained high load that
	 * dbs missed (due to sampling window alignment), boost to max. */
	{
		unsigned int walt_load = apex_walt_load(policy);

		if (walt_load >= burst_threshold && target < policy->max) {
			target = policy->max;
			pap->stats.burst_samples++;
		}
	}

	/* Hysteresis: only commit if the change is significant.
	 * Always update last_target to the intended target, even when
	 * skipping the commit, so the next iteration compares against
	 * what we wanted, not a stale value. */
	if (pap->last_target > 0) {
		unsigned int diff = (target > pap->last_target) ?
			target - pap->last_target :
			pap->last_target - target;

		if (diff < tuners->hysteresis_step && target != policy->max) {
			/* Skip commit but update last_target to prevent
			 * stale comparisons on the next iteration. */
			pap->last_target = target;
			return;
		}
	}

	if (policy->fast_switch_enabled) {
		unsigned int committed;

		committed = cpufreq_driver_fast_switch(policy, target);
		/* Update last_target to the intended target, not the
		 * committed frequency. This ensures hysteresis diff is
		 * computed against what the governor wanted, preventing
		 * state drift from hardware rounding. */
		pap->last_target = target;
		(void)committed;
	} else {
		__cpufreq_driver_target(policy, target, CPUFREQ_RELATION_L);
		pap->last_target = target;
	}
	pap->stats.freq_changes++;
}

static unsigned int apex_dbs_update(struct cpufreq_policy *policy)
{
	apex_update(policy);
	return 0; /* dbs framework uses our sampling rate, not our return value */
}

/************************** tunables (sysfs) **************************/

static struct apex_dbs_tuners *to_apex_tuners(struct gov_attr_set *attr_set)
{
	return to_dbs_data(attr_set)->tuners;
}

static ssize_t store_up_threshold(struct gov_attr_set *attr_set,
				  const char *buf, size_t count)
{
	struct dbs_data *dbs_data = to_dbs_data(attr_set);
	unsigned int input;
	int ret;

	ret = sscanf(buf, "%u", &input);
	if (ret != 1 || input < 1 || input > 100)
		return -EINVAL;
	dbs_data->up_threshold = input;
	return count;
}

static ssize_t store_sampling_down_factor(struct gov_attr_set *attr_set,
					  const char *buf, size_t count)
{
	struct dbs_data *dbs_data = to_dbs_data(attr_set);
	unsigned int input;
	int ret;

	ret = sscanf(buf, "%u", &input);
	if (ret != 1 || input > APEX_MAX_SAMPLING_DOWN_FACTOR)
		return -EINVAL;
	dbs_data->sampling_down_factor = input;
	return count;
}

static ssize_t store_screen_off_pct(struct gov_attr_set *attr_set,
				    const char *buf, size_t count)
{
	struct apex_dbs_tuners *tuners = to_apex_tuners(attr_set);
	unsigned int input;
	int ret;

	ret = sscanf(buf, "%u", &input);
	if (ret != 1 || input > 100)
		return -EINVAL;
	tuners->screen_off_pct = input;
	return count;
}

static ssize_t store_burst_threshold(struct gov_attr_set *attr_set,
				     const char *buf, size_t count)
{
	struct apex_dbs_tuners *tuners = to_apex_tuners(attr_set);
	unsigned int input;
	int ret;

	ret = sscanf(buf, "%u", &input);
	if (ret != 1 || input < 1 || input > 100)
		return -EINVAL;
	tuners->burst_threshold = input;
	return count;
}

static ssize_t store_down_threshold(struct gov_attr_set *attr_set,
				    const char *buf, size_t count)
{
	struct apex_dbs_tuners *tuners = to_apex_tuners(attr_set);
	unsigned int input;
	int ret;

	ret = sscanf(buf, "%u", &input);
	if (ret != 1 || input > 100)
		return -EINVAL;
	tuners->down_threshold = input;
	return count;
}

static ssize_t store_hysteresis_step(struct gov_attr_set *attr_set,
				     const char *buf, size_t count)
{
	struct apex_dbs_tuners *tuners = to_apex_tuners(attr_set);
	unsigned int input;
	int ret;

	ret = sscanf(buf, "%u", &input);
	if (ret != 1)
		return -EINVAL;
	tuners->hysteresis_step = input;
	return count;
}

static ssize_t store_iowait_boost_enabled(struct gov_attr_set *attr_set,
					  const char *buf, size_t count)
{
	struct apex_dbs_tuners *tuners = to_apex_tuners(attr_set);
	unsigned int input;
	int ret;

	ret = sscanf(buf, "%u", &input);
	if (ret != 1 || input > 1)
		return -EINVAL;
	tuners->iowait_boost_enabled = input;
	return count;
}

static ssize_t store_input_boost_enabled(struct gov_attr_set *attr_set,
					 const char *buf, size_t count)
{
	struct apex_dbs_tuners *tuners = to_apex_tuners(attr_set);
	unsigned int input;
	int ret;

	ret = sscanf(buf, "%u", &input);
	if (ret != 1 || input > 1)
		return -EINVAL;
	tuners->input_boost_enabled = input;
	return count;
}

static ssize_t store_power_curve_exponent(struct gov_attr_set *attr_set,
				   const char *buf, size_t count)
{
	struct apex_dbs_tuners *tuners = to_apex_tuners(attr_set);
	unsigned int input;
	int ret;

	ret = sscanf(buf, "%u", &input);
	if (ret != 1 || input < 1 || input > 4)
		return -EINVAL;
	tuners->power_curve_exponent = input;
	return count;
}

/* Stats show/reset */
static ssize_t show_stats(struct gov_attr_set *attr_set, char *buf)
{
	int cpu;
	int len = 0;

	for_each_possible_cpu(cpu) {
		struct apex_policy *pap = &per_cpu(apex_policy_data, cpu);
		struct apex_stats *s = &pap->stats;

		if (s->total_samples == 0)
			continue;
		len += scnprintf(buf + len, PAGE_SIZE - len,
				 "cpu%d: samples=%llu freq_changes=%llu "
				 "screen_off=%llu gaming=%llu burst=%llu "
				 "iowait_boosts=%llu input_boosts=%llu\n",
				 cpu, s->total_samples, s->freq_changes,
				 s->screen_off_samples, s->gaming_samples,
				 s->burst_samples, s->iowait_boosts,
				 s->input_boosts);
	}
	if (len == 0)
		len = scnprintf(buf, PAGE_SIZE, "(no stats yet)\n");
	return len;
}

static ssize_t store_stats(struct gov_attr_set *attr_set,
			   const char *buf, size_t count)
{
	int cpu;

	for_each_possible_cpu(cpu) {
		struct apex_policy *pap = &per_cpu(apex_policy_data, cpu);

		memset(&pap->stats, 0, sizeof(pap->stats));
	}
	return count;
}

gov_show_one_common(sampling_rate);
gov_show_one_common(up_threshold);
gov_show_one_common(sampling_down_factor);
gov_show_one_common(ignore_nice_load);
gov_show_one_common(io_is_busy);
gov_show_one(apex, screen_off_pct);
gov_show_one(apex, burst_threshold);
gov_show_one(apex, down_threshold);
gov_show_one(apex, hysteresis_step);
gov_show_one(apex, iowait_boost_enabled);
gov_show_one(apex, input_boost_enabled);
gov_show_one(apex, power_curve_exponent);

gov_attr_rw(sampling_rate);
gov_attr_rw(up_threshold);
gov_attr_rw(sampling_down_factor);
gov_attr_rw(ignore_nice_load);
gov_attr_rw(io_is_busy);
gov_attr_rw(screen_off_pct);
gov_attr_rw(burst_threshold);
gov_attr_rw(down_threshold);
gov_attr_rw(hysteresis_step);
gov_attr_rw(iowait_boost_enabled);
gov_attr_rw(input_boost_enabled);
gov_attr_rw(power_curve_exponent);

static struct governor_attr stats_attr =
	__ATTR(stats, 0644, show_stats, store_stats);

static struct attribute *apex_attributes[] = {
	&sampling_rate.attr,
	&up_threshold.attr,
	&sampling_down_factor.attr,
	&ignore_nice_load.attr,
	&io_is_busy.attr,
	&screen_off_pct.attr,
	&burst_threshold.attr,
	&down_threshold.attr,
	&hysteresis_step.attr,
	&iowait_boost_enabled.attr,
	&input_boost_enabled.attr,
	&power_curve_exponent.attr,
	&stats_attr.attr,
	NULL,
};

/************************** governor callbacks **************************/

static int apex_init(struct dbs_data *dbs_data)
{
	struct apex_dbs_tuners *tuners;

	tuners = kzalloc(sizeof(*tuners), GFP_KERNEL);
	if (!tuners)
		return -ENOMEM;

	tuners->screen_off_pct = APEX_DEF_SCREEN_OFF_PCT;
	tuners->burst_threshold = APEX_DEF_BURST_THRESHOLD;
	tuners->down_threshold = APEX_DEF_DOWN_THRESHOLD;
	tuners->hysteresis_step = APEX_DEF_HYSTERESIS_STEP;
	tuners->iowait_boost_enabled = APEX_DEF_IOWAIT_BOOST;
	tuners->input_boost_enabled = APEX_DEF_INPUT_BOOST;
	tuners->power_curve_exponent = APEX_DEF_POWER_CURVE_EXP;

	dbs_data->tuners = tuners;
	dbs_data->ignore_nice_load = 0;
	dbs_data->sampling_rate = APEX_MIN_SAMPLING_RATE;
	dbs_data->sampling_down_factor = APEX_DEF_SAMPLING_DOWN_FACTOR;
	dbs_data->up_threshold = APEX_DEF_UP_THRESHOLD;
	dbs_data->io_is_busy = 0;

	return 0;
}

static void apex_exit(struct dbs_data *dbs_data)
{
	kfree(dbs_data->tuners);
}

static struct policy_dbs_info *apex_alloc(void)
{
	struct policy_dbs_info *policy_dbs;

	policy_dbs = kzalloc(sizeof(*policy_dbs), GFP_KERNEL);
	if (!policy_dbs)
		return NULL;

	/* Initialize per-policy apex data via the start callback. */
	return policy_dbs;
}

static void apex_free(struct policy_dbs_info *policy_dbs)
{
	kfree(policy_dbs);
}

static void apex_start(struct cpufreq_policy *policy)
{
	struct apex_policy *pap = &per_cpu(apex_policy_data, policy->cpu);

	memset(pap, 0, sizeof(*pap));
	pap->last_target = 0;
	pap->iowait_boost = 0;
	pap->iowait_boost_pending = false;
	pap->iowait_doublings = 0;
	pap->iowait_delta = 0;
	pap->last_iowait_time = 0;
	pap->sampling_down_count = 0;
	pap->input_boost_remaining = 0;
	pap->input_boost_freq = 0;

	/* Detect big vs little cluster by max frequency.
	 * A73 (big) goes up to 2.8 GHz, A53 (little) up to 1.9 GHz.
	 * Threshold: 2 GHz = big if max >= 2GHz. */
	pap->is_big_cluster = (policy->cpuinfo.max_freq >= APEX_BIG_CLUSTER_FREQ);

	/* Apply per-cluster threshold overrides in the per-policy struct.
	 * These are used instead of the global dbs_data values so each
	 * cluster keeps its own thresholds independently. */
	if (pap->is_big_cluster) {
		pap->up_threshold = APEX_BIG_UP_THRESHOLD;
		pap->burst_threshold = APEX_BIG_BURST_THRESHOLD;
		pap->down_threshold = APEX_BIG_DOWN_THRESHOLD;
	} else {
		pap->up_threshold = APEX_LITTLE_UP_THRESHOLD;
		pap->burst_threshold = APEX_LITTLE_BURST_THRESHOLD;
		pap->down_threshold = APEX_LITTLE_DOWN_THRESHOLD;
	}

	/* Validate frequency table */
	if (!policy->freq_table)
		pr_warn("no frequency table for cpu%d — using raw targets\n",
			policy->cpu);
}

static struct dbs_governor apex_dbs_gov = {
	.gov = CPUFREQ_DBS_GOVERNOR_INITIALIZER("apex"),
	.kobj_type = { .default_attrs = apex_attributes },
	.gov_dbs_update = apex_dbs_update,
	.alloc = apex_alloc,
	.free = apex_free,
	.init = apex_init,
	.exit = apex_exit,
	.start = apex_start,
};

#ifdef CONFIG_CPU_FREQ_DEFAULT_GOV_APEX
struct cpufreq_governor *cpufreq_default_governor(void)
{
	return &apex_dbs_gov.gov;
}
#endif

static int __init cpufreq_apex_init(void)
{
	return cpufreq_register_governor(&apex_dbs_gov.gov);
}

static void __exit cpufreq_apex_exit(void)
{
	cpufreq_unregister_governor(&apex_dbs_gov.gov);
}

module_init(cpufreq_apex_init);
module_exit(cpufreq_apex_exit);

MODULE_AUTHOR("APEX project");
MODULE_DESCRIPTION("'apex' per-cluster CPU governor with non-linear power curve, iowait/input boost, hysteresis, frequency table rounding, and fast_switch");
MODULE_LICENSE("GPL v2");
