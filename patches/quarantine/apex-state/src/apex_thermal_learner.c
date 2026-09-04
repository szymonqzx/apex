// SPDX-License-Identifier: GPL-2.0-only
/*
 * apex_thermal_learner.c — 7-day thermal learning engine
 *
 * Ring buffer of 7 days × 24 hours × 12 samples/hour = 2,016 entries.
 * Each entry: temperature, cluster frequencies, foreground UID.
 * After 7 days: compute per-hour-of-day percentile temperatures.
 * Adjust trip points by ±2°C based on 90th percentile.
 * Persist across reboots via /persist/apex/thermal_profile.bin.
 * Expose learner state via /proc/apex/thermal_profile.
 */

#include <linux/slab.h>
#include <linux/fs.h>
#include <linux/uaccess.h>
#include <linux/seq_file.h>
#include <linux/sort.h>
#include <linux/string.h>
#include <linux/timekeeping.h>
#include <linux/cpufreq.h>
#include <linux/build_bug.h>

#include "apex_thermal_learner.h"

/* Compile-time safety: ensure the sort buffer in compute() stays bounded.
 * 7 days × 12 samples = 84 ints = 336 bytes — well within 8KB kernel stack. */
BUILD_BUG_ON(APEX_LEARNER_DAYS * APEX_LEARNER_SAMPLES_PER_HOUR > APEX_LEARNER_MAX_SORT_BUF);

/* ---- private helpers ---- */

/* Get current hour-of-day (0..23) from wall clock */
static unsigned int apex_learner_current_hour(void)
{
	struct timespec64 ts;
	struct tm tm;

	ktime_get_real_ts64(&ts);
	time64_to_tm(ts.tv_sec, 0, &tm);
	return (unsigned int)tm.tm_hour;
}

/* Comparison function for sorting temperature arrays */
static int cmp_int(const void *a, const void *b)
{
	int ia = *(const int *)a;
	int ib = *(const int *)b;

	return (ia > ib) - (ia < ib);
}

/* Compute percentile of a sorted array.
 * p is 0..100. Returns the percentile value. */
static int percentile_of_sorted(const int *arr, unsigned int n, unsigned int p)
{
	unsigned int idx;

	if (n == 0)
		return 0;
	if (n == 1)
		return arr[0];

	/* idx = ceil(p/100 * (n-1)) — nearest-rank method */
	idx = ((p * (n - 1)) + 99) / 100;
	if (idx >= n)
		idx = n - 1;
	return arr[idx];
}

/* ---- public API ---- */

void apex_learner_init(struct apex_learner *l)
{
	memset(l, 0, sizeof(*l));
	l->trips.warn_deg = APEX_LEARNER_BASE_WARN;
	l->trips.throttle_deg = APEX_LEARNER_BASE_THROTTLE;
	l->trips.critical_deg = APEX_LEARNER_BASE_CRITICAL;
	l->trips.adjusted = false;
	l->current_hour = apex_learner_current_hour();

	/* Try to load persisted profile */
	if (apex_learner_load(l) == 0) {
		l->loaded_from_persist = true;
		pr_info("apex learner: loaded persisted profile (days=%u)\n",
			l->days_collected);
	} else {
		pr_info("apex learner: no persisted profile, starting fresh\n");
	}
}

/* Add a thermal sample to the ring buffer.
 * Called every 5 minutes from the health tick. */
void apex_learner_add_sample(struct apex_learner *l, int temp,
			     int big_freq, int little_freq, uid_t fg_uid)
{
	unsigned int hour = apex_learner_current_hour();
	struct apex_thermal_sample *s;

	/* Detect hour rollover */
	if (hour != l->current_hour) {
		l->current_hour = hour;
		l->samples_this_hour = 0;

		/* Check if we've completed a full day (24 hours cycled).
		 * A full day = 24 hours × 12 samples = 288 slots. */
		if (l->write_idx > 0 &&
		    (l->write_idx % (APEX_LEARNER_HOURS * APEX_LEARNER_SAMPLES_PER_HOUR)) == 0) {
			l->days_collected++;
			if (l->days_collected >= APEX_LEARNER_DAYS) {
				l->days_collected = APEX_LEARNER_DAYS;
				/* Recompute trip points */
				apex_learner_compute(l);
				/* Persist the updated profile */
				apex_learner_save(l);
			}
		}
	}

	/* Write sample to ring buffer */
	s = &l->samples[l->write_idx];
	s->temp = temp;
	s->big_freq = big_freq;
	s->little_freq = little_freq;
	s->fg_uid = fg_uid;

	l->write_idx = (l->write_idx + 1) % APEX_LEARNER_TOTAL_SLOTS;
	l->samples_this_hour++;

	/* Track max samples per hour for stats */
	if (l->samples_this_hour > APEX_LEARNER_SAMPLES_PER_HOUR)
		l->samples_this_hour = APEX_LEARNER_SAMPLES_PER_HOUR;
}

/* Compute per-hour-of-day statistics and adjust trip points.
 * Called after 7 days of data collected, or manually. */
void apex_learner_compute(struct apex_learner *l)
{
	int temp_buf[APEX_LEARNER_DAYS * APEX_LEARNER_SAMPLES_PER_HOUR];
	unsigned int hour, day, sample;
	int p90_sum = 0;
	int p90_avg;
	int adj;

	for (hour = 0; hour < APEX_LEARNER_HOURS; hour++) {
		unsigned int count = 0;

		for (day = 0; day < APEX_LEARNER_DAYS; day++) {
			for (sample = 0; sample < APEX_LEARNER_SAMPLES_PER_HOUR; sample++) {
				unsigned int idx = (day * APEX_LEARNER_HOURS +
						    hour) * APEX_LEARNER_SAMPLES_PER_HOUR + sample;
				if (idx < APEX_LEARNER_TOTAL_SLOTS) {
					int t = l->samples[idx].temp;
					if (t > 0)  /* skip uninitialized/zero */
						temp_buf[count++] = t;
				}
			}
		}

		if (count == 0) {
			l->hourly[hour].p50 = 0;
			l->hourly[hour].p90 = 0;
			l->hourly[hour].p99 = 0;
			l->hourly[hour].min_temp = 0;
			l->hourly[hour].max_temp = 0;
			l->hourly[hour].sample_count = 0;
			continue;
		}

		sort(temp_buf, count, sizeof(int), cmp_int, NULL);

		l->hourly[hour].p50 = percentile_of_sorted(temp_buf, count, 50);
		l->hourly[hour].p90 = percentile_of_sorted(temp_buf, count, 90);
		l->hourly[hour].p99 = percentile_of_sorted(temp_buf, count, 99);
		l->hourly[hour].min_temp = temp_buf[0];
		l->hourly[hour].max_temp = temp_buf[count - 1];
		l->hourly[hour].sample_count = count;

		p90_sum += l->hourly[hour].p90;
	}

	/* Average 90th percentile across all 24 hours */
	p90_avg = p90_sum / APEX_LEARNER_HOURS;

	/* Adjust trip points: shift baseline by (p90_avg - baseline_warn)
	 * clamped to ±2°C. If the device runs consistently hotter than
	 * the baseline, raise trip points (more tolerant). If cooler,
	 * lower them (more aggressive throttling). */
	adj = p90_avg - APEX_LEARNER_BASE_WARN;
	if (adj > APEX_LEARNER_ADJUST_MAX)
		adj = APEX_LEARNER_ADJUST_MAX;
	if (adj < -APEX_LEARNER_ADJUST_MAX)
		adj = -APEX_LEARNER_ADJUST_MAX;

	l->trips.warn_deg = APEX_LEARNER_BASE_WARN + adj;
	l->trips.throttle_deg = APEX_LEARNER_BASE_THROTTLE + adj;
	l->trips.critical_deg = APEX_LEARNER_BASE_CRITICAL + adj;
	l->trips.adjusted = true;

	pr_info("apex learner: trip points adjusted (warn=%d, throttle=%d, critical=%d, adj=%+d)\n",
		l->trips.warn_deg, l->trips.throttle_deg,
		l->trips.critical_deg, adj);
}

/* Persist learner state to /persist/apex/thermal_profile.bin
 * Writes a versioned header followed by the learner struct. */
int apex_learner_save(const struct apex_learner *l)
{
	struct file *f;
	loff_t pos = 0;
	ssize_t ret;
	struct apex_learner_persist_header hdr = {
		.magic = APEX_LEARNER_PERSIST_MAGIC,
		.version = APEX_LEARNER_PERSIST_VERSION,
		.struct_size = sizeof(*l),
		.reserved = 0,
	};

	f = filp_open(APEX_LEARNER_PERSIST_PATH, O_WRONLY | O_CREAT, 0600);
	if (IS_ERR(f))
		return PTR_ERR(f);

	/* Write header */
	ret = kernel_write(f, (const char *)&hdr, sizeof(hdr), &pos);
	if (ret != (ssize_t)sizeof(hdr)) {
		pr_warn("apex learner: short header write (%zd/%zu)\n",
			ret, sizeof(hdr));
		filp_close(f, NULL);
		return -EIO;
	}

	/* Write learner struct */
	ret = kernel_write(f, (const char *)l, sizeof(*l), &pos);
	filp_close(f, NULL);

	if (ret != (ssize_t)sizeof(*l)) {
		pr_warn("apex learner: short write to persist file (%zd/%zu)\n",
			ret, sizeof(*l));
		return -EIO;
	}

	pr_info("apex learner: profile persisted (hdr+body=%zu bytes)\n",
		sizeof(hdr) + sizeof(*l));
	return 0;
}

/* Load learner state from /persist/apex/thermal_profile.bin
 * Validates magic, version, and struct size before copying. */
int apex_learner_load(struct apex_learner *l)
{
	struct file *f;
	loff_t pos = 0;
	ssize_t ret;
	struct apex_learner_persist_header hdr;
	struct apex_learner tmp;

	f = filp_open(APEX_LEARNER_PERSIST_PATH, O_RDONLY, 0);
	if (IS_ERR(f))
		return PTR_ERR(f);

	/* Read and validate header */
	ret = kernel_read(f, (char *)&hdr, sizeof(hdr), &pos);
	if (ret != (ssize_t)sizeof(hdr)) {
		pr_warn("apex learner: short header read (%zd/%zu)\n",
			ret, sizeof(hdr));
		filp_close(f, NULL);
		return -EIO;
	}

	if (hdr.magic != APEX_LEARNER_PERSIST_MAGIC) {
		pr_warn("apex learner: bad magic 0x%08x (expected 0x%08x)\n",
			hdr.magic, APEX_LEARNER_PERSIST_MAGIC);
		filp_close(f, NULL);
		return -EINVAL;
	}

	if (hdr.version != APEX_LEARNER_PERSIST_VERSION) {
		pr_warn("apex learner: persist version %u unsupported (expected %u)\n",
			hdr.version, APEX_LEARNER_PERSIST_VERSION);
		filp_close(f, NULL);
		return -EINVAL;
	}

	if (hdr.struct_size != sizeof(tmp)) {
		pr_warn("apex learner: struct size mismatch (%u vs %zu)\n",
			hdr.struct_size, sizeof(tmp));
		filp_close(f, NULL);
		return -EINVAL;
	}

	/* Read learner struct */
	ret = kernel_read(f, (char *)&tmp, sizeof(tmp), &pos);
	filp_close(f, NULL);

	if (ret != (ssize_t)sizeof(tmp)) {
		pr_warn("apex learner: short read from persist file (%zd/%zu)\n",
			ret, sizeof(tmp));
		return -EIO;
	}

	/* Validate loaded fields before applying */
	if (tmp.write_idx >= APEX_LEARNER_TOTAL_SLOTS) {
		pr_warn("apex learner: loaded write_idx %u out of range, resetting\n",
			tmp.write_idx);
		tmp.write_idx = 0;
	}
	if (tmp.days_collected > APEX_LEARNER_DAYS) {
		pr_warn("apex learner: loaded days_collected %u out of range, clamping\n",
			tmp.days_collected);
		tmp.days_collected = APEX_LEARNER_DAYS;
	}
	if (tmp.current_hour >= APEX_LEARNER_HOURS) {
		pr_warn("apex learner: loaded current_hour %u out of range, resetting\n",
			tmp.current_hour);
		tmp.current_hour = 0;
	}

	/* Copy validated state, preserving current trip points if adjusted */
	memcpy(l, &tmp, sizeof(tmp));
	return 0;
}

/* Show learner state via seq_file for /proc/apex/thermal_profile */
void apex_learner_show(struct seq_file *m, const struct apex_learner *l)
{
	unsigned int hour;

	seq_printf(m, "learner_days_collected: %u / %u\n",
		   l->days_collected, APEX_LEARNER_DAYS);
	seq_printf(m, "learner_write_idx: %u / %u\n",
		   l->write_idx, APEX_LEARNER_TOTAL_SLOTS);
	seq_printf(m, "learner_loaded_from_persist: %s\n",
		   l->loaded_from_persist ? "yes" : "no");
	seq_printf(m, "trip_points_adjusted: %s\n",
		   l->trips.adjusted ? "yes" : "no (using defaults)");
	seq_printf(m, "trip_warn: %d C\n", l->trips.warn_deg);
	seq_printf(m, "trip_throttle: %d C\n", l->trips.throttle_deg);
	seq_printf(m, "trip_critical: %d C\n", l->trips.critical_deg);
	seq_printf(m, "\n");
	seq_printf(m, "hourly_stats (hour: p50 p90 p99 min max samples):\n");

	for (hour = 0; hour < APEX_LEARNER_HOURS; hour++) {
		const struct apex_hourly_stats *h = &l->hourly[hour];

		if (h->sample_count == 0)
			continue;
		seq_printf(m, "  %02u: %d %d %d %d %d %u\n",
			   hour, h->p50, h->p90, h->p99,
			   h->min_temp, h->max_temp, h->sample_count);
	}
}
