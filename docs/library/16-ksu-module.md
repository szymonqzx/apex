# 16 — KSU Module

## Overview

The APEX ROM is delivered as a KernelSU-Next module. The module overlays files onto `/system` without modifying the system partition. This means the entire ROM can be installed, updated, and removed by managing a single KSU module — no system partition writes, no data wipe.

## Module Structure

```
ksu-module/
├── module.prop                    # Module metadata
├── post-fs-data.sh                # Early boot script
├── service.sh                     # Post-boot script
├── uninstall.sh                   # Cleanup script
├── sepolicy.rule                  # SELinux policy rules
└── system/                        # Overlay files (mounted over /system)
    ├── build.prop.append
    ├── vendor.build.prop.append
    ├── etc/
    │   ├── init/                  # 17 init RC files
    │   └── thermald.conf
    ├── hidden_packages.list
    ├── bin/                       # 8 shell scripts
    ├── app/                       # Regular apps (NFCForge, PTK TUI)
    └── priv-app/                  # Privileged apps (ApexControl, SystemServices)
```

## module.prop

```properties
id=apex_rom
name=APEX ROM Agent Spine
version=v1.0.0
versionCode=1
author=takon
description=APEX ROM system overlays: agent, WM, desktop, Lindroid, hiding stack, pentest tools
```

## Boot Flow

### Phase 1: post-fs-data.sh (early boot, before Zygote)

Runs after `/data` is mounted but before the framework starts.

1. **Kernel detection**: checks `/proc/version` for APEX kernel string
   - Sets `ro.apex.kernel_detected=1` or `0`
   - If not APEX kernel: sets warning property (never blocks boot)
2. **APEX data directory**: creates `/data/adb/apex/` with subdirectories:
   - `/data/adb/apex/backup/` — boot image backups
   - `/data/adb/apex/logs/` — runtime logs
   - `/data/adb/apex/modules/` — module storage
3. **Socket permissions**: creates `/dev/socket/` entries with correct permissions for:
   - `apex-agent` (0600, root:root)
   - `apex-bridge` (0600, root:root)
   - `apex_remote_proxy` (0660, system:system)

### Phase 2: service.sh (post-boot, after sys.boot_completed=1)

Runs after the Android framework has fully booted.

1. **Build.prop overlays**: appends `build.prop.append` to `/system/build.prop`
   - Idempotent: checks if already applied before appending
   - Uses a sentinel string to detect prior application
2. **Vendor build.prop overlays**: appends `vendor.build.prop.append` to `/vendor/build.prop`
   - Same idempotent approach
3. **Hidden packages**: copies `hidden_packages.list` to HMA-OSS config location
4. **Health monitor**: starts `apex_agent_healthcheck.sh` in background
   - Monitors apexagentd liveness
   - Circuit breaker: max 5 restarts per 10-minute window

### Phase 3: apex_modules.rc (post-boot, after KSU init)

One-time hiding stack module installer:
1. Checks sentinel file `/data/adb/apex_modules_installed`
2. If not installed, installs 4 KSU modules from `/system/apex/modules/*.zip`:
   - Zygisk-Next
   - Shamiko
   - HMA-OSS
   - TrickyStore
3. Creates sentinel file to prevent re-installation

## SELinux Policy (sepolicy.rule)

Loaded by KSU's sepolicy.rule mechanism. Enforcing mode only — no permissive domains.

### Domains
| Domain | Component | Purpose |
|--------|-----------|---------|
| `apex_agent` | apexagentd | Agent daemon — binder, socket, procfs, sysfs |
| `apex_charge_proc` | Charge sysfs | Power supply procfs files |
| `apex_chroot` | apex-bridge | Chroot bridge — binder, hardware access |

### Key Rules
```te
# Agent domain
init_daemon_domain(apex_agent)
binder_call(apex_agent, system_server)
binder_call(system_server, apex_agent)
allow apex_agent apex_charge_proc:file { read write open getattr };
allow apex_agent proc_apex:dir { search read };
allow apex_agent proc_apex:file { read open };
allow apex_agent system_lib_file:file { read open execute };

# Neverallow — brick safety
neverallow apex_agent block_device:blk_file { write append };
neverallow apex_agent self:capability { sys_admin sys_module };

# Neverallow — no network for inference daemon
neverallow apex_agent self:tcp_socket { create bind listen accept };
neverallow apex_agent self:udp_socket { create bind listen accept };
```

## uninstall.sh

Cleanup when the KSU module is removed:
1. Stops apexagentd and apex_remote_proxy
2. Stops apex-bridge
3. Cleans up socket files
4. Preserves logs at `/data/adb/apex/logs/`
5. Does NOT remove `/data/adb/apex/` (user data preserved)
6. Does NOT remove hiding stack modules (user must remove separately)

## Packaging

### tools/package-ksu-module.sh
Assembles the KSU module directory into a flashable zip:
1. Copies all files from `ksu-module/` to a temp directory
2. Ensures all shell scripts are executable (chmod +x)
3. Creates zip with proper structure
4. Output: `releases/apex-rom-ksu-module-v1.0.0.zip` (22MB)

### tools/package-flashable.sh
Combines AnyKernel3 kernel flasher + KSU module into a single recovery zip:
1. Copies AnyKernel3 template
2. Copies kernel Image from `out/arch/arm64/boot/Image`
3. Copies 239 kernel modules + depmod metadata
4. Copies `apex-load-modules.sh`
5. Copies KSU module zip into AnyKernel3
6. Output: `releases/apex-rom-flashable-v1.0.0-topaz.zip` (92MB)

## Flashing

### Recommended Order
1. Flash standalone kernel zip first: `apex-kernel-0.4.0-zepharo-anykernel3.zip`
2. Confirm boot works
3. Flash KSU module zip: `apex-rom-ksu-module-v1.0.0.zip`
4. Reboot
5. Configure hiding stack via Apex Control

### Combined Flash
The flashable zip (`apex-rom-flashable-v1.0.0-topaz.zip`) combines both in one flash. This is convenient but riskier — if the kernel doesn't boot, you can't separate kernel from module.

### Recovery
- **Soft-bootloop**: flash stock boot image or switch A/B slot
- **Module issues**: remove KSU module from recovery, reboot
- **Data preservation**: all data stays intact — no wipe needed
