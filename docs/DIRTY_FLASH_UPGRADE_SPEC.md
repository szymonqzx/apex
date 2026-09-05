# APEX ROM — Dirty-Flash Upgrade Specification (S9)

## Overview

The APEX ROM is designed for dirty-flash upgrades: the user flashes a new ROM
zip over the existing installation without wiping data. This preserves all user
data, app data, and settings across updates.

## Current State

- User runs: `23.2-20260328-UNOFFICIAL-tapas` (LineageOS 23.2 / Android 16 QPR2)
- Device: Redmi Note 12 4G (topaz/tapas, SM6225-AD, 8GB RAM, 128GB UFS 2.2)
- APEX ROM dirty-flashes over this base — data is preserved.

## Upgrade Paths

### Path 1: Virtual A/B OTA (primary)

1. `update_engine` writes new system/vendor/product images to the inactive slot
2. `apex_ab_verify.sh` runs post-install verification:
   - Kernel Image header is valid
   - SELinux policy compiles and loads
   - `apex.agent` service starts in system_server
   - `apexagentd` daemon starts and connects
3. Slot is marked active only if verification passes
4. Reboot into new slot
5. On boot: health check (boot_completed + system_server alive)
6. If boot fails 3 consecutive times: auto-rollback to previous slot
7. If boot succeeds: commit snapshot (cancel-rollback)

**Brick-safety**: A/B auto-rollback means a failed update cannot brick the device.
The previous slot is always available.

### Path 2: Recovery OTA zip (emergency fallback)

1. `apex_ota_fallback.sh` generates a LineageOS-compatible OTA zip
2. User flashes the zip via TWRP/LineageOS recovery
3. Recovery flashes: boot, system, vendor, product partitions
4. Data partition is NOT touched — data preserved
5. Reboot into updated system

**Brick-safety**: Recovery is always available as a fallback. The OTA zip only
touches boot/system/vendor/product — never bootloader/aboot/partition tables.

### Path 3: Dirty-flash new ROM zip (manual)

1. User downloads the new APEX ROM zip
2. Boots into recovery (TWRP or LineageOS recovery)
3. Flashes the ROM zip over the current installation
4. Optionally flashes the APEX kernel zip (if kernel was updated)
5. Reboots

**Data preservation**: The ROM zip does NOT include a wipe directive. User data,
app data, and internal storage are all preserved.

## What Gets Updated

| Partition | Updated by A/B OTA | Updated by Recovery OTA | Bootloader? |
|-----------|--------------------|-------------------------|-------------|
| boot      | Yes (new slot)     | Yes                     | No          |
| system    | Yes (snapshot)     | Yes                     | No          |
| vendor    | Yes (snapshot)     | Yes                     | No          |
| product   | Yes (snapshot)     | Yes                     | No          |
| userdata  | **No**             | **No**                  | No          |
| modem     | **No**             | **No**                  | No          |
| bootloader| **No**             | **No**                  | **Never**   |
| aboot     | **No**             | **No**                  | **Never**   |
| tz/hyp/sbl| **No**             | **No**                  | **Never**   |

## Verification After Upgrade

After any upgrade path, the following checks run automatically:

1. **Kernel detection**: `apex_kernel_detect.sh` verifies APEX kernel is running
2. **SELinux**: Policy loads in enforcing mode (no permissive domains)
3. **Agent service**: `apex.agent` binder service is registered
4. **Agent daemon**: `apexagentd` starts and connects to system_server
5. **Brick-safety**: `verify-brick-safety.sh` runs from the new system

If any check fails, the system logs a warning but does NOT refuse to boot.
The ROM always boots — it only warns about missing features.

## Rollback

### A/B auto-rollback
- Triggered by 3 consecutive boot failures on the new slot
- Bootloader falls back to the previous active slot
- No user intervention required

### Manual rollback
- `bootctl set-active-slot _a` (or _b) from recovery or adb shell
- Reboot into the previous slot

### Recovery rollback
- Flash the previous ROM zip via recovery
- Data is preserved

## Compatibility

- APEX ROM is compatible with LineageOS 23.2 dirty-flash
- Upgrades from LineageOS 23.2 to APEX ROM: flash ROM zip + APEX kernel zip
- Upgrades between APEX ROM versions: A/B OTA or recovery zip
- Downgrades: not supported via A/B (use recovery flash with data wipe)
