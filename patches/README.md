# APEX Kernel Patches

The patch series in `apex-new/` is applied to the **Zepharo R9** base tree
(Linux 5.15.170, `topnotchfreaks/kernel_msm-5.15` tag `ZEPHARO`) before
building. The series is ordered by `apex-new/series` and applied by
`tools/apply-patches.sh` (idempotent).

## Current series (v0.2)

| Patch | Purpose |
| :--- | :--- |
| `apex-sysfs` | APEX sysfs control plane — `/sys/class/apex/` class with version/base/features nodes |
| `apex-charge` | APEX charge control module — charge limit, mode, bypass, JSON battery telemetry |
| `apex-device-backports` | Topaz device drivers ported from the legacy tree: fingerprint (FPC1020, Goodix FOD), NOPMI charger (BQ2589X, SC8551, SM5602, LN8000), battery authentication (DS28E16, onewire GPIO), ANT check, MI thermal interface |

Each patch is a directory with an idempotent `apply.sh <kernel-dir>` and its
sources under `src/` (or `legacy/` for backported drivers — vendored in-tree,
no external tree required).

## Adding a patch

1. Create `apex-new/<name>/apply.sh` (idempotent) + sources under
   `apex-new/<name>/src/`.
2. Append a one-line description to `apex-new/series`.
3. C files must pass `scripts/checkpatch.pl --no-tree -f` clean and carry an
   SPDX-License-Identifier (`GPL-2.0`).

## Source references

- Base tree: `topnotchfreaks/kernel_msm-5.15` tag `ZEPHARO` (Linux 5.15.170)
- Backported drivers: Xiaomi topaz legacy kernel tree (kernel-5.15.189-legacy)

## Removed / not applied

The earlier `quarantine/` directory holds experimental patches from the
original plan (apex-governor, apex-state, apex-watchdog, apex-immortal,
apex-lmk, apex-display, etc.) that were **not** included in v0.2. They are
archived for reference only and are not part of the build.
