# APEX Kernel Patches

## Applied Patches

### Tier 1: Base & Device Compatibility
- **ChicKernel 5.15.189 base tree** — imported from ChicKernel/device_xiaomi_gemstones-kernel
- **Stable upgrade 5.15.189 → 5.15.211** — 3741 files, +45263/-49446, 88 hunks fuzzy-matched
- **sched_param redefinition** — rename UAPI `struct sched_param` to `__kernel_sched_param` for ROM header compat
- **Topaz module lists** — 96 module entries, 54 vendor blocklist entries, empty systemdlkm blocklist
- **Baseband guard (BBG)** — anti-brick modem protection with efisp exploit mode (3 patches)
- **hdlc_ppp revert** — not needed (CAF tree doesn't have the problematic timer sync code)

### Tier 2: Performance & Optimization (WildKernels common)
- **disable_cache_hot_buddy** — reduce cache allocation bias
- **f2fs_enlarge_min_fsync_blocks** — larger fsync batch for F2FS
- **f2fs_reduce_congestion** — reduce F2FS congestion wait
- **file_struct_8bytes_align** — 8-byte alignment for file struct
- **force_tcp_nodelay** — enable TCP_NODELAY by default
- **increase_ext4_default_commit_age** — longer ext4 commit interval
- **increase_sk_mem_packets** — larger socket memory allocation
- **int_sqrt** — optimized integer square root
- **mem_opt_prefetch** — memory-optimized prefetch
- **minimise_wakeup_time** — reduce wakeup processing time
- **optimise_memcmp** — optimized memcmp for arm64
- **optimized_mem_operations** — general memory operation optimizations
- **reduce_cache_pressure** — lower vm_cache_pressure
- **reduce_freeze_timeout** — shorter freeze timeout
- **reduce_gc_thread_sleep_time** — reduce F2FS GC thread sleep
- **reduce_pci_pme_wakeups** — reduce PCI PME wakeup events
- **silence_irq_cpu_logspam** — suppress IRQ CPU hotplug log spam
- **silence_system_logspam** — suppress system log spam
- **clear_page_16bytes_align** — 16-byte aligned clear_page
- **adjust_cpu_scan_order** — optimize CPU scan order for task scheduling
- **add_limitation_scaling_min_freq** — enforce scaling_min_freq floor
- **add_timeout_wakelocks_globally** — global wakelock timeout
- **avoid_extra_s2idle_wake_attempts** — reduce s2idle wake attempts
- **fake_config** — kernel build config spoofing
- **IPv6_NAT_FIX** — IPv6 NAT support fix
- **Droidspaces** — USER_NS guard, ghost task, POSIX mqueue ABI, SYSVIPC KABI (1-8)

### Tier 2: Networking
- **BBRv3** — TCP Bottleneck Bandwidth and RTT v3 with PLB (22 files, 3034 insertions)
- **ntsync** — Windows sync primitives for Wine/Proton gaming (1344 insertions)

### Tier 3: Root & Security
- **KSU hooks** — KernelSU-Next manual hook points (execve, faccessat, keyctl, pty, input)
- **syscall_hooks** — syscall-level hooks for KSU sucompat
- **ABI bypass GKI** — bypass GKI ABI checks for custom modules
- **Conditional vendor module blacklisting** — runtime module blacklist support
- **SuSFS** — already integrated in ChicKernel base (dentry NULL safety checks present)

### Tier 4: Custom APEX Drivers (from initial skeleton)
- **apex.c** — APEX state machine: /proc/apex/* surface, 16-row decision table
- **apex_watchdog.c** — self-healing watchdog: CPU, GPU, thermal, ZRAM, battery checks
- **apex_immortal.c** — OOM-immortal process protection
- **cpufreq_apex.c** — APEX CPU frequency governor

## Patch Sources
- WildKernels/kernel_patches (common/, wild/hooks, sultan, experimental)
- topnotchfreaks/kernel_msm-5.15 (zepharo branch — reference for LTS/CLO sync)
- kernel.org stable (linux-5.15.y branch)

## Skipped Patches (with reasons)
- Sultan hooks — conflict with wild/hooks (same files, already applied)
- QRTR xarray refactor — ABI-breaking upstream change, CAF QRTR is functional
- F2FS upstream cleanups — CAF F2FS works, WildKernels F2FS optimizations applied instead
- xhci graceperiod — feature not present in CAF tree
- regmap NULL check removal — unsafe (removes safety check)
- timer.h type change — ABI-breaking
