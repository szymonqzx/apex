# Changelog

All notable changes to the APEX kernel project are documented here.
Format follows [Keep a Changelog](https://keepachangelog.com/en/1.1.0/);
the project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [0.3.0-zepharo] — planned

### Added
- **`apex-baseband-guard`**: anti-hard-brick LSM blocking writes to critical
  partitions (boot, dtbo, vbmeta*, userdata, ...) from untrusted processes.
  Vendored from `vc-teahouse/Baseband-guard` @ `a54e0dc` (GPL-2.0) with a
  static 5.15-pinned Makefile; registered via `DEFINE_LSM` (own cred blob,
  no SELinux objsec patching). `CONFIG_BBG=y` and `baseband_guard` in
  `CONFIG_LSM`.

### Changed
- **`apex_charge` now actuates hardware.** The v0.2 module stored
  `charge_limit_percent`/`charge_mode`/`bypass_charging` as ints and never
  touched the charger. Rewritten: when capacity reaches the limit the module
  brakes the main charger's `CURRENT_NOW` (via `power_supply_set_property`),
  re-asserts every 15 s against the ROM's charger daemons, and applies 3%
  hysteresis. The fake `charge_mode` and `bypass_charging` knobs (no hardware
  mapping on topaz) were removed.
- **Purged redundant experimental systems**: apex-state, apex-governor,
  apex-watchdog, apex-immortal, apex-lmk, apex-memfreq, apex-cpuboost,
  apex-thermal-uclamp, apex-display, apex-blx, apex-autoload and the
  WildKernels patch archive were removed (audit: all have production-tested
  in-tree/upstream equivalents — WALT input-boost, schedutil, QTI memlat
  DCVS, QTI thermal cdevs, LMKD).
- Version bumped to `0.3.0-zepharo` (module + build + package).
- `build-kernel.sh` no longer generates the dead `patches/apex-state/
  build-info.h` (nothing included it).

### Security
- Baseband guard: `CONFIG_BBG_BLOCK_BOOT` / `CONFIG_BBG_BLOCK_RECOVERY`
  remain off by default (recovery flashing must keep working).

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

## [0.4.0-zepharo] — planned

### Added
- **Native root**: KernelSU-Next integrated (kprobes-based, no manual hook
  points). `CONFIG_KSU=y`. kprobes + ext4 deps already enabled.
- **Root hiding**: SUSFS (`simonpunk/susfs4ksu`) — path hiding, mount hiding,
  kstat spoofing, maps spoofing, try_umount, uname spoof. `CONFIG_KSU_SUSFS=y`
  + suboptions. SUSFS commands are dispatched through a new KSU-Next prctl
  syscall hook (`kernelsu/feature/susfs_glue.c`) — KSU-Next has no prctl
  channel, so the classic `prctl(0xDEADBEEF, CMD_SUSFS_*, ...)` interface was
  adapted to the Next dispatcher (`ksu_register_syscall_hook`).
- **Upstream concurrency**: base moved from the ZEPHARO tag (5.15.170) to the
  maintained `zepharo` branch (5.15.211, 9349 commits ahead): android13-5.15-lts
  + CLO kernel.lnx.5.15.r1-rel merges, BBRv3 + tcp_plb, Schedhorizon governor,
  f2fs DIO overwrite optimizations. `.apex-base` + CI updated to the branch.
- New series patch `apex-walt-scheddebug` (guards `sched_feat_names` refs
  behind CONFIG_SCHED_DEBUG — required for production SCHED_DEBUG=n).
- KSU/SUSFS integration is vendored as a new series patch (`apex-root`) so a
  clean checkout reproduces it.

### Changed
- Version bumped to `0.4.0-zepharo`.
- SUSFS 5.4 kernel patch adapted to 5.15 (do_symlinkat/do_linkat take
  `struct filename *` in 5.15 — no re-getname; 12 hunks fixed manually).
- `vm_flags_t` include fix in susfs.h (`<linux/mm_types.h>`).

### Security note
- BBG marks the `u:r:ksu:s0` domain as untrusted — root exists but cannot
  write protected partitions (boot/dtbo/vbmeta). This is the intended
  anti-brick posture with root enabled.

## [0.4.1-zepharo] — planned

### Changed (device tuning — SM6225-AD)
- **HZ 250 → 300** (Zephyr-lineage tickrate, aligned with the 120 Hz display).
- **-O3** via `CC_OPTIMIZE_FOR_PERFORMANCE_O3` (un-ARC-gated in
  `apex-base-fixes`) — the ChicKernel-proven optimization level for this SoC.
- **Schedhorizon is now the DEFAULT governor** (topaz-proven; schedutil fork
  with efficient_freq + up_delay tunables; EAS-compatible).
- **SSG (Samsung Generic) I/O scheduler** enabled and made the DEFAULT
  (ChicKernel/SSG-proven for UFS), BFQ kept available with cgroups.
- **DAMON + DAMON_RECLAIM** (proactive reclaim for 4 GB devices), F2FS
  unfair-rwsem, EROFS pcpu kthreads (hi-pri), RT softint optimization,
  RCU_FAST_NO_HZ + RCU_NOCB_CPU, GKI_HACKS_TO_FIX (hidden vendor-module
  configs), Kprofiles framework (kp_mode 0-3 sysfs).
- **apex_profiles.rc rewritten** against the shipped v0.4 kernel surface:
  schedhorizon rate limits, WALT up/downmigrate sysctls, KGSL GPU caps
  (Adreno 610, 1260 MHz stock), APEX charge limit node. Removed dead
  /proc/apex/* and /proc/apex_charge/* paths.
- check-configs gains a `tuning` feature group + validates the new
  required options.

### Notes
- Research basis: ChicKernel stable-7 defconfig (cloned directly) + zepharo
  branch unified_defconfig. Not adopted (security): KASAN, USERFAULTFD,
  KALLSYMS_ALL, PANIC_ON_OOPS, DEFAULT_GOV_PERFORMANCE, Boeffla/CASS/Polly
  (not in the zepharo branch). Nebula kernel is for veux/peux, NOT topaz.
