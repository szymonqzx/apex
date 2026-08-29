# APEX Kernel — Custom Kernel Research Synthesis

## Research Sources

Kernels studied for this synthesis:

| Kernel | Device/SoC | Base | Key Innovations |
|--------|-----------|------|-----------------|
| **ChicKernel** (chickendrop89) | Redmi Note 12/13 4G (SM6225) | android13-5.15-lts | Wakelock tweaks, boeffla WB, forced lazy RCU, power-efficient workqueues, SSG I/O tuning, 4GB RAM optimization |
| **Sultan Kernel** (Sultanxda) | Pixel 8/Pro (Tensor G3) | android16-6.1 | CASS scheduler, Tensor AIO DEVFREQ (RAM/L3), Simple LMK, TEO cpuidle fixes, uclamp battery fix, DynamIQ scheduler tuning, GCC 14.2 + LTO |
| **Optimistic Kernel** (etnperlong) | Pixel 9a (Tensor G4) | android14-6.1 | Sultan-based, MGLRU re-enabled, PSI+MEMCG, ondemand/conservative tuning, mq-deadline optimization (Xanmod), BBR v3, zstd/lz crypto updates |
| **Ahnet-69** | Various | Various | IO boost, multiple TCP congestion algorithms, Nethunter patches, AI GPU management, overclock, DRM support |
| **Wild KSU** (WildKernels) | Various (4.4-6.6) | Various | KSU-Next + SuSFS packaging, optimization patches |
| **xiaomi-6225-AD org** | SM6225-AD | bengal-5.15 | 23 repos: kernel modules, device trees, sepolicy — potential source for device-specific backports |

Additional research: DroidRooter 2026 custom kernel guide, Android performance optimization documentation, AutoFDO kernel profiling (Google blog), TCP congestion control algorithms (BBR/Westwood/CUBIC).

---

## Current APEX Kernel Inventory

What APEX already has (verified by reading source):

- Custom per-cluster CPU governor (non-linear power curve, iowait/input boost, hysteresis, fast_switch, LMH awareness, WALT integration, per-cluster auto-tuning, gaming mode)
- In-kernel control plane (screen/charge/audio/game state, thermal monitoring, GPU devfreq, health tick, incident ring, panic notifier, RTC wakealarm)
- Self-healing watchdog (5 subsystem checks, exponential backoff, 3-strike panic, boot self-check, PMIC WDT minidump)
- OOM-immortal whitelist (built-in + runtime sysctl)
- USB VID:PID autoloader for pentest drivers
- Device backports (SM5602 fuel gauge, DWC3 USB, mi_thermald fix, USB tether panic, kmsg suppression)
- Userspace bridge daemon (fork+execvp, uid 0 only, SELinux-scoped)
- Compose control app
- AlarmKeeper daemon (RTC alarm mirroring)
- Defconfig: CASS, WALT, uclamp, PSI, TEO+MENU cpuidle, BBR TCP, BFQ+MQ_DEADLINE, ZSTD zram+writeback, KSM, THP madvise, MEMCG, interconnect, DCVS, CFI, KASLR, KernelSU-Next+SuSFS
- Build system: Clang 22 + LLD, defconfig fragment merging, SELinux compilation, AnyKernel3 packaging

---

## Synthesized Improvements

Each improvement is categorized by priority, effort, and source kernel(s) that inspired it.

### Tier 1: High-Impact, Low-Effort (Do First)

#### 1. Enable ThinLTO Build
**Source:** Sultan Kernel (GCC 14.2 + LTO), Optimistic Kernel (Clang + LTO)
**Current state:** `toolchain.config` explicitly disables LTO: `# CONFIG_LTO is not set`
**Rationale:** Sultan and Optimistic both build with LTO. On a 5.15 kernel with Clang 22, ThinLTO is the safe choice — it gives most of the binary size and performance benefits of full LTO with lower build time and fewer link-time issues. Kernel accounts for ~40% of CPU time on Android (Google AutoFDO blog), so even small kernel codegen improvements compound.
**Change:**
```
# toolchain.config — replace LTO disable with ThinLTO
CONFIG_LTO=y
CONFIG_LTO_CLANG_THIN=y
# CONFIG_LTO_CLANG_FULL is not set
# CONFIG_LTO_NONE is not set
```
**Risk:** Low. ThinLTO is well-supported in Clang 22 for 5.15 kernels. If link errors occur, fall back to `CONFIG_LTO_NONE=y`.
**Verification:** Build succeeds, Image size decreases or stays same, no new warnings.

#### 2. TCP Westwood as Available Congestion Algorithm
**Source:** ChicKernel (westwood as default + BBR)
**Current state:** APEX has BBR as default (`performance.config`). No Westwood compiled in.
**Rationale:** Westwood performs better than BBR on poor/lossy 4G networks (per XDA forum analysis). For a mobile device that moves between Wi-Fi and cellular, having Westwood as a switchable option (not default) gives flexibility. ChicKernel shipped both. This is a one-line config addition.
**Change:**
```
# performance.config — add after BBR config
CONFIG_TCP_CONG_WESTWOOD=y
# BBR remains default; Westwood is selectable via sysctl
# echo westwood > /proc/sys/net/ipv4/tcp_congestion_control
```
**Risk:** Negligible. Adds a module option, no behavior change unless switched.

#### 3. Power-Efficient Workqueues
**Source:** ChicKernel (power-efficient workqueues)
**Current state:** Not set in any APEX defconfig fragment.
**Rationale:** On big.LITTLE SoCs, power-efficient workqueues route work to the little cluster when possible, saving battery. The SM6225-AD has clear A73/A53 asymmetry. This is a single Kconfig option with no code changes.
**Change:**
```
# scheduler.config — add
CONFIG_WQ_POWER_EFFICIENT=y
```
**Risk:** Low. Well-supported in 5.15. May add slight latency to work items; tunable at runtime via sysctl.

#### 4. Forced Lazy RCU
**Source:** ChicKernel (forced lazy RCU for power savings)
**Current state:** Not configured.
**Rationale:** RCU lazy batching defers grace periods, reducing wakeups on idle. On a 4-8GB device that spends significant time with screen off, this reduces idle power consumption. Available in 5.15 via `RCU_LAZY`.
**Change:**
```
# scheduler.config — add
CONFIG_RCU_LAZY=y
CONFIG_RCU_LAZY_DEFAULT_GP=10
```
**Risk:** Low. Well-tested in 5.15+. May slightly delay freeing of RCU-protected objects.

#### 5. FQ (Fair Queue) Packet Scheduler
**Source:** Required companion for BBR (Linux networking docs)
**Current state:** BBR is enabled but `CONFIG_NET_SCH_FQ` is not set.
**Rationale:** BBR performs best with FQ as the queuing discipline. Without FQ, BBR falls back to internal pacing which is less efficient. This is a known requirement documented in Linux kernel networking docs since 4.9.
**Change:**
```
# performance.config — add
CONFIG_NET_SCH_FQ=y
```
**Risk:** Negligible. Standard kernel feature.

### Tier 2: Medium-Impact, Medium-Effort

#### 6. Simple LMK (Low Memory Killer) Alternative
**Source:** Sultan Kernel (Simple LMK replaces Android's LMK)
**Current state:** APEX relies on the default Android LMK. No custom LMK configured.
**Rationale:** Sultan replaced Android's LMK with Simple LMK for more aggressive and accurate memory reclaim. On a 4GB device (Redmi Note 12 4G base variant), memory pressure is the primary cause of UI jank. Simple LMK uses a single threshold based on free memory + cache, killing the largest background process. However, this requires a patch to `drivers/staging/android/lowmemorykiller.c` or a new driver — not just a config change.
**Change:** Two options:
- **Option A (config-only):** Tune the existing LMK thresholds via init.d script (lower minfree, adjust oom_adj thresholds). Lower effort, less effective.
- **Option B (patch):** Add a `patches/apex-lmk/` directory with a Simple LMK implementation. Higher effort, more effective.
**Recommendation:** Start with Option A (init.d tuning), evaluate, then consider Option B if jank persists.
**Risk:** Medium. Incorrect LMK thresholds can cause aggressive kills or OOM panics.

#### 7. MGLRU (Multi-Gen LRU)
**Source:** Optimistic Kernel (re-enabled MGLRU, disabled SLMK, brought back PSI+MEMCG)
**Current state:** Not configured. APEX has PSI and MEMCG but not MGLRU.
**Rationale:** MGLRU improves page reclaim by tracking page generations instead of a single active/inactive list. On low-RAM devices (4GB), this reduces thrashing and improves cold-app launch. Google merged MGLRU into 5.16, but it was backported to 5.15 by some vendors. Need to check if CAF bengal-5.15 has the backport.
**Change:**
```
# zram.config — add if available in 5.15
CONFIG_LRU_GEN=y
CONFIG_LRU_GEN_ENABLED=y
```
**Risk:** Medium. If the CAF tree doesn't have MGLRU backported, this config will be silently ignored. Need to verify with `make menuconfig` or grep Kconfig.

#### 8. GPU Adreno Tuning — Min Clock Floor
**Source:** DroidRooter gaming guide (raise GPU min clock to 50-60% of max for gaming)
**Current state:** APEX's control plane sets GPU devfreq governor based on screen/gaming state but doesn't set a min clock floor.
**Rationale:** The Adreno 610 at 1260 MHz with `msm-adreno-tz` governor can drop to very low clocks during brief idle moments in games, causing frame drops. Setting a min clock floor during gaming mode (e.g., 600 MHz = ~48% of max) prevents these drops. This is a sysfs write from the control plane, not a kernel patch.
**Change:** In `apex.c`, when gaming mode is enabled, write to `/sys/class/kgsl/kgsl-3d0/devfreq/min_freq`. When disabled, restore to default min.
```c
// In apex_set_gaming_mode(bool on):
if (on) {
    // Set GPU min freq to 600MHz during gaming
    apex_sysfs_write("/sys/class/kgsl/kgsl-3d0/devfreq/min_freq", "600000000");
} else {
    // Restore default min (typically 320MHz for Adreno 610)
    apex_sysfs_write("/sys/class/kgsl/kgsl-3d0/devfreq/min_freq", "320000000");
}
```
**Risk:** Low. Reversible via sysfs. Battery impact during gaming is expected.

#### 9. KCAL Display Color Calibration
**Source:** DroidRooter 2026 guide (KCAL as standard custom kernel feature), Ahnet-69
**Current state:** Not present in APEX.
**Rationale:** KCAL allows RGB gain adjustment for the display panel. Useful for color accuracy tuning and reducing blue light at night (alternative to screen filter apps). On MDSS/DSI panels (which SM6225 uses), KCAL hooks into the MDSS driver. Requires a kernel patch to `drivers/video/fbdev/mdss/` or the DSI controller.
**Change:** Create `patches/apex-display/` with a KCAL patch that exposes `/sys/class/rgb_gains/` (or similar). The patch reads/writes MDSS PP (Ping-Pong) registers for RGB gain values.
**Risk:** Medium. Panel-specific. Incorrect values can cause display issues (recoverable on reboot). Needs testing on the actual panel.

#### 10. WireGuard VPN Backport
**Source:** Common custom kernel feature, available in mainline since 5.6
**Current state:** Not configured.
**Rationale:** WireGuard is the modern VPN protocol — faster and simpler than OpenVPN/IPSec. Already in mainline 5.6+, so 5.15 has it natively. Just needs to be enabled.
**Change:**
```
# pentest.config or new defconfig/networking.config
CONFIG_WIREGUARD=y
CONFIG_WIREGUARD_DEBUG=n
```
**Risk:** Negligible. Mainline feature in 5.15.

### Tier 3: High-Impact, High-Effort (Future Work)

#### 11. AutoFDO Build Profiling
**Source:** Google Android Developers Blog (March 2026) — "kernel accounts for 40% of CPU time"
**Current state:** Not implemented.
**Rationale:** AutoFDO (Auto Feedback-Directed Optimization) uses runtime profiling data to guide compiler code layout. Google reports measurable performance improvements on Android kernels. The workflow: build instrumented kernel → boot and run workload → collect profile → rebuild with profile-guided optimization.
**Change:** Add `tools/autofdo-build.sh` that:
1. Builds with `-fprofile-generate`
2. Flashes, boots, runs benchmark workload
3. Collects profile via `perf record` + `create_llvm_prof`
4. Rebuilds with `-fprofile-use`
**Risk:** High effort. Requires on-device profiling. Build pipeline complexity increases significantly.

#### 12. Touchscreen Processing Pipeline (twoshay-equivalent)
**Source:** Sultan Kernel (twoshay: palm/edge rejection, power reduction)
**Current state:** Not present.
**Rationale:** Sultan's twoshay pipeline improved touch quality and reduced power on Pixel devices. The SM6225 uses a Focaltech or Goodix touchscreen (device-dependent). A custom touch processing pipeline would need to be written for the specific panel driver.
**Change:** Would require reverse-engineering the touch driver's processing stages and implementing palm rejection / edge suppression in kernel. Device-specific, high effort.
**Risk:** High. Could break touch input. Needs the actual device for testing.

#### 13. DEVFREQ for RAM/L3 Cache (Tensor AIO equivalent)
**Source:** Sultan Kernel (Tensor AIO — custom DEVFREQ for RAM/L3-cache speed)
**Current state:** Not present.
**Rationale:** Sultan's Tensor AIO clocks down RAM/L3 cache faster when not needed, saving idle battery. On SM6225, the LPDDR4X is controlled by the RPM (Resource Power Manager) via SMD-RPM bus voting. A custom DEVFREQ driver for memory bandwidth would need to interface with the interconnect framework (which APEX already enables via `CONFIG_INTERCONNECT_QCOM_BENGAL`).
**Change:** Would require writing a custom DEVFREQ driver that monitors memory access patterns and votes for lower bandwidth through the interconnect framework when the CPU/GPU are idle.
**Risk:** High. Deep platform integration. Incorrect bandwidth votes can cause system instability.

#### 14. CPU Cluster Isolation for Gaming
**Source:** Ahnet-69 (AI GPU management), DroidRooter (big core foreground isolation)
**Current state:** APEX has gaming mode (governor tuning) but no CPU isolation.
**Rationale:** During gaming, isolating 1-2 big cores (A73) exclusively for the foreground game process and pushing all background tasks to the little cluster (A53) reduces scheduling contention. This is done via cgroup cpuset assignment.
**Change:** In the gaming mode activation (`apex.c`), write cpuset configuration:
```
# Move background tasks to little cluster
echo 4-7 > /dev/cpuset/background/cpus
# Reserve 1 big core for foreground game
echo 0-3 > /dev/cpuset/foreground/cpus
# Pin foreground app to big cluster
echo 0-3 > /dev/cpuset/system/cpus
```
**Risk:** Medium. Needs careful cgroup setup. Incorrect cpuset can starve system services.

#### 15. exFAT/NTFS Driver Backport
**Source:** Common custom kernel feature for USB OTG storage support
**Current state:** Not configured.
**Rationale:** USB OTG with exFAT/NTFS USB drives is a common use case. Linux 5.15 has native exFAT (`CONFIG_EXFAT_FS`) and NTFS3 (`CONFIG_NTFS3`). Just needs enabling.
**Change:**
```
# New defconfig/filesystems.config or add to pentest.config
CONFIG_EXFAT_FS=y
CONFIG_EXFAT_DEFAULT_IOCHARSET="utf8"
CONFIG_NTFS3_FS=y
CONFIG_NTFS3_64BIT_CLUSTER=y
```
**Risk:** Negligible. Mainline features in 5.15.

### Tier 4: Investigate / Monitor

#### 16. xiaomi-6225-AD Organization Repositories
**Source:** GitHub org `xiaomi-6225-AD` (23 repos)
**Current state:** APEX is based on ChicKernel's tree. The xiaomi-6225-AD org has kernel modules, device trees, and sepolicy specifically for SM6225-AD.
**Action:** Clone and diff their `android_kernel_xiaomi_sm6225-modules` and `android_kernel_xiaomi_sm6225-devicetrees` against the ChicKernel tree to identify:
- Device-specific fixes not in ChicKernel
- Updated device trees with corrected OPP tables / thermal zones
- Sepolicy updates for bengal-5.15
**Risk:** Low (investigation only). Merge decisions per-commit.

#### 17. IRQ Balancer Tuning (SBalance)
**Source:** Sultan Kernel (fixed "huge bug in IRQ balancer SBalance")
**Current state:** APEX uses default IRQ balancing.
**Rationale:** Sultan found and fixed a severe bug in the IRQ balancer on Pixel devices. While SM6225 uses a different IRQ topology, reviewing the IRQ balancer configuration for the bengal platform could reveal similar issues.
**Action:** Review `/proc/interrupts` distribution during gaming and idle. Check if `CONFIG_IRQ_TIME_ACCOUNTING` (already enabled) is sufficient or if custom IRQ affinity tuning is needed.

#### 18. zRAM Compression Algorithm Benchmark
**Source:** Optimistic Kernel (updated zstd & lz crypto)
**Current state:** APEX uses ZSTD for zRAM.
**Rationale:** ZSTD is the right default, but on A73/A53 cores, LZ4 may decompress faster (lower latency for page-in) at the cost of lower compression ratio. On a 4GB device, compression ratio matters more than decompression speed, so ZSTD is likely correct. Worth benchmarking.
**Action:** Build with both `CONFIG_ZRAM_DEF_COMP_ZSTD` and `CONFIG_ZRAM_DEF_COMP_LZ4`, run Geekbench + memory pressure tests, compare.

---

## Priority Matrix

| # | Improvement | Impact | Effort | Priority |
|---|------------|--------|--------|----------|
| 1 | ThinLTO build | Medium | Low | **P0** |
| 2 | TCP Westwood available | Low | Low | **P0** |
| 3 | Power-efficient workqueues | Medium | Low | **P0** |
| 4 | Forced lazy RCU | Medium | Low | **P0** |
| 5 | FQ packet scheduler | Medium | Low | **P0** |
| 10 | WireGuard VPN | Low | Low | **P0** |
| 15 | exFAT/NTFS filesystems | Low | Low | **P0** |
| 8 | GPU min clock floor (gaming) | High | Low-Med | **P1** |
| 6a | LMK threshold tuning | Medium | Low | **P1** |
| 7 | MGLRU | High | Medium | **P1** |
| 9 | KCAL display calibration | Medium | Medium | **P2** |
| 14 | CPU cluster isolation (gaming) | High | Medium | **P2** |
| 16 | xiaomi-6225-AD repo investigation | Unknown | Low | **P2** |
| 6b | Simple LMK patch | High | High | **P3** |
| 11 | AutoFDO profiling | High | High | **P3** |
| 12 | Touch processing pipeline | Medium | High | **P3** |
| 13 | RAM/L3 DEVFREQ driver | Medium | High | **P3** |
| 17 | IRQ balancer review | Unknown | Low | **P3** |
| 18 | zRAM compression benchmark | Low | Low | **P3** |

---

## What APEX Already Does Better Than Its Peers

This is worth noting — APEX has several features that ChicKernel, Sultan, and others don't have:

1. **In-kernel thermal learner** — 7-day moving average thermal pattern learning with persistent state. No other custom kernel for this device class has this.
2. **Self-healing watchdog** — 5-subsystem monitoring with exponential backoff and 3-strike panic. Sultan fixes bugs reactively; APEX detects and recovers proactively.
3. **Non-linear power curve governor** — Most custom kernels use schedutil or ondemand with default parameters. APEX's governor with quadratic power curve mapping, iowait/input boost, and per-cluster auto-tuning is more sophisticated.
4. **Pentest USB autoload** — NetHunter-compatible driver autoloading via VID:PID matching. Unique among custom kernels for this device.
5. **Incident ring + panic notifier** — In-kernel crash logging with ring buffer. Most custom kernels rely on pstore/ramoops only.
6. **Userspace bridge with SELinux scoping** — Formal SELinux policy for the bridge daemon. Most custom kernels have no userspace integration.
7. **RTC wakealarm mirroring** — AlarmManager-to-PMIC bridge for deep sleep alarm reliability.

---

## Recommended Implementation Order

### Phase 1: Config-Only Changes (P0 items — all defconfig, no code)
1. ThinLTO in `toolchain.config`
2. TCP Westwood in `performance.config`
3. Power-efficient workqueues in `scheduler.config`
4. Forced lazy RCU in `scheduler.config`
5. FQ packet scheduler in `performance.config`
6. WireGuard in `pentest.config` (or new `networking.config`)
7. exFAT/NTFS in a new `filesystems.config`

All of these are Kconfig additions. No source code changes. Can be done in a single commit, verified by `check-configs.py` and a test build.

### Phase 2: Low-Code Changes (P1 items)
8. GPU min clock floor — add sysfs write to `apex.c` gaming mode handler
9. LMK threshold tuning — add to `rom-overlays/bin/apex-alarmkeeper.c` or a new init.d script
10. MGLRU — verify availability in CAF 5.15, add config if available

### Phase 3: Medium-Effort Patches (P2 items)
11. KCAL display calibration — new `patches/apex-display/` patch
12. CPU cluster isolation — add cpuset writes to gaming mode in `apex.c`
13. xiaomi-6225-AD repo investigation — clone, diff, identify backports

### Phase 4: Research / Future (P3 items)
14. Simple LMK — design and implement if Phase 2 LMK tuning is insufficient
15. AutoFDO — build pipeline for profile-guided optimization
16. Touch processing pipeline — device-specific research
17. RAM/L3 DEVFREQ — platform driver development
18. IRQ balancer review — diagnostic work
19. zRAM compression benchmark — A/B testing

---

## Summary

APEX is already more feature-complete than ChicKernel (its base) in every dimension: governor sophistication, control plane, watchdog, thermal learning, and security. The gaps identified through this research are primarily:

- **Missing config options** (7 items, all P0): ThinLTO, Westwood, power-efficient workqueues, lazy RCU, FQ scheduler, WireGuard, exFAT/NTFS — all one-line Kconfig additions
- **Missing tuning** (2 items, P1): GPU min clock floor, LMK threshold adjustment — small code or script additions
- **Missing features** (5 items, P2-P3): KCAL, cluster isolation, Simple LMK, AutoFDO, touch pipeline — require new patches or build infrastructure
- **Investigation opportunities** (3 items): xiaomi-6225-AD repos, IRQ balancer, zRAM benchmark — diagnostic work

The P0 batch is the highest ROI: 7 config-only changes that bring APEX to parity with Sultan/Optimistic on build optimization and networking, with zero code risk. Recommend implementing Phase 1 immediately.
