/* SPDX-License-Identifier: GPL-2.0-only */
/*
 * apex_thermal_learner.h — 7-day thermal learning engine
 *
 * Ring buffer of 7 days × 24 hours × 12 samples/hour = 2,016 entries.
 * Each entry: temperature, cluster frequencies, foreground UID.
 * After 7 days: compute per-hour-of-day percentile temperatures.
 * Adjust trip points by ±2°C based on 90th percentile.
 * Persist across reboots via /persist/apex/thermal_profile.bin.
 * Expose learner state via /proc/apex/thermal_profile.
 */

#ifndef APEX_THERMAL_LEARNER_H
#define APEX_THERMAL_LEARNER_H

#include <linux/types.h>
#include <linux/uidgid.h>

/* Ring buffer dimensions */
#define APEX_LEARNER_DAYS		7
#define APEX_LEARNER_HOURS		24
#define APEX_LEARNER_SAMPLES_PER_HOUR	12  /* every 5 minutes */
#define APEX_LEARNER_TOTAL_SLOTS	(APEX_LEARNER_DAYS * APEX_LEARNER_HOURS * APEX_LEARNER_SAMPLES_PER_HOUR)
#define APEX_LEARNER_HOURS_TOTAL	(APEX_LEARNER_DAYS * APEX_LEARNER_HOURS)

/* Trip point adjustment range */
#define APEX_LEARNER_ADJUST_MAX		2   /* ±2°C */
#define APEX_LEARNER_PERCENTILE		90  /* 90th percentile */

/* Default trip points (baseline) */
#define APEX_LEARNER_BASE_WARN		45
#define APEX_LEARNER_BASE_THROTTLE	55
#define APEX_LEARNER_BASE_CRITICAL	65

/* Persistence */
#define APEX_LEARNER_PERSIST_PATH	"/persist/apex/thermal_profile.bin"
#define APEX_LEARNER_PERSIST_MAGIC	0x41504C52  /* "APLR" */
#define APEX_LEARNER_PERSIST_VERSION	1

/* Compile-time safety: ensure the stack buffer in compute() stays bounded */
#define APEX_LEARNER_MAX_SORT_BUF	256

/* A single thermal sample */
struct apex_thermal_sample {
	int temp;		/* CPU temp in °C */
	int big_freq;		/* Big cluster freq in kHz (0 if unknown) */
	int little_freq;	/* Little cluster freq in kHz (0 if unknown) */
	uid_t fg_uid;		/* Foreground UID (0 = home/launcher) */
};

/* Per-hour-of-day statistics (computed from 7 days of data) */
struct apex_hourly_stats {
	int p50;		/* 50th percentile (median) */
	int p90;		/* 90th percentile */
	int p99;		/* 99th percentile */
	int min_temp;
	int max_temp;
	unsigned int sample_count;
};

/* Adjusted trip points (output of the learner) */
struct apex_thermal_trip_points {
	int warn_deg;
	int throttle_deg;
	int critical_deg;
	bool adjusted;		/* true after 7 days of data */
};

/* Persist file header — written before the learner struct */
struct apex_learner_persist_header {
	__u32 magic;
	__u32 version;
	__u32 struct_size;
	__u32 reserved;
};

/* Learner state — embedded in apex_state */
struct apex_learner {
	/* Ring buffer: 7×24×12 entries, circular */
	struct apex_thermal_sample samples[APEX_LEARNER_TOTAL_SLOTS];
	unsigned int write_idx;		/* next write position (0..2015) */

	/* Per-hour-of-day computed stats (24 entries) */
	struct apex_hourly_stats hourly[APEX_LEARNER_HOURS];

	/* Adjusted trip points */
	struct apex_thermal_trip_points trips;

	/* Current hour-of-day tracking */
	unsigned int current_hour;	/* 0..23 */
	unsigned int samples_this_hour;	/* 0..11 */

	/* Day counter */
	unsigned int days_collected;	/* 0..7 */

	/* Persistence */
	bool loaded_from_persist;
};

/* API — called from apex.c */
void apex_learner_init(struct apex_learner *l);
void apex_learner_add_sample(struct apex_learner *l, int temp,
			     int big_freq, int little_freq, uid_t fg_uid);
void apex_learner_compute(struct apex_learner *l);
int apex_learner_save(const struct apex_learner *l);
int apex_learner_load(struct apex_learner *l);
void apex_learner_show(struct seq_file *m, const struct apex_learner *l);

#endif /* APEX_THERMAL_LEARNER_H */
