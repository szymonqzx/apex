# APEX ROM — Update Architecture

## Overview

The APEX ROM uses a **dual update path**: Virtual A/B seamless updates (primary)
with auto-fallback, and a LineageOS OTA-style zip (emergency fallback).

## APEX Kernel Compatibility

The APEX kernel is a **clean drop-in for LineageOS 23.2** — it boots on a
stock LineageOS 23.2 installation without any ROM-side modifications. This
is a core design principle:

- **APEX kernel → clean LOS 23.2**: Works as a drop-in replacement kernel.
  The kernel is self-contained (KernelSU-Next + SuSFS + schedhorizon + charge
  threshold) and does not require any ROM-side patches to boot.
- **APEX ROM → APEX kernel**: The ROM requires the APEX kernel for full
  functionality (agent, charging, tuning, chroot). Without it, the ROM
  **warns** (boot notice, dmesg flag, Apex Control badge) but never blocks boot.
- **Test**: `rom-overlays/init.d/apex_kernel_detect.sh` detects the APEX kernel
  via `/proc/version` marker and `/proc/apex/version` sysfs node. The detection
  script is read-only and sets system properties for the UI badge.

## Virtual A/B (Primary)

### Device Support

The Redmi Note 12 4G (topaz/tapas, SM6225-AD) supports Virtual A/B updates.
Virtual A/B uses snapshot-based merging in `userdata` rather than dedicated
`system_b`/`vendor_b` partitions, saving storage.

### Slot Mechanism

- Two logical slots: `_a` (active) and `_b` (inactive)
- `bootctl` HAL manages slot flags: `active`, `boot_successful`, `retry_count`
- On update: new image written to inactive slot, slot marked `active` with
  `boot_successful=0` and `retry_count=3`

### Test-Before-Commit

1. Update writes new system image to inactive slot
2. `bootctl` marks inactive slot as active with retry_count=3
3. Device reboots into new slot
4. `apex_ab_verify.sh` runs during `on boot` phase:
   - Kernel version starts with `5.15`
   - APEX sysfs present at `/sys/class/apex/`
   - `system_server` started successfully
   - `apexagentd` registered with `servicemanager`
5. If all checks pass: `setprop persist.apex.slot_verified 1`,
   `bootctl mark-boot-successful`
6. If any check fails: `bootctl set-active-boot-slot <previous>`,
   device reboots back to known-good slot

### Auto-Rollback

- Bootloader increments `boot_attempt` counter on each boot of a non-successful slot
- After `retry_count` (3) failed attempts, bootloader auto-switches to previous slot
- This is a hardware-level guarantee — no software needed for rollback
- `apex_ab_verify.sh` provides a *software-level* early rollback (faster than
  waiting for 3 failed boots)

### Safe-Flash Rules (ABSOLUTE)

1. **NEVER** flash or write to: `bootloader`, `aboot`, `sbl`, `tz`, `hyp`,
   `modem`, `keymaster`, `cmnlib`, `devcfg`, or any partition table entry
2. **NEVER** use `dd if=` targeting boot-critical partitions
3. **NEVER** use `fastboot flash` on: `aboot`, `sbl1`, `sbl2`, `sbl3`, `tz`,
   `rpm`, `hyp`, `modem`, `bootloader`, `devinfo`, `partition`
4. Only write to: `boot`, `system`, `vendor`, `product`, `system_ext`,
   `userdata` (via OTA), `vbmeta` (with verified boot disabled flag)
5. `tools/verify-brick-safety.sh` enforces this — grep-scans the entire repo

## OTA Zip (Emergency Fallback)

### When to Use

- Virtual A/B update corrupted both slots (extremely unlikely)
- Recovery from a soft-brick where recovery still works
- Manual downgrade to a known-good version

### Format

- Standard LineageOS OTA zip format
- Contains: `system.img`, `vendor.img`, `boot.img`, `product.img`,
  `system_ext.img`, `META-INF/com/google/android/update-binary`,
  `META-INF/com/google/android/updater-script`
- Flashable via TWRP/LineageOS recovery
- `apex_ota_fallback.sh` generates this zip from a built ROM

### OTA Updater Config

```
# /system/etc/lineageos_updater.conf
server=https://updates.apex.local/api
channel=stable
device=tapas
```

## Dirty-Flash Upgrade Path

### From: 23.2-20260328-UNOFFICIAL-tapas

1. Boot into recovery (TWRP or LineageOS recovery)
2. Flash APEX ROM zip (contains system, vendor, boot, product, system_ext)
3. Flash APEX kernel AnyKernel3 zip
4. Wipe cache + dalvik-cache (NOT data)
5. Reboot

### Data Preservation

- `userdata` is NOT wiped during dirty-flash
- FBE (File-Based Encryption) keys preserved
- App data preserved
- Settings preserved
- Only system/vendor/boot partitions are updated

## Update Flow Diagram

```
┌─────────────┐     ┌──────────────┐     ┌─────────────┐
│ Build ROM    │────►│ Generate A/B │────►│ Write to    │
│ (lunch + m)  │     │ payload      │     │ inactive    │
└─────────────┘     └──────────────┘     │ slot        │
                                         └──────┬──────┘
                                                │
                                         ┌──────▼──────┐
                                         │ Reboot to   │
                                         │ new slot    │
                                         └──────┬──────┘
                                                │
                              ┌─────────────────┼─────────────────┐
                              │                 │                 │
                       ┌──────▼──────┐  ┌───────▼───────┐  ┌─────▼──────┐
                       │ apex_ab_     │  │ Boot fails    │  │ Boot loops │
                       │ verify PASS  │  │ (verify FAIL) │  │ 3x         │
                       └──────┬──────┘  └───────┬───────┘  └─────┬──────┘
                              │                 │                 │
                       ┌──────▼──────┐  ┌───────▼───────┐  ┌─────▼──────┐
                       │ mark-boot-  │  │ set-active    │  │ bootloader │
                       │ successful  │  │ previous slot │  │ auto-switch│
                       └─────────────┘  └───────────────┘  └────────────┘
```

## Emergency OTA Fallback

```
┌─────────────┐     ┌──────────────┐     ┌─────────────┐
│ Build ROM    │────►│ apex_ota_    │────►│ Transfer    │
│              │     │ fallback.sh  │     │ to device   │
└─────────────┘     └──────────────┘     └──────┬──────┘
                                               │
                                        ┌──────▼──────┐
                                        │ Recovery    │
                                        │ flash zip   │
                                        └─────────────┘
```

## Brick-Safety Verification

`tools/verify-brick-safety.sh` scans every file in the repository for:

- `dd if=` targeting: boot, aboot, sbl, tz, hyp, modem, bootloader, partition
- `fastboot flash` targeting: aboot, sbl1, sbl2, sbl3, tz, rpm, hyp, modem,
  bootloader, devinfo, partition
- Any write to `/dev/block/by-name/aboot*`, `/dev/block/by-name/sbl*`,
  `/dev/block/by-name/tz*`, `/dev/block/by-name/hyp*`,
  `/dev/block/by-name/modem*`, `/dev/block/by-name/bootloader*`

If any match is found, the script exits 1 and lists the offending files.
This is enforced in CI and as a pre-commit check.
