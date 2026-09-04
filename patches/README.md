# APEX Kernel Patches

The patch series in `apex-new/` is applied to the **Zepharo R9** base tree
(Linux 5.15.170, `topnotchfreaks/kernel_msm-5.15` tag `ZEPHARO`) before
building. The series is ordered by `apex-new/series` and applied by
`tools/apply-patches.sh` (idempotent).

## Current series (v0.3)

| Patch | Purpose |
| :--- | :--- |
| `apex-sysfs` | APEX sysfs control plane — `/sys/class/apex/` class with version/base/features nodes |
| `apex-charge` | APEX charge limiting — stops charging at a user-set % by braking the main charger's charge current (`CURRENT_NOW`) through the power_supply framework, re-asserted periodically, with 3% hysteresis |
| `apex-baseband-guard` | Anti-hard-brick partition protection (LSM). Vendored from `vc-teahouse/Baseband-guard` @ `a54e0dc` (GPL-2.0) with a 5.15-pinned Makefile; registered via `DEFINE_LSM` (own cred blob, no SELinux patching) |
| `apex-device-backports` | Topaz device drivers ported from the legacy tree: fingerprint (FPC1020, Goodix FOD), NOPMI charger (BQ2589X, SC8551, SM5602, LN8000), battery authentication (DS28E16, onewire GPIO), ANT check, MI thermal interface |

Each patch is a directory with an idempotent `apply.sh <kernel-dir>` and its
sources under `src/` (or `legacy/` for backported drivers — vendored in-tree,
no external tree required).

## Design principle

The APEX patch set is deliberately small and surgical. Features that have a
production-tested equivalent in the base tree or in other topaz custom
kernels are **not** reimplemented here:

- CPU governor → `schedutil` (EAS governor, consumes WALT) with runtime
  tuning via `rom-overlays/init.d/apex_profiles.rc`
- CPU input boost → WALT `input-boost` (already in-tree)
- Memory bandwidth scaling → Qualcomm `memlat` DCVS (already in-tree)
- Thermal mitigation → QTI thermal cdevs (`lmh`, `cpu_voltage_cooling`,
  `bcl`) + `mi_thermald` userspace
- OOM / process protection → Android LMKD adj ranges
- Watchdog / health → kernel watchdog + `healthd`/LMKD

## Adding a patch

1. Create `apex-new/<name>/apply.sh` (idempotent) + sources under
   `apex-new/<name>/src/`.
2. Append a one-line description to `apex-new/series`.
3. C files must pass `scripts/checkpatch.pl --no-tree -f` clean and carry an
   SPDX-License-Identifier (`GPL-2.0`).
4. Vendored third-party code must preserve its license file and record the
   upstream source + commit in the patch README.

## Source references

- Base tree: `topnotchfreaks/kernel_msm-5.15` tag `ZEPHARO` (Linux 5.15.170)
- Baseband guard: `vc-teahouse/Baseband-guard` @ `a54e0dc` (GPL-2.0)
- Backported drivers: Xiaomi topaz legacy kernel tree (kernel-5.15.189-legacy)

## Removed / not applied

The experimental systems from the original plan (apex-state, apex-governor,
apex-watchdog, apex-immortal, apex-lmk, apex-memfreq, apex-cpuboost,
apex-thermal-uclamp, apex-display, apex-blx, apex-autoload) were audited
against production-tested in-tree/upstream equivalents and **removed in
v0.3**. They are not part of the build; see
`docs/README.md` and the git history for the audit rationale.
