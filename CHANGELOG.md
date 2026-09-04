# Changelog

All notable changes to the APEX kernel project are documented here.
Format follows [Keep a Changelog](https://keepachangelog.com/en/1.1.0/);
the project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

### Added
- Tracked `apex_defconfig` at repo level (`defconfig/apex_defconfig`) — the
  single source of truth, synced into the kernel tree by the build script.
  A clean checkout is now fully reproducible.
- `LICENSE` (GPL-2.0), `CONTRIBUTING.md`, `CHANGELOG.md`.
- Vendored device-backport sources in-tree: `patches/apex-new/
  apex-device-backports/legacy/` (51 files) replaces the broken absolute
  symlink to a gitignored local tree — patches now apply from a clean clone.

### Changed
- Removed all stale defconfig fragments and dead compile-time profile
  overlays (`profile-*.config` set non-existent `CONFIG_APEX_PROFILE_*`
  symbols). Profile switching is runtime-only via
  `rom-overlays/init.d/apex_profiles.rc`; `build-kernel.sh --profile`
  removed.
- `tools/verify.sh` rewritten for the v0.2 stack: no KernelSU/SuSFS checks,
  correct Image/module strings detection (fixed `grep -q` SIGPIPE bug under
  `set -o pipefail`), repo-integrity and packaging checks. 26 checks, PASS.
- `tools/check-configs.py` rewritten for the single-defconfig layout
  (dependencies, conflicts, required =y/=n, feature summary).
- `tools/release.sh` now runs pre-release checks (config, cert tests, syntax),
  verifies the build, creates the git tag `v<ver>-zepharo`, and writes the
  manifest with the tracked defconfig reference.
- `README.md`, `patches/README.md`, `tools/README.md`, `docs/README.md`
  rewritten to describe the actual v0.2 state; stale plan docs marked
  historical.
- CI: added code-quality job (checkpatch + shellcheck + patch series) and a
  full kernel-build job (dispatch/tag triggered) with verify + packaging;
  config-validation now targets `defconfig/apex_defconfig`.
- Release artifacts moved to `releases/`; `.gitignore` covers logs, python
  caches, and pending diff files.

## [0.2.0-zepharo] — 2026-09-04

### Added
- Single hand-crafted `apex_defconfig` replacing the fragment merge system.
- Proper module loading: `apex-load-modules.sh` with ordered loading of
  critical modules + on-device `depmod` in AnyKernel3.
- Clean patch system: `patches/apex-new/series` + `tools/apply-patches.sh`.
- CI: defconfig validation, patch-series verification.

### Changed
- Scheduler: WALT built-in (was module), `SCHED_DEBUG`/`SCHEDSTATS` disabled
  for production, `SCHED_CONSERVATIVE_BOOST_LPM_BIAS` enabled.
- CPUFreq: QCOM HW driver built-in (required by WALT), removed unused
  governors (userspace, conservative).
- I/O: removed Kyber scheduler; kept BFQ + MQ_DEADLINE.
- Memory: MGLRU enabled at boot, KSM enabled, ZRAM/ZSMALLOC built-in.
- Power: QCOM LPM idle governor built-in.
- Thermal: statistics/emulation disabled for production; removed HISI
  thermal driver.
- Build warnings reduced from 500 to 32 via Clang 22
  `-Wdefault-const-init-var-unsafe` suppression (false positive on
  `time_after()`).
- All APEX code is now checkpatch-clean.
- Disabled `DEBUG_INFO_BTF` (incompatible with ThinLTO on pahole 1.31).

### Fixed
- WALT build failure when built-in: `qcom_cpufreq_get_cpu_cycle_counter`
  symbol resolution (QCOM cpufreq must be built-in too).
- WALT build failure with `SCHED_DEBUG=n`: guarded `sched_feat_names`
  reference with `#ifdef CONFIG_SCHED_DEBUG`.
- BTF/ThinLTO link failure producing corrupt 18-byte `.btf.vmlinux.bin.o`.

### Build metrics
| Metric | 0.1.0 | 0.2.0 |
|--------|-------|-------|
| Image size | 38 MB | 35 MB |
| Modules | 244 | 236 |
| Build warnings | 500 | 32 |
| Checkpatch errors | 3 | 0 |
| Certification tests | 91 pass / 2 skip | 91 pass / 2 skip |
| Flashable zip | 74 MB | 69 MB |

## [0.1.0-zepharo] — 2026-08-29

### Added
- Initial Zepharo R9 (5.15.170) rebase for topaz/tapas.
- ThinLTO, BBR TCP, ZSTD ZRAM, SELinux enforcing.
- APEX sysfs control plane (`/sys/class/apex/`).
- APEX charge control module.
- Topaz device driver backports (fingerprint, charger ICs, MI thermal,
  ANT check, battery auth).
- Pentest surface hardening (CFI, BPF restrictions, lockdown LSM,
  SLAB hardening).
- Certification test suite (91 tests).
- CI + release pipeline.

[0.2.0-zepharo]: https://github.com/szymonqzx/apex-kernel/releases/tag/v0.2.0-zepharo
[0.1.0-zepharo]: https://github.com/szymonqzx/apex-kernel/releases/tag/v0.1.0-zepharo
