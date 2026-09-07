# 18 — Migration

## Overview

The migration script (`migration/apex-migrate.sh`) handles the transition from a Magisk-based setup to KernelSU-Next. It uninstalls Magisk/APatch/LSPosed apps, removes their residual files, and prepares the system for the APEX ROM's KSU module. The script is designed to be safe — it only removes root management artifacts, never touches user data or system partitions.

## Script (apex-migrate.sh)

### Prerequisites
- Root access (current root method: Magisk or APatch)
- APEX kernel already flashed (AnyKernel3)
- KSU-Next manager installed
- Script run as root

### Steps

#### Step 1: Uninstall Root Management Apps
```bash
pm uninstall --user 0 com.topjohnwu.magisk
pm uninstall --user 0 me.bmax.apatch
pm uninstall --user 0 org.lsposed.manager
pm uninstall --user 0 com.solohsu.android.edxp.manager
```

These are uninstalled for user 0 only (not system-wide). If installed as system apps, they're added to `hidden_packages.list` instead.

#### Step 2: Remove Magisk Residual Files
```bash
rm -rf /data/adb/magisk
rm -rf /data/adb/modules  # Magisk modules (KSU uses different path)
rm -f /sbin/su
rm -f /sbin/magisk
rm -f /data/adb/magisk.db
```

Only `/data/adb/magisk*` paths are removed. KSU's `/data/adb/ksu/` is preserved.

#### Step 3: Remove LSPosed Residual Files
```bash
rm -rf /data/adb/lspd
rm -rf /data/adb/modules/zygisk_lsposed
```

#### Step 4: Clean Properties
```bash
# Remove Magisk-set properties that leak root
setprop ro.boot.magisk 2>/dev/null || true
setprop init.svc.magisk 2>/dev/null || true
setprop init.svc.magisk_pfs 2>/dev/null || true
```

#### Step 5: Verify KSU-Next is Active
```bash
if [ ! -f /data/adb/ksu/.installed ]; then
    echo "ERROR: KernelSU-Next not detected"
    echo "Flash APEX kernel first, then install KSU-Next manager"
    exit 1
fi
```

#### Step 6: Create APEX Data Directories
```bash
mkdir -p /data/adb/apex/backup
mkdir -p /data/adb/apex/logs
mkdir -p /data/adb/apex/modules
```

#### Step 7: Report
```
Migration complete.
- Magisk apps: uninstalled
- Magisk files: removed
- LSPosed files: removed
- KSU-Next: verified active
- APEX data dirs: created

Next steps:
1. Install APEX KSU module (apex-rom-ksu-module-v1.0.0.zip)
2. Reboot
3. Open Apex Control to configure hiding stack
4. Install keybox via Yurikey
```

## Safety Guarantees

- **No partition writes**: only touches `/data/adb/` and `/sbin/`
- **No data wipe**: user data, apps, settings all preserved
- **No system modification**: doesn't touch `/system/`, `/vendor/`, `/product/`
- **Reversible**: if migration fails, Magisk can be reinstalled
- **Idempotent**: running twice doesn't cause issues (rm -rf on non-existent dirs is safe)

## What the Migration Does NOT Do

- Does not install KSU-Next (user must flash kernel + install manager first)
- Does not install the APEX KSU module (user must flash it after migration)
- Does not install the hiding stack modules (done by `apex_modules.rc` on first boot)
- Does not install the keybox (user must use Yurikey separately)
- Does not remove user-installed apps (only root management apps)

## README (migration/README.md)

The migration README documents:
- Prerequisites
- Step-by-step migration guide
- Troubleshooting (what to do if KSU-Next isn't detected)
- Rollback instructions (how to go back to Magisk)
- FAQ (common questions about the migration)
