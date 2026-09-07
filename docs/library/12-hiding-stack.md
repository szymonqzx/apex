# 12 — Hiding Stack

## Overview

APEX ROM implements a comprehensive root-hiding stack to pass Play Integrity checks and prevent root detection by banking apps, streaming services, and security tools. The stack covers 76 detection vectors across 4 walls (tiers), using a combination of kernel-level hiding (SuSFS), Zygisk-based hiding (Shamiko), package hiding (HMA-OSS), and hardware-backed keybox injection (TrickyStore + Yurikey).

## Architecture

```
┌─────────────────────────────────────────────────────┐
│                  HIDING STACK                        │
├─────────────────────────────────────────────────────┤
│  Tier 1: Kernel-resident (SuSFS, compile-time)      │
│    ├── /proc/mounts, /proc/self/mountinfo           │
│    ├── /proc/kallsyms (root + non-root)              │
│    ├── SELinux denial log spoofing                   │
│    ├── /proc/<pid>/maps, attr/current, loginuid     │
│    ├── /proc/net/tcp(6)                              │
│    ├── /proc/version, boot_id                        │
│    ├── /dev/mem, /dev/kmem, /dev/port (STRICT_DEVMEM)│
│    ├── eBPF hook probes (kptr_restrict=2)            │
│    ├── Zygisk syscall trace                          │
│    ├── acct UID, ksucalls tracepoint                 │
│    └── system_server mem scan                        │
├─────────────────────────────────────────────────────┤
│  Tier 2: ROM-resident (build.prop / SELinux overlays)│
│    ├── ro.build.fingerprint (PIF spoof)              │
│    ├── ro.build.type=user, ro.debuggable=0           │
│    ├── ro.secure=1, ro.build.keys=release-keys       │
│    ├── ro.boot.verifiedbootstate=yellow              │
│    ├── ro.boot.veritymode=enforcing                  │
│    ├── pm list packages (HMA module)                 │
│    ├── getprop root-related (overlay + SettingsFirewall)│
│    ├── Magisk/APatch/LSPosed residue (migration)     │
│    └── Stock HALs kept (camera, sensors, BT, GPU)    │
├─────────────────────────────────────────────────────┤
│  Tier 3: Zygisk-resident (Shamiko + ReZygisk)        │
│    ├── /proc/<pid>/maps (self)                       │
│    ├── Zygisk module list                             │
│    └── Denylist enforcement                           │
├─────────────────────────────────────────────────────┤
│  Tier 4: Hardware-backed (TrickyStore + Yurikey)     │
│    ├── ro.boot.vbmeta.device_state (keybox bypass)   │
│    ├── ro.boot.flash.locked (keybox bypass)           │
│    └── Play Integrity STRONG attestation              │
└─────────────────────────────────────────────────────┘
```

## Components

### KernelSU-Next + SuSFS (kernel, compile-time)
- **Source**: `patches/apex-new/apex-root/` (81 C/H files, ~12,000 lines)
- **Kernel configs**: `CONFIG_KSU=y`, `CONFIG_KSU_SUSFS=y` + 8 sub-options
- **Hiding**: path hiding, mount hiding, kstat hiding, maps hiding, uname spoofing
- **PID hiding**: `KERNELSU_HIDE_PID` hides root process PIDs from `/proc/<pid>/attr/current` and `/proc/<pid>/loginuid`
- **Tracepoint remap**: `KERNELSU_TRACEPOINT_REMAP` remaps ksucalls tracepoint
- **AVC denial spoofing**: SuSFS spoofs SELinux denial logs to hide root-related denials

### Shamiko (Zygisk module)
- **Purpose**: Denylist-based root hiding for Zygisk-injected apps
- **Mechanism**: Hooks app_process to hide root artifacts from denylisted packages
- **Denylist**: configured from `hiding/denylist.conf` (30+ packages)
- **Runtime**: Zygisk-Next provides the Zygisk runtime

### HMA-OSS (KSU module)
- **Purpose**: Package and path hiding — hides root apps from `pm list packages`, `pm path`, `dumpsys package`
- **Mechanism**: Filters package manager queries at the framework level
- **Consumes**: `ksu-module/system/hidden_packages.list`

### TrickyStore (KSU module)
- **Purpose**: Hardware-backed KeyStore keybox injection for Play Integrity STRONG attestation
- **Mechanism**: Injects a valid keybox into the hardware-backed KeyStore
- **Keybox path**: `/data/adb/tricky_store/keybox.xml`

### Yurikey (companion app)
- **Purpose**: One-time keybox installation tool
- **Mechanism**: Guides user through keybox import, verifies keybox validity
- **One-time**: After installation, Yurikey can be uninstalled

### PIF (Play Integrity Fix)
- **Purpose**: DEVICE-level Play Integrity bypass via build.prop fingerprint spoofing
- **Mechanism**: Dirty build.prop overlay spoofs Xiaomi MIUI fingerprint
- **NOT a module**: PIF is built into the ROM overlay, not a separate KSU module

## 76-Vector Audit

The full hiding stack audit is documented in DESIGN.md §7. It covers:

### Tier 1 — Kernel-resident (25 vectors, closed by SuSFS at compile time)
| Vector | Fix |
|--------|-----|
| `/proc/mounts` | SuSFS `hide_mountpoint` |
| `/proc/self/mountinfo` | SuSFS `hide_mountinfo` |
| `/proc/kallsyms` (non-root) | SuSFS `hide_kallsyms` |
| `/proc/kallsyms` (root) | SuSFS KSU range filter |
| SELinux denial log | SuSFS `spoof_avc_denials` |
| `/proc/<pid>/maps` (sibling) | SuSFS filter |
| `/proc/<pid>/maps` (self) | SuSFS + Shamiko |
| `/proc/<pid>/attr/current` | `KERNELSU_HIDE_PID` |
| `/proc/<pid>/loginuid` | `KERNELSU_HIDE_PID` |
| `/proc/net/tcp(6)` | SuSFS filter + Pentest marker |
| `/proc/version` | SuSFS overlay |
| `/dev/mem`, `/dev/kmem`, `/dev/port` | `STRICT_DEVMEM=y` |
| eBPF hook probes | `kptr_restrict=2` + devmem strict |
| Zygisk syscall trace | SuSFS + Shamiko + ReZygisk |
| `acct` UID | `KERNELSU_HIDE_PID` |
| `ksucalls` tracepoint | `KERNELSU_TRACEPOINT_REMAP` |
| system_server mem scan | devmem + kptr (root-grant whitelist) |
| ... | (8 more vectors) |

### Tier 2 — ROM-resident (49 vectors, closed by dirty build.prop / SELinux overlays)
| Vector | Fix |
|--------|-----|
| `ro.build.fingerprint` | dirty build.prop (MIUI V816.0.7.0.UMGMIXM) |
| `ro.build.type` | `user` |
| `ro.debuggable` | `0` |
| `ro.secure` | `1` |
| `ro.build.keys` | `release-keys` |
| `ro.boot.verifiedbootstate` | `yellow` (stock) |
| `ro.boot.veritymode` | `enforcing` (stock) |
| `pm list packages` | HMA module |
| `dumpsys package` | HMA module |
| `getprop` (root-related) | build.prop overlay + SettingsFirewall |
| `Settings.Secure/Global/System` | SettingsFirewall |
| Magisk app residue | removed by migration script |
| `/sbin/su`, `/sbin/magisk` | removed by migration |
| `/data/adb/magisk` | removed by migration |
| LSPosed/zygisk module list | Shamiko + not used |
| ... | (33 more vectors) |

### Tier 3 — Zygisk-resident (2 vectors, closed by Shamiko + ReZygisk)
| Vector | Fix |
|--------|-----|
| `/proc/<pid>/maps` (self) | SuSFS + Shamiko |
| Zygisk module list | Shamiko + not used |

### Tier 4 — Hardware-backed (2 vectors, closed by TrickyStore + Yurikey)
| Vector | Fix |
|--------|-----|
| `ro.boot.vbmeta.device_state` | **WALL (bypassed by keybox)** |
| `ro.boot.flash.locked` | **WALL (bypassed by keybox)** |

## Module Count

The hiding stack uses the minimum possible modules:

| Module | Purpose | Removable? |
|--------|---------|-----------|
| Zygisk-Next | Zygisk runtime for KSU-Next | No — Shamiko depends on it |
| Shamiko | Denylist-based root hiding | No — covers /proc/self/maps |
| HMA-OSS | Package/path hiding | No — covers pm list packages |
| TrickyStore | Keybox injection | No — STRONG integrity |
| Yurikey | Keybox installer | Yes — uninstall after setup |

Total: 4 irreducible modules + 1 setup tool. SuSFS, PIF, ReZygisk, and TreatWheel are all moved to kernel/ROM level (no separate module needed).

## PIF Fingerprint

The build.prop overlay spoofs:
```
ro.build.fingerprint=xiaomi/tapas_global/tapas:13/TKQ1.221114.001/V816.0.7.0.UMGMIXM:user/release-keys
ro.build.type=user
ro.debuggable=0
ro.secure=1
ro.build.keys=release-keys
```

This matches a stock MIUI Android 13 fingerprint, sufficient for DEVICE-level Play Integrity. STRONG integrity requires the TrickyStore keybox.

## Configuration Scripts

### hiding/configure_hiding.sh
Configures the hiding stack after first boot:
1. Configures Shamiko denylist from `denylist.conf`
2. Configures HMA-OSS package hiding
3. Verifies TrickyStore keybox presence
4. Runs a basic Play Integrity check

### hiding/install_modules.sh
One-time KSU module installer:
1. Installs Zygisk-Next from `/system/apex/modules/zygisk_next.zip`
2. Installs Shamiko from `/system/apex/modules/shamiko.zip`
3. Installs HMA-OSS from `/system/apex/modules/hma_oss.zip`
4. Installs TrickyStore from `/system/apex/modules/tricky_store.zip`
5. Creates sentinel file to prevent re-installation

### hiding/denylist.conf
30+ packages in the denylist:
- Banking: Barclays, HSBC, NatWest, Lloyds, Santander, Halifax, TSB, Starling, Monzo, Revolut, PayPal
- Google: Play Services, Play Integrity, Google Services Framework
- Streaming: Netflix, Disney+, Spotify, Amazon Prime
- Security/MDM: MS Teams, Workday, BlackBox
- Root detection: Magisk, APatch, SuperSU, etc.
- APEX internal: com.apex.control, com.apex.agent

## Known Walls

| Wall | Status | Explanation |
|------|--------|-------------|
| Widevine L1 | Behind | Hardware wall — Netflix/Prime in SD only |
| Bootloader relock apps | Behind | Rare in 2026, most use STRONG integrity |
| Internal Wi-Fi injection | Behind | Hardware wall — use external USB adapters |
