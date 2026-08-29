# APEX kernel — Redmi Note 12 4G (topaz)

A custom kernel for the Redmi Note 12 4G (Snapdragon 685 / SM6225-AD)
based on the ChicKernel 5.15.189 tree with KernelSU-Next and SuSFS.

## What's in the box

### Kernel patches (patches/)

- **apex-governor** — Per-cluster CPU governor with non-linear power curve,
  iowait boost, hysteresis, fast_switch (EPSS), per-cluster auto-tuning,
  gaming mode, and screen-off ceiling
- **apex-state** — In-kernel control plane: 5-input decision table,
  thermal monitoring, GPU devfreq, GPU min clock floor (gaming),
  CPU cluster isolation (gaming), health tick, incident ring, RTC wakealarm
- **apex-charge** — Advanced charging & battery manager for PM7250B SMB5.
  5000mAh BN5M battery, 33W HVDCP3 fast charge. Sysfs-controlled charge
  limiting (80-100%), 4 charging profiles (fast/balanced/eco/overnight),
  thermal mitigation (10-step ICC), bypass charging via SMB1355 parallel,
  input suspension, SoH estimation, cycle count, quick charge type detection.
  Integrated with apex.c health tick for automatic JEITA-aware thermal
  mitigation. SELinux policy (apex_charge.te) allows init/system_app/shell
  to access /proc/apex_charge/*. Corrected batterydata DTSI (5000mAh) replaces
  the QRD 3600mAh profile. Coexists with hvdcp_opti daemon (different layers).
- **apex-watchdog** — Self-healing watchdog: 5-min subsystem checks,
  3-strike panic, CPU/GPU/thermal/ZRAM/battery monitoring
- **apex-immortal** — OOM-immortal whitelist for critical tasks
  (desk clock, alarm, bridge daemon)
- **apex-autoload** — USB VID:PID autoloader for pentest drivers
- **apex-display** — KCAL display color calibration (RGB gain via sysfs)
- **apex-lmk** — Simple LMK: adj-bucketed, size-sorted memory pressure
  killer with dedicated reaper thread and RT priority (adapted from
  Sultan Alsawaf's Simple LMK architecture)
- **apex-memfreq** — Memory bandwidth DEVFREQ driver: scales LPDDR4X
  bandwidth based on CPU utilization (real SM6225 interconnect IDs
  from device tree: MASTER_AMPSS_M0 → SLAVE_EBI_CH0)
- **apex-cpuboost** — Input-driven CPU frequency booster: hooks into
  touch events to boost policy min frequency for immediate responsiveness
  (inspired by Qualcomm cpu-boost driver)
- **apex-thermal-uclamp** — Thermal cooling device using Energy Model:
  smooth frequency capping via uclamp instead of sudden throttling
  (inspired by Google cdev_uclamp from Pixel kernel)
- **apex-blx** — Backlight dimmer: caps max brightness on battery for
  AMOLED power savings, auto-removes cap when charging
- **device-backports** — SM5602 fuel gauge, DWC3 USB, mi_thermald,
  USB tether panic, kmsg spam suppression

### Defconfig fragments (defconfig/)

- scheduler.config — PREEMPT, HZ=250, WALT, CASS, EAS, PSI, CPU idle stack,
  power-efficient workqueues, forced lazy RCU
- governor.config — apex governor, schedutil fallback, EPSS
- hardening.config — STRICT_DEVMEM, CFI, KASLR, no USERFAULTFD
- performance.config — interconnect, DCVS, BFQ, TCP BBR+Westwood, FQ scheduler
- zram.config — ZSTD + writeback, KSM, transparent huge pages, MGLRU
- root.config — KernelSU-Next + SuSFS
- pentest.config — NetHunter drivers as modules, WireGuard VPN
- toolchain.config — Clang 22 + LLD + ThinLTO
- filesystems.config — exFAT, NTFS3 (USB OTG storage support)
- display.config — KCAL display color calibration
- version.config — Localversion

### Build tools (tools/)

- build-kernel.sh — Apply patches, merge fragments, build
- check-configs.py — Verify config consistency
- verify.sh — Verify build output (20+ checks)
- package-anykernel3.sh — Create flashable zip
- autofdo-build.sh — AutoFDO profile-guided build pipeline
- investigate-sm6225-repos.sh — Diff xiaomi-6225-AD repos for backports
- irq-balance-check.sh — Review IRQ distribution on-device
- zram-benchmark.sh — A/B benchmark zRAM compression algorithms

### Userspace (chroot/ + apps/)

- apex-bridge — Daemon bridging Android framework to /proc/apex/*
- apex-term — Chroot entry wrapper
- apex-control — Jetpack Compose control app (gaming toggle, status,
  governor, watchdog, health, sensors, BT, thermal profile, stats,
  KCAL RGB calibration, incident log viewer, auto-refresh)

### ROM overlays (rom-overlays/)

- apex_power.rc — init.d script for screen/gaming/charging state, LMK tuning,
  ZRAM configuration, GPU governor switching, CPU boost configuration
- apex_profiles.rc — Three-switchable-profile system (Battery/Balanced/Performance)
  with per-profile schedutil ramp asymmetry, WALT upmigrate thresholds, GPU clock
  caps, charge limits (80/90/100%), and charging thermal throttle
- thermald.conf — Thermal trip points (45/55/65°C, replaces mi_thermald)
- SELinux policy for chroot domain (apex_chown.te)
- build.prop overlays for PIF (Xiaomi stock fingerprint for Play Integrity)
- hidden_packages.list — HMA-OSS blacklist for Magisk/APatch/LSPosed residue

### Dirty ROM modification (tools/apex-dirty-modify.sh)

On-device script that applies all ROM overlays to a running LineageOS 23.2
install without formatting. Idempotent, backs up originals, writes install
manifest. Can be pushed via adb and run as root, or applied automatically
during AnyKernel3 flash.

## Quick start

```bash
# 1. Check configs
python3 tools/check-configs.py

# 2. Build (supports --profile battery|balanced|performance)
./tools/build-kernel.sh chickernel_defconfig ksun --profile balanced

# 2b. Optional: Neutron Clang toolchain
NEUTRON_CLANG=/path/to/neutron/clang ./tools/build-kernel.sh chickernel_defconfig ksun

# 3. Verify
./tools/verify.sh

# 4. Package (includes all ROM overlays + dirty-modify + wakelock audit)
APEX_PROFILE=balanced ./tools/package-anykernel3.sh

# 5. Flash (kernel + overlays in one zip)
adb push apex-kernel-1.2.0-balanced-anykernel3.zip /sdcard/
# Reboot to recovery, flash the zip — no data wipe

# 5b. Or dirty-apply overlays only (no kernel reflash):
adb push tools/apex-dirty-modify.sh /data/local/tmp/
adb shell su -c "sh /data/local/tmp/apex-dirty-modify.sh"

# 6. Audit wakelocks (standby drain diagnosis):
adb push tools/apex-wakelock-audit.sh /data/local/tmp/
adb shell su -c "sh /data/local/tmp/apex-wakelock-audit.sh"
```

## Architecture

```
SM6225-AD (Snapdragon 685)
├── 4x Cortex-A73 @ 2.8 GHz (big cluster, EPSS DVFS)
├── 4x Cortex-A53 @ 1.9 GHz (little cluster, EPSS DVFS)
├── Adreno 610 @ 1260 MHz (KGSL, devfreq)
├── LPDDR4X @ 2133 MHz
├── UFS 2.2
└── 5000 mAh battery (SM5602 fuel gauge)

Kernel: Linux 5.15.189 (CAF bengal-5.15)
Scheduler: CASS + WALT + schedutil fallback
Governor: apex (non-linear power curve, iowait boost, hysteresis)
Root: KernelSU-Next + SuSFS
```
