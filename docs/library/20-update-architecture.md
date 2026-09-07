# 20 — Update Architecture

## Overview

APEX ROM uses a dirty-flash-only update model. There is no OTA (Over-The-Air) update system — updates are applied by flashing new kernel and KSU module zips via recovery. The ROM is designed for a single user (personal use, not distributed), so the lack of OTA is a deliberate choice, not a limitation.

## Virtual A/B Support

The Redmi Note 12 4G uses Virtual A/B updates:
- Two slots: `_a` and `_b`
- Active slot is booted; inactive slot is updated
- On update: write to inactive slot → mark bootable → reboot → switch slots
- If new slot fails to boot: `bootctl` switches back to previous slot

### APEX and Virtual A/B
APEX does not use the A/B mechanism for updates — it dirty-flashes the boot partition directly. However, the A/B mechanism provides a safety net:

1. **Before flashing APEX kernel**: the current boot image is backed up to `/data/adb/apex/backup/boot_backup_$(date).img`
2. **If APEX kernel doesn't boot**: flash stock boot image via recovery, or switch A/B slot
3. **`apex_ab_verify.sh`**: verifies current slot is marked bootable
4. **`apex_ota_fallback.sh`**: if an OTA update fails, rolls back to previous slot

## Update Scripts

### rom-overlays/update/apex_ab_verify.sh
```bash
#!/system/bin/sh
# Verify current A/B slot is bootable
slot=$(getprop ro.boot.slot_suffix)
bootctl=$(which bootctl 2>/dev/null || echo "/system/bin/bootctl")
$bootctl get-active-slot
$bootctl is-slot-bootable "$slot"
```

### rom-overlays/update/apex_ota_fallback.sh
```bash
#!/system/bin/sh
# OTA fallback — roll back to previous slot on failure
# Triggered by update_engine on failure
slot=$(getprop ro.boot.slot_suffix)
other_slot=$([ "$slot" = "_a" ] && echo "_b" || echo "_a")
bootctl mark-boot-successful  # mark current as successful
# If we got here, current slot booted successfully
```

### rom-overlays/update/apex_update_engine.rc
Init RC for the update engine:
```rc
service apex_update_engine /system/bin/update_engine
    class core
    user root
    group root
    seclabel u:r:update_engine:s0
```

## Dirty-Flash Upgrade Path

### Kernel Update
1. Download new `apex-kernel-*.zip`
2. Flash via recovery (AnyKernel3 writes to boot partition)
3. Reboot
4. `anykernel.sh` backs up current boot image before flashing

### KSU Module Update
1. Download new `apex-rom-ksu-module-*.zip`
2. Flash via KSU manager or recovery
3. Reboot
4. `post-fs-data.sh` runs with new overlay files
5. `service.sh` applies updated build.prop overlays (idempotent)

### Full ROM Update
1. Download new `apex-rom-flashable-*.zip`
2. Flash via recovery
3. Reboot
4. Both kernel and module are updated in one flash

## Dirty-Flash Upgrade Specification

The `docs/DIRTY_FLASH_UPGRADE_SPEC.md` (103 lines) documents:
- What can be dirty-flashed (kernel, KSU module, apps)
- What cannot be dirty-flashed (bootloader, modem, TZ)
- Upgrade path from stock → APEX
- Upgrade path between APEX versions
- Rollback procedures

## What is NOT Updated

- **Bootloader**: never touched by APEX
- **Modem/baseband**: never touched
- **Trust Zone (TZ)**: never touched
- **System partition**: never modified (KSU overlays instead)
- **Vendor partition**: never modified (overlays via build.prop.append)
- **User data**: never wiped

## Backup Strategy

| Data | Location | Backup |
|------|----------|--------|
| Boot image | `/dev/block/by-name/boot` | `/data/adb/apex/backup/boot_backup_*.img` |
| Keybox | `/data/adb/tricky_store/keybox.xml` | One-time off-device backup (user choice) |
| Chroot rootfs | `/data/adb/apex/arch` | Not backed up (can be re-initialized) |
| Agent memory | `/data/local/tmp/apex_memory.db` | Not backed up (regenerated) |
| Consent audit | `/data/system/apex/consent_audit.db` | Not backed up (append-only log) |

## No OTA — By Design

The user has chosen manual updates over OTA for the following reasons:
1. **Personal use**: single device, single user — no fleet management needed
2. **Control**: manual updates let the user verify each release before flashing
3. **Simplicity**: no OTA infrastructure to maintain or secure
4. **Safety**: dirty-flash is reversible; OTA can soft-brick if interrupted
5. **Size**: ROM updates are 70-92MB — too large for automatic download on mobile data
