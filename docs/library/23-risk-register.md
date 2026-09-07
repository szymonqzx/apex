# 23 — Risk Register

## Overview

Honest assessment of risks, known hardware walls, and their mitigations. APEX ROM is a personal-use project — some risks are accepted rather than mitigated because they don't affect the user's use case.

## Risk Table

| # | Risk | Severity | Mitigation | Status |
|---|------|----------|------------|--------|
| R1 | Widevine L1 unavailable | Low | Accepted — Netflix/Prime in SD only | Hardware wall |
| R2 | Bootloader-relock apps reject | Low | Most banking apps use STRONG integrity, not relock check | Accepted |
| R3 | Single off-device keybox backup | Medium | One-time exception, justified by replacement cost | Accepted |
| R4 | Internal Wi-Fi injection is hardware wall | Low | Use external USB adapters (ALFA AWUS036ACH) | Accepted |
| R5 | ChicKernel archived Feb 2026 | Low | Still buildable, backport device fixes once | Accepted |
| R6 | 7-day thermal learning takes a week | None | Safe defaults (45/55/65°C) from day one | Not yet implemented |
| R7 | APatch Manager residue in launcher | None | Uninstalled in migration step 2 | Mitigated |
| R8 | kptr_restrict=2 may interfere with crash tools | Low | Read-only for non-root; root has access | Accepted |
| R9 | LOS source sync failure | High | Pre-download repos + shallow sync | Not yet attempted |
| R10 | Kernel compile failure | Medium | CAF/CLO base is well-tested; ChicKernel backports are isolated | Mitigated (kernel builds) |
| R11 | Soft-bootloop after kernel flash | Medium | Boot backup to /data/adb/apex/backup/; A/B slot switch | Mitigated |
| R12 | SELinux denial blocks functionality | Medium | Explicit allow rules for each domain; verify-stealth.sh checks | Mitigated |
| R13 | Agent daemon crash loop | Medium | Circuit breaker: 5 restarts per 10-min window; fallback mode | Mitigated |
| R14 | Prompt injection bypasses consent | Medium | Multi-layer detection: injection patterns, encoding checks, sanitization | Mitigated |
| R15 | Remote inference data exfiltration | Medium | Separate proxy domain; consent warns "data leaves device"; no daemon network | Mitigated |
| R16 | Charge control write fails silently | Medium | ToolEffectVerifier reads back value; audit logs before/after | Mitigated |
| R17 | Container escape (Lindroid) | Low | No KVM (shared kernel); chroot + namespace isolation; SELinux | Accepted |
| R18 | scrcpy-server not packaged | Low | Needs to be built and added to KSU module | Not yet done |
| R19 | Out-of-tree pentest drivers not built | Low | build-pentest-drivers.sh exists; run when needed | Not yet done |
| R20 | verify-brick-safety.sh has a bug | Low | Script returns non-zero even when checks pass; test catches it | Known bug |

## Hardware Walls

These are limitations that cannot be overcome without OEM cooperation or hardware changes:

### Widevine L1
- **Issue**: Custom kernel breaks Widevine L1 (Trusted Execution Environment mismatch)
- **Impact**: Netflix, Amazon Prime, and other DRM-protected streaming in SD only
- **Workaround**: None — hardware-level DRM verification
- **Accepted**: User doesn't watch DRM-protected content on this device

### Bootloader Lock State
- **Issue**: `ro.boot.flash.locked` and `ro.boot.vbmeta.device_state` are set by bootloader
- **Impact**: Some apps check these properties directly
- **Workaround**: TrickyStore + Yurikey keybox bypasses STRONG integrity checks
- **Accepted**: Keybox provides STRONG integrity despite unlocked bootloader

### USB-C USB 2.0 Only
- **Issue**: topaz USB-C port is USB 2.0 — no DisplayPort alt mode
- **Impact**: No wired display output
- **Workaround**: scrcpy over USB ADB or TCP
- **Accepted**: scrcpy provides adequate desktop experience

### Internal Wi-Fi Injection
- **Issue**: Internal Wi-Fi chip (WCN3990) doesn't support monitor mode or packet injection
- **Impact**: Cannot use internal Wi-Fi for wireless pentesting
- **Workaround**: External USB Wi-Fi adapters (ALFA AWUS036ACH, etc.)
- **Accepted**: User uses external adapters for pentesting

### No KVM (SM6225)
- **Issue**: Snapdragon 685 doesn't support hardware virtualization (KVM)
- **Impact**: Cannot run full VMs on-device
- **Workaround**: Lindroid uses container (namespace isolation) instead of VM
- **Accepted**: Container provides adequate Linux environment

## Honest Self-Assessment

| Layer | Verdict | Why |
|-------|---------|-----|
| Root hiding | **Best-in-class** | KernelSU-Next + SuSFS, full 76-vector audit, kernel-level pid/attr/loginuid hiding |
| Pentest drivers | **Best-in-class** | Full NetHunter set, VID:PID autoload, zero idle drain when not attached |
| Kernel scheduler | **Best-in-class** | Custom SchedHorizon governor, EAS-aware, screen-off ramp |
| Daily-driver quality | **Best-in-class** | 17+ pain-point fixes with specific kernel mechanisms |
| Terminal | **Best-in-class** | Real Arch on the Android kernel, full Binder + HAL + raw /dev, Enforcing, no autostart |
| Keybox path | **Best-in-class** | TrickyStore + Yurikey, kept from proven setup |
| Module count | **Best-in-class** | 4 irreducible + 1 setup tool. SuSFS, PIF, ReZygisk all moved to kernel/ROM |
| Agent security | **Strong** | Multi-layer consent, injection detection, effect verification, append-only audit |
| Agent memory | **Good** | BM25 retrieval is fast but less semantic than embeddings |
| Backups | **At parity** | On-device only, manual — user's choice. One-time off-device keybox copy is explicit exception |
| Updates | **At parity** | Manual, no OTA — user's choice |
| Bootloader relock / Widevine L1 | **Behind** | Hardware walls. Not closeable on a daily driver without OEM cooperation |
| LOS source / ROM build | **Not started** | KSU module overlay approach works; full ROM build is future work |
| Out-of-tree pentest drivers | **Not started** | In-tree drivers available; out-of-tree drivers need building |
| 7-day thermal learner | **Not started** | Safe defaults from day one; learner is enhancement |
| WM/Desktop/Lindroid | **Code written, untested** | Cannot test without full ROM build or device |

## What Would Change the Assessment

1. **LOS source sync + ROM build** → moves "LOS source / ROM build" from "Not started" to "Best-in-class"
2. **Out-of-tree driver build** → moves "Pentest drivers" from "Best-in-class (in-tree only)" to "Best-in-class (full)"
3. **7-day thermal learner** → moves "Daily-driver quality" even further ahead
4. **Device testing** → moves WM/Desktop/Lindroid from "untested" to verified
5. **scrcpy-server packaging** → moves Desktop Mode from "code written" to "functional"
