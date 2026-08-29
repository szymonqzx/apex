# ROM overlays

Dirty-applied overlays for the existing LineageOS 23.2 install. All overlays
are written and ready to apply via `tools/apex-dirty-modify.sh` or the
AnyKernel3 zip's `post_install_overlays()` function.

## Files

| Path | Purpose | Status |
| :--- | :--- | :--- |
| `build.prop/system.build.prop.append` | PIF: Xiaomi stock fingerprint, release-keys, security patch | ✓ Ready |
| `build.prop/vendor.build.prop.append` | Vendor build props for PIF (fingerprint, security patch, DTB info) | ✓ Ready |
| `init.d/apex_power.rc` | Screen/gaming/charging state, LMK tuning, ZRAM, GPU governor, CPU boost | ✓ Ready |
| `thermald/thermald.conf` | 45/55/65°C trip points + adaptive learner config | ✓ Ready |
| `selinux/apex_chown.te` | Chroot raw-HW SELinux policy (Enforcing, no permissive) | ✓ Ready |
| `bin/apex-alarmkeeper.c` | Alarm-mirror source (compile for aarch64, deploy to /vendor/bin) | Source only |
| `bin/apex-bridge.c` | Bridge daemon source (compile for aarch64, deploy to /vendor/bin) | Source only |
| `hidden_packages.list` | HMA-OSS blacklist (Magisk, APatch, LSPosed, EdXposed) | ✓ Ready |

## Application

### Method A — AnyKernel3 flash (automatic)

The `package-anykernel3.sh` script copies all overlays into the zip. During
flash, `anykernel.sh`'s `post_install_overlays()` function applies them:

1. Mounts /system and /vendor rw
2. Appends build.prop overlays (idempotent — checks for APEX marker)
3. Copies apex_power.rc to /vendor/etc/init/
4. Copies thermald.conf to /system/etc/
5. Copies SELinux policy to /system/etc/selinux/
6. Copies hidden_packages.list to /data/adb/apex/
7. Installs pre-compiled binaries to /vendor/bin/ (if present)
8. Creates /data/adb/apex/ directory structure
9. Unmounts partitions

### Method B — Manual dirty-apply (no reflash)

```bash
adb push tools/apex-dirty-modify.sh /data/local/tmp/
adb shell su -c "sh /data/local/tmp/apex-dirty-modify.sh"
```

The script:
- Backs up original files to /data/adb/apex/backup-pre-apex/
- Applies all overlays (idempotent — safe to re-run)
- Disables mi_thermald if present
- Installs KSU service.d scripts for post-boot kernel tuning
- Removes Magisk/APatch manager apps (keeps data)
- Sets kernel runtime parameters (kptr_restrict, dmesg_restrict, etc.)
- Verifies all overlays with 10-point check
- Writes install manifest to /data/adb/apex/install_manifest.json

## PIF Strategy

The build.prop overlay spoofs a stock Xiaomi MIUI fingerprint
(V816.0.7.0.UMGMIXM, Android 13, TKQ1.221114.001) that Play Integrity
accepts for the topaz/tapas device model. The actual LineageOS 23.2 SDK
level (36, Android 16) is preserved — Play Integrity DEVICE tier checks
the fingerprint, not the SDK. STRONG tier is handled by TrickyStore +
Yurikey keybox (not build.prop).

## SELinux Policy

The `apex_chown.te` source must be compiled into policy. Two options:
1. Ship as a KernelSU-Next module with `sepolicy.rule` (recommended)
2. Compile on-device via `sepolicy-inject` (one-time)

The policy defines the `apex_chroot` domain for the Arch Linux ARM chroot,
with precise allow rules for Binder (system_server, HAL services) and raw
hardware nodes (ST21NFC, LIRC, USB, serial). No permissive domains.
