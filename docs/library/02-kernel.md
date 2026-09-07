# 02 — Kernel

## Base

- **Source**: CAF/CLO `bengal-5.15` (Qualcomm Code Linaro of Oregon)
- **Version**: Linux 5.15.211
- **Toolchain**: Clang 22.1.8 + LLD 22.1.8 (CachyOS LLVM)
- **Device tree**: SM6225-AD (Snapdragon 685, Redmi Note 12 4G topaz/tapas)
- **Device fixes**: ChicKernel device-fix backports (archived Feb 2026, still buildable)

## Defconfig Highlights

### Scheduler
| Config | Value | Rationale |
|--------|-------|----------|
| `CONFIG_PREEMPT` | y | Low-latency preemption for responsive UI |
| `CONFIG_HZ` | 250 | Balance between latency and overhead |
| `CONFIG_NO_HZ_IDLE` | y | Tickless idle for power saving |
| `CONFIG_HIGH_RES_TIMERS` | y | Microsecond-resolution timers |
| `CONFIG_SCHED_MC` | y | Multi-core scheduling awareness |
| `CONFIG_UCLAMP_TASK` | y | Utilization clamping for EAS |
| `CONFIG_UCLAMP_TASK_GROUP` | y | Per-cgroup utilization clamping |
| `CONFIG_SCHED_THERMAL_PRESSURE` | y | Thermal-aware scheduling |
| `CONFIG_PSI` | y | Pressure stall information for OOM detection |
| `CONFIG_ENERGY_MODEL` | y | EAS energy model for big.LITTLE |
| `CONFIG_CPU_FREQ_DEFAULT_GOV_SCHEDHORIZON` | y | Custom SchedHorizon governor (Bandido-class) |
| `CONFIG_FAIR_GROUP_SCHED` | y | CFS group scheduling |

### Memory
| Config | Value | Rationale |
|--------|-------|----------|
| `CONFIG_ZRAM` | y | Compressed swap in RAM |
| `CONFIG_ZRAM_DEF_COMP_ZSTD` | y | Zstd compression (best ratio/speed) |
| `CONFIG_ZRAM_WRITEBACK` | y | Writeback to persistent storage |
| `CONFIG_VMAP_STACK` | y | Virtually-mapped kernel stacks (guard pages) |

### Security & Hardening
| Config | Value | Rationale |
|--------|-------|----------|
| `CONFIG_RANDOMIZE_BASE` | y | KASLR — kernel address space layout randomization |
| `CONFIG_STRICT_KERNEL_RWX` | y | Read-only kernel text, writable data only |
| `CONFIG_RODATA_FULL_DEFAULT_ENABLED` | y | Full read-only data protection |
| `CONFIG_MODULE_SIG` | y | Module signature verification |
| `CONFIG_MODULE_SIG_PROTECT` | y | Only signed modules load |
| `CONFIG_MODULE_SIG_SHA1` | y | SHA1 signature hash |
| `CONFIG_SECURITY_SELINUX` | y | SELinux enabled, enforcing |
| `CONFIG_KALLSYMS` | y | Kernel symbols (SuSFS spoofs to non-root) |
| `CONFIG_AUDIT` | y | Audit subsystem |

### Root & Hiding
| Config | Value | Rationale |
|--------|-------|----------|
| `CONFIG_KSU` | y | KernelSU-Next kernel-side root |
| `CONFIG_KSU_SUSFS` | y | SuSFS hiding framework |
| `CONFIG_KSU_SUSFS_SUS_PATH` | y | Hide paths from non-root |
| `CONFIG_KSU_SUSFS_SUS_MOUNT` | y | Hide mountpoints |
| `CONFIG_KSU_SUSFS_SUS_KSTAT` | y | Hide file stat info |
| `CONFIG_KSU_SUSFS_SUS_MAPS` | y | Hide `/proc/<pid>/maps` entries |
| `CONFIG_KSU_SUSFS_TRY_UMOUNT` | y | Auto-umount hidden mounts |
| `CONFIG_KSU_SUSFS_SPOOF_UNAME` | y | Spoof uname output |
| `CONFIG_KSU_SUSFS_ENABLE_LOG` | y | SuSFS debug logging |

### APEX Custom
| Config | Value | Rationale |
|--------|-------|----------|
| `CONFIG_APEX_SYSFS` | y | APEX sysfs interface at `/sys/class/apex/` |
| `CONFIG_APEX_CHARGE` | n | Disabled — uses standard power_supply interface instead |

### Networking (Pentest)
| Config | Value | Rationale |
|--------|-------|----------|
| `CONFIG_NET_CLS_ACT` | y | Traffic classifier actions |
| `CONFIG_NET_ACT_POLICE` | y | Traffic policing |
| `CONFIG_NET_ACT_MIRRED` | y | Mirror/redirect actions (packet injection) |
| `CONFIG_NET_ACT_SKBEDIT` | y | Skb editing |
| `CONFIG_NET_ACT_BPF` | y | BPF actions |
| `CONFIG_NET_CLS_BPF` | y | BPF classifier |

### Thermal
| Config | Value | Rationale |
|--------|-------|----------|
| `CONFIG_THERMAL` | y | Thermal framework |
| `CONFIG_THERMAL_WRITABLE_TRIPS` | y | Writable trip points |
| `CONFIG_THERMAL_GOV_STEP_WISE` | y | Step-wise mitigation |
| `CONFIG_THERMAL_GOV_USER_SPACE` | y | Userspace thermal control |
| `CONFIG_THERMAL_GOV_POWER_ALLOCATOR` | y | Power allocator governor |
| `CONFIG_CPU_THERMAL` | y | CPU thermal zones |
| `CONFIG_CPU_FREQ_THERMAL` | y | CPU freq thermal mitigation |

### Namespaces (for Lindroid)
| Config | Value | Rationale |
|--------|-------|----------|
| `CONFIG_NAMESPACES` | y | Namespace support |
| `CONFIG_UTS_NS` | y | UTS namespaces |
| `CONFIG_TIME_NS` | y | Time namespaces |
| `CONFIG_NET_NS` | y | Network namespaces |
| `CONFIG_USER_NS` | n | Disabled (security: user namespaces enable privilege escalation) |
| `CONFIG_PID_NS` | n | Disabled (Lindroid uses chroot, not full PID namespace) |

### Watchdog
| Config | Value | Rationale |
|--------|-------|----------|
| `CONFIG_WATCHDOG` | y | Watchdog framework |
| `CONFIG_WATCHDOG_CORE` | y | Core watchdog infrastructure |

## Kernel Patches (patches/apex-new/)

### apex-root (KernelSU-Next + SuSFS)
The largest patch set — 81 C/H files implementing kernel-based root access:
- **core/**: KernelSU core logic, supercall dispatch, hook infrastructure
- **hook/arm64/**: ARM64-specific hooking (syscall table, inline hooks)
- **policy/**: Allowlist management, app profiles, feature flags
- **manager/**: APK signature verification, package observer, throne tracker
- **selinux/**: SELinux rule injection, sepolicy patching at runtime
- **infra/**: Event queue, file wrapper, seccomp cache, SU mount namespace
- **runtime/**: Boot events, ksud integration
- **sulog/**: Event logging, fd management
- **supercall/**: Supercall dispatch, permission checks
- **susfs.c** (1,427 lines): SuSFS hiding — path/mount/kstat/maps spoofing

### apex-sysfs
APEX sysfs interface at `/sys/class/apex/`:
- `policy` — write: screen_on, screen_off, game 0|1, charge 0|1, audio 0|1
- `state` — read: current 4-input state machine state
- `version` — read: APEX kernel version string
- `governor` — read: current governor info
- `watchdog` — read: watchdog status
- `health` — read: health check summary
- `thermal_profile` — read: learned thermal profile (7-day)
- `policy_active` — read: currently active policy

### apex-baseband-guard
Baseband security module:
- Monitors baseband modem activity
- Detects unauthorized baseband access
- Tracing infrastructure for modem IPC
- Block device helper for modem partition protection

### apex-device-backports
Hardware driver backports from newer CAF releases:
- Fingerprint sensors (FPC1020, Goodix GFx)
- Battery authentication (DS28E16 1-Wire SHA3)
- Charger ICs (BQ2589X, LN8000, SC8551, NOPMI)
- ANT+ radio
- Thermal sensor drivers

### apex-walt-scheddebug
WALT (Window Assisted Load Tracking) scheduler debug enhancements:
- Exposes WALT statistics via sched_debug
- Per-CPU load tracking visibility

### apex-base-fixes
Device-specific bug fixes for SM6225-AD on the 5.15 base.

### apex-charge
Charge control integration — uses standard `power_supply` sysfs interface rather than a custom driver. The `CONFIG_APEX_CHARGE` is disabled because the standard Qualcomm PMIC charger driver already exposes `charge_control_limit_max` via sysfs.

## Module Loading

239 kernel modules are built and packaged:
- In-tree modules: Wi-Fi (ath9k_htc, carl9170, rtl8187), SDR (rtl28xxu, hackrf, airspy), CAN (gs_usb, peak_usb, slcan), UART (ch341, ftdi_sio, cp210x, pl2303), IR (lirc, ir_toy)
- Module signing: `CONFIG_MODULE_SIG=y` with `CONFIG_MODULE_SIG_PROTECT=y` — only signed modules load
- Depmod metadata: `modules.dep`, `modules.alias`, `modules.symbols`, `modules.builtin`, `modules.symbols`
- Loading order: `anykernel3/modules/apex-load-modules.sh` handles ordered loading at boot

## Thermal Policy

APEX has no userspace thermald. All thermal policy is enforced in-kernel.

The `thermald.conf` file in the KSU module is **reference documentation only** — it documents trip points for humans. The kernel modules read battery/charger temperature directly from the `power_supply` class and apply mitigation automatically.

### Trip Points
| Zone | Warn | Throttle | Critical |
|------|------|----------|----------|
| CPU | 45°C | 55°C (A73 → 70%) | 65°C (all → 50%) |
| GPU | 50°C | 60°C | 70°C |
| Battery | 40°C | 45°C (JEITA warm) | 50°C (JEITA hot) |
| Charger skin | 45°C | 55°C (idx 4: 3.0A) | 65°C (idx 7: 1.5A) |
| Charger die | 60°C | 70°C | 80°C |

### JEITA Charging Policy
- **Warm** (>40°C battery): FCC reduced to 2.5A
- **Hot** (>45°C battery): charging stopped
- **Cold** (<5°C battery): FCC reduced to 2.5A, float voltage reduced to 4.25V

The original `mi_thermald` is disabled by the ROM overlay because the kernel modules handle all thermal policy with lower latency and more granular control.

## ZRAM Configuration

- **Enabled**: yes
- **Compression**: zstd (best ratio/speed tradeoff for 4-8GB RAM devices)
- **Writeback**: enabled (pages can be written back to persistent storage)
- **Memory tracking**: disabled (reduces overhead)

ZRAM provides compressed swap in RAM, effectively increasing available memory by ~2-3x for compressible workloads. On a 4GB device, this gives ~8-10GB of effective memory for typical Android workloads.

## Boot Flow

```
1. Bootloader loads kernel Image from boot partition
2. Kernel initializes, loads APEX sysfs module
3. KernelSU-Next initializes (hooks, policy, SELinux patching)
4. SuSFS initializes (hiding hooks)
5. Init starts, processes apex_kernel_detect.rc
6. post-fs-data.sh: kernel detection, /data/adb/apex creation, socket perms
7. service.sh: build.prop overlays, hidden packages, health monitor start
8. apex_agent.rc: apexagentd starts
9. apex_remote_proxy.rc: remote proxy starts
10. apex-bridge: chroot bridge daemon starts
11. apex_modules.rc: hiding stack module installer (one-time)
12. sys.boot_completed=1: all other services start
```

## Kernel Flash Safety

The kernel flashes via AnyKernel3 to `/dev/block/by-name/boot` only:
- **Never touches**: bootloader, aboot, TZ, modem, XBL, AOP, persist, FRP, misc, metadata
- **Boot backup**: `anykernel.sh` backs up current boot image to `/data/adb/apex/backup/boot_backup_$(date).img` before flashing
- **Slot device**: `is_slot_device=auto` — detects A/B slots automatically
- **Device check**: `do.devicecheck=1` — verifies topaz/tapas before flashing
- **Recovery**: soft-bootloop recoverable via stock boot flash or slot switch
