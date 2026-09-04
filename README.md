# APEX kernel

A hardened, modern custom kernel for the **Redmi Note 12 4G** (topaz / tapas,
Snapdragon 685 / SM6225-AD), built on the **Zepharo R9** base (Linux 5.15.170,
CAF msm-5.15). GKI-compatible: kernel Image replaces the ROM's `boot` partition
while the ROM's ramdisk, DTB, and vendor modules are untouched.

## Highlights

- **Modern toolchain**: Clang 22 + LLD, ThinLTO, DWARF5 debug info
- **Scheduler**: WALT load tracking (built-in) + EAS + UCLAMP, PREEMPT, HZ=250
- **Security hardening**: CFI, KASLR, Shadow Call Stack, SLAB freelist
  hardening, lockdown LSM, unprivileged BPF disabled, userfaultfd disabled
- **Memory**: MGLRU enabled at boot, KSM, ZRAM (ZSTD) built-in
- **Device drivers**: fingerprint (FPC/Goodix), charger ICs (BQ2589X, SC8551,
  SM5602, LN8000), MI thermal, ANT check, battery authentication — ported from
  the topaz legacy tree
- **APEX control plane**: `/sys/class/apex/` sysfs class + charge limiting
  module that actually stops charging at a user-set % (brakes the charger's
  `CURRENT_NOW` via the power_supply framework, re-asserted periodically)
- **Baseband guard**: LSM blocking writes to critical partitions
  (boot/vbmeta/dtbo/...) from untrusted processes — anti-hard-brick protection
  (vendored from `vc-teahouse/Baseband-guard`)
- **Zero-warning build**: all Clang 22 diagnostics resolved; APEX code is
  checkpatch-clean

## Repository layout

```
defconfig/
  apex_defconfig        # Single source of truth (tracked in git)
patches/apex-new/       # Patch series applied to the kernel tree
  series                # Ordered list of patches
  <name>/apply.sh       # Idempotent per-patch installer
anykernel3/             # AnyKernel3 flashable packaging
tools/                  # Build / verify / package / release tooling
tests/cert/             # Certification test suite (pytest)
rom-overlays/           # init scripts, profiles, thermald, SELinux, PIF
apps/                   # Android control app (Jetpack Compose)
chroot/                 # Bridge daemon + chroot wrappers
docs/                   # Architecture and design docs
releases/               # Release artifacts (zip + checksum + manifest)
```

> `kernel/` is not in git — it is the Zepharo R9 base tree, extracted
> separately. `tools/build-kernel.sh` applies the patch series and syncs the
> tracked defconfig into it, so a clean checkout reproduces the build.

## Building

Requirements: clang 22+, LLVM binutils, `aarch64-linux-gnu-gcc`, `zip`,
`bc`, `bison`, `flex`, `libssl-dev`, `libelf-dev`, python3 + pytest.

```bash
# 1. Extract the Zepharo R9 kernel source to kernel/
#    (topnotchfreaks/kernel_msm-5.15, tag ZEPHARO)

# 2. Apply the patch series (idempotent)
./tools/apply-patches.sh

# 3. Build (incremental by default; --clean for a full rebuild)
./tools/build-kernel.sh

# 4. Verify the build output
./tools/verify.sh --strict

# 5. Package a flashable zip
./tools/package-anykernel3.sh
```

## Installing

Flash the AnyKernel3 zip in recovery (TWRP/OrangeFox) on top of a
GKI-compatible ROM (LineageOS / AOSP 13–16). No data wipe.

```bash
adb push releases/apex-kernel-<ver>-anykernel3.zip /sdcard/
# reboot to recovery, flash
```

The kernel Image replaces the `boot` partition. Kernel modules are installed
to `/vendor/lib/modules/` with depmod metadata, and
`apex-load-modules.sh` (installed to `/vendor/bin/`) loads critical modules
in the correct order at boot.

## APEX control plane

After boot, the kernel exposes:

- `/sys/class/apex/version` — kernel version
- `/sys/class/apex/base` — base tree
- `/sys/class/apex/enabled_features` — feature list
- `/sys/class/apex/charge/charge_limit_percent` — charge limit (80–100, 0=off)
- `/sys/class/apex/charge/status` — JSON battery telemetry + limit state

```bash
# Stop charging at 85% (re-asserted every 15s against the ROM's daemons)
echo 85 > /sys/class/apex/charge/charge_limit_percent
# Disable the limit
echo 0 > /sys/class/apex/charge/charge_limit_percent
```

## Profile switching

Battery / balanced / performance profiles are runtime-only: set
`apex.profile=battery|balanced|performance` and
`rom-overlays/init.d/apex_profiles.rc` applies the matching sysfs tunables
(governor ramp, WALT migration thresholds, GPU clocks, thermal trips, charge
limits).

## Configuration

`defconfig/apex_defconfig` is the single source of truth — no fragment
merging. Validate it with:

```bash
python3 tools/check-configs.py
```

## Testing

```bash
# Certification suite (91 tests: build, rollback, charge invariants, config)
python3 -m pytest tests/cert/ -v
```

## Releasing

```bash
./tools/release.sh 0.2.1 --build
```

Runs config checks + certification tests + build + verify + package, then
creates the git tag `v0.2.1-zepharo`, checksums, and a release manifest in
`releases/`.

## License

GPL-2.0 (see [LICENSE](LICENSE)). The kernel base is Zepharo R9
(topnotchfreaks/kernel_msm-5.15); device-specific drivers are ported from the
Xiaomi topaz legacy tree.
