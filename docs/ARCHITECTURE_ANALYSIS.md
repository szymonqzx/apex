# Redmi Note 12 4G — Deep Architecture Analysis & Kernel Improvement Opportunities

## Device: Redmi Note 12 4G (codename: tapas/topaz)
## SoC: Qualcomm Snapdragon 685 (SM6225-AD), codename "khaje" in CAF trees
## Kernel: Linux 5.15.189 (CAF bengal-5.15 branch), ChicKernel base

---

## 1. SoC Architecture Deep Dive

### CPU Complex
- **Big cluster**: 4x Cortex-A73 (Kryo 265 Gold) @ 2.8 GHz, 6nm
- **Little cluster**: 4x Cortex-A53 (Kryo 265 Silver) @ 1.9 GHz
- **Architecture**: ARMv8.2-A (A32 + A64), 64-bit
- **Cache**: A73 has 2MB L2 shared per cluster; A53 has 512KB L2 per cluster
- **Key limitation**: A73 is an older big core (2016 design) — no DSU, no split L3
- **big.LITTLE topology**: Two separate cpufreq policies (per-cluster), not per-core
- **Hardware DVFS**: EPSS (Enhanced Power Save State) via qcom-cpufreq-hw, NOT OSM
  - EPSS uses 4-byte LUT rows, perf_state register at offset 0x320
  - Supports fast_switch (direct register write, no mailbox)
  - LMH (Limits Management Hardware) IRQ for thermal throttling

### GPU
- **Adreno 610** @ ~950-1260 MHz (Qualcomm underclocks to ~845 MHz on SD685)
- **Driver**: KGSL (vendor module, not in base tree — loaded from vendor partition)
- **No DRM_MSM**: Display path is vendor KGSL + MDP/DPU, not upstream DRM
- **Devfreq governors**: Performance, Powersave, Userspace, Passive available
- **Key limitation**: Adreno 610 is OpenGL ES 3.2 only, no Vulkan 1.1, very limited compute

### Memory Subsystem
- **RAM**: LPDDR4X dual-channel @ 2133 MHz, 17 GB/s peak bandwidth
- **Variants**: 4/6/8 GB (your device likely 8 GB)
- **No L3 cache** (A73/A53 lack DSU — L3 is SoC-level CCI/LLCC)
- **Interconnect**: CAF ICC-RPM (bengal.c), SMD-RPM bus voting
- **No BWMON** in chickernel config (CONFIG_QCOM_BWMON=m in vendor GKI but not merged)

### Peripherals & Connectivity
- **Modem**: Snapdragon X11 LTE (Cat 13 DL 390 Mbps / Cat 13 UL 150 Mbps)
- **Wi-Fi**: FastConnect 6200 (802.11ac 2x2 MIMO, 867 Mbps) — WCN3980 chipset
- **Bluetooth**: BT 5.2 via QCA HCI UART
- **ISP**: Spectra 346 (triple camera, up to 192 MP)
- **DSP**: Hexagon 686
- **Audio**: WCD9375 codec via SLIMBus
- **Storage**: UFS 2.2 (not eMMC — important for I/O tuning)
- **Display**: Super AMOLED 1080x2400 @ 120 Hz, MIPI-DSI
- **Battery**: 5000 mAh, SMB1355 charger + SM5602 fuel gauge
- **PMIC**: PM6115 + PM6125
- **USB**: DWC3 USB 3.1 (Type-C with FSA4480 USB-C switch)
- **IR blaster**: Present (Redmi-specific feature)
- **NFC**: ST54 (if equipped — variant-dependent)

### Thermal Architecture
- **TSENS**: Qualcomm TSENS thermal sensors
- **LMH**: Hardware-level DCVS throttling via IRQ
- **mi_thermald**: Xiaomi's userspace thermal daemon (known bug: wrong-core shutdown)
- **Thermal zones**: CPU, GPU, modem, battery, skin
- **Cooling devices**: CPU frequency, GPU frequency, modem, hotplug

---

## 2. Current Kernel Configuration Analysis

### What ChicKernel Already Does Right
1. **CONFIG_SCHED_CASS=y** — Sultan Alsawaf's Capacity Aware Superset Scheduler
   - Better than stock CFS for big.LITTLE — uses capacity-relative utilization
   - Optimizes wake-up CPU selection for A73/A53 asymmetry
2. **CONFIG_ZRAM=y + ZSTD** — Best-in-class swap compression
3. **CONFIG_PREEMPT=y** — Low-latency preemption (good for UI responsiveness)
4. **CONFIG_PSI=y** — Pressure stall information (enables Android's memory/CPU/IO pressure detection)
5. **CONFIG_BFQ_GROUP_IOSCHED=y** — Fair queuing I/O scheduler with cgroup awareness
6. **CONFIG_F2FS_FS_COMPRESSION=y** — F2FS inline compression
7. **CONFIG_EROFS_FS_PCPU_KTHREAD=y + HIPRI=y** — Parallelized EROFS decompression
8. **CONFIG_CPU_FREQ_DEFAULT_GOV_PERFORMANCE=y** — Max performance default
9. **CONFIG_SCHEDSTATS=y** — Scheduler statistics for debugging
10. **CONFIG_UCLAMP_TASK=y + UCLAMP_TASK_GROUP=y** — Utilization clamping for RT tasks

### What's Missing or Suboptimal

#### A. CPU Frequency & Governor (HIGH IMPACT)

**Problem 1: CONFIG_CPU_FREQ_DEFAULT_GOV_PERFORMANCE=y**
- The chickernel defaults to `performance` governor, which pins CPU at max frequency always
- This wastes enormous battery for zero benefit when the screen is off or during light tasks
- The `apex` governor (being written) addresses this, but it's not yet integrated
- **Fix**: Switch to `schedutil` as default (already compiled), or `apex` once integrated
- The `scheduler.config` fragment correctly targets `CONFIG_CPU_FREQ_DEFAULT_GOV_SCHEDUTIL=y` but the chickernel defconfig overrides it

**Problem 2: No fast_switch utilization in schedutil**
- The qcom-cpufreq-hw driver supports `fast_switch` (direct EPSS register write)
- schedutil checks `policy->fast_switch_enabled` and uses it for sub-microsecond transitions
- But the chickernel uses `performance` governor, bypassing schedutil entirely
- **Fix**: Enable schedutil as default — it will automatically use fast_switch

**Problem 3: No WALT (Window Assisted Load Tracking)**
- The scheduler.config fragment specifies `CONFIG_SCHED_WALT=y` but it's not in the chickernel defconfig
- WALT is Qualcomm's load tracking that feeds schedutil with better utilization data
- On CAF kernels, WALT + schedutil outperforms PELT + schedutil for big.LITTLE
- Without WALT, schedutil uses PELT signals which are less responsive on this SoC
- **Fix**: Enable CONFIG_SCHED_WALT=y (the tree has the full WALT implementation in kernel/sched/walt/)

**Problem 4: No DCVS hardware governor**
- CONFIG_QCOM_DCVS is not enabled in chickernel
- DCVS (Dynamic Clock and Voltage Scaling) is Qualcomm's hardware-assisted DVFS
- The EPSS driver in the tree supports hardware-forwarded DVFS
- Without DCVS, all frequency transitions go through the kernel governor software path
- **Fix**: Enable CONFIG_QCOM_DCVS=m (module, loaded from vendor)

#### B. CPU Idle & Power States (HIGH IMPACT)

**Problem 5: Missing CPU_IDLE_MULTIPLE_DRIVERS**
- Stock khaje has `CONFIG_CPU_IDLE_MULTIPLE_DRIVERS=y` — chickernel doesn't
- Without this, both clusters share one cpuidle driver, preventing per-cluster idle state optimization
- A73 and A53 have different power characteristics and need different idle state tables
- **Fix**: Enable CONFIG_CPU_IDLE_MULTIPLE_DRIVERS=y

**Problem 6: Missing CPU_IDLE_GOV_MENU**
- Stock has both MENU and TEO governors; chickernel only has TEO
- MENU is better for systems with predictable idle patterns (phones)
- TEO (Timer Events Oriented) is better for server-like workloads
- Having both costs nothing and allows runtime switching
- **Fix**: Enable CONFIG_CPU_IDLE_GOV_MENU=y

**Problem 7: Missing ARM_CPUIDLE**
- Stock has `CONFIG_ARM_CPUIDLE=y` — chickernel doesn't
- ARM_CPUIDLE provides the generic ARM CPU idle driver
- PSCI CPUIDLE is present but ARM_CPUIDLE provides additional platform-specific states
- **Fix**: Enable CONFIG_ARM_CPUIDLE=y

**Problem 8: Missing ARM_PSCI_CPUIDLE_DOMAIN**
- Stock has `CONFIG_ARM_PSCI_CPUIDLE_DOMAIN=y` — chickernel doesn't
- This enables OS-initiated CPU power domain management via PSCI
- Allows the kernel to power down entire clusters when all CPUs are idle
- On A73/A53 big.LITTLE, cluster power-down saves significant power
- **Fix**: Enable CONFIG_ARM_PSCI_CPUIDLE_DOMAIN=y

#### C. HZ / Tick Rate (MEDIUM IMPACT)

**Problem 9: HZ not configured (defaults to 100)**
- The chickernel defconfig doesn't set CONFIG_HZ at all
- The scheduler.config fragment targets HZ=200, but it's not applied
- At HZ=100, the scheduler tick fires every 10ms — too coarse for UI responsiveness
- At HZ=250 (stock), it's 4ms — better but higher overhead
- HZ=200 is the sweet spot for this SoC: 5ms granularity, manageable overhead
- With NO_HZ_IDLE (already targeted), idle CPUs don't tick at all
- **Fix**: Set CONFIG_HZ=200, CONFIG_HZ_200=y, CONFIG_NO_HZ_IDLE=y

#### D. Memory Management (MEDIUM IMPACT)

**Problem 10: No KSM (Kernel Samepage Merging)**
- `# CONFIG_KSM is not set` in both stock and chickernel
- With 4-8 GB RAM, KSM can deduplicate identical pages (common in Android with multiple Zygote forks)
- KSM has minimal CPU overhead when `ksm_thread_pages_to_scan` is tuned low
- **Fix**: Enable CONFIG_KSM=y (optional — enable with conservative scan rate)

**Problem 11: No ZRAM_WRITEBACK**
- ZRAM is enabled with ZSTD but writeback is disabled
- ZRAM writeback allows compressed pages to be written to flash when RAM is exhausted
- On UFS 2.2, writeback is fast enough to be useful
- **Fix**: Enable CONFIG_ZRAM_WRITEBACK=y (allows the device to use flash as swap extension)

**Problem 12: No ZSWAP**
- ZSWAP provides a compressed RAM cache for swap pages
- Works alongside ZRAM but caches pages before they hit the swap device
- **Fix**: Consider CONFIG_ZSWAP=y with ZSTD compressor and zsmalloc allocator

**Problem 13: CONFIG_USERFAULTFD=y — Security risk**
- userfaultfd() is a known exploitation primitive for Android
- Used in dirty pipe and other exploits for page manipulation
- On a hardened kernel (which this aims to be), it should be disabled
- **Fix**: Set `# CONFIG_USERFAULTFD is not set`

#### E. I/O Subsystem (MEDIUM IMPACT)

**Problem 14: No F2FS_IOSTAT**
- `# CONFIG_F2FS_IOSTAT is not set` — disables I/O statistics in F2FS
- Without IOSTAT, Android's storage performance dashboard can't report
- This costs nothing to enable and provides valuable debugging data
- **Fix**: Enable CONFIG_F2FS_IOSTAT=y

**Problem 15: Missing MQ_DEADLINE scheduler**
- BFQ is enabled (good for fairness) but MQ_DEADLINE is not
- MQ_DEADLINE has lower overhead than BFQ and is better for latency-sensitive I/O
- On UFS 2.2, MQ_DEADLINE can provide better read latency for app launches
- **Fix**: Enable CONFIG_MQ_DEADLINE=y as alternative I/O scheduler

#### F. Interconnect & Memory Bandwidth (MEDIUM IMPACT)

**Problem 16: No INTERCONNECT_QCOM in chickernel**
- The bengal interconnect driver (CONFIG_INTERCONNECT_QCOM_BENGAL=m) is in vendor GKI
- Without it, memory bandwidth voting doesn't work — CPU/GPU/modem can't request bandwidth
- This means the interconnect stays at a default level, either too high (wasting power) or too low (hurting performance)
- **Fix**: Ensure INTERCONNECT_QCOM_BENGAL module is loaded from vendor (or built-in)

**Problem 17: No QCOM_BWMON**
- BWMON monitors memory bandwidth and feeds DCVS for adaptive bandwidth scaling
- Without BWMON, the interconnect can't react to bandwidth demand changes
- **Fix**: Ensure CONFIG_QCOM_BWMON=m is available (vendor module)

#### G. GPU / Display (MEDIUM IMPACT)

**Problem 18: No GPU devfreq optimization**
- Adreno 610 runs via KGSL vendor module
- The apex state machine could control GPU frequency via devfreq sysfs
- Currently no GPU thermal cap in the apex policy table
- **Fix**: Add GPU devfreq management to apex-state (write to /sys/class/devfreq/qcom,gpubw/governor)

**Problem 19: No display panel refresh rate control**
- Super AMOLED 120 Hz — but no kernel-side refresh rate management
- The display driver (vendor MDP/DPU) handles this, but kernel could hint
- **Fix**: Add display state to apex-state (screen on/off already tracked, could add refresh rate hint)

#### H. Thermal Management (HIGH IMPACT)

**Problem 20: mi_thermald wrong-core shutdown bug**
- ChicKernel fixed this (commit 3e85c4293b) but the fix needs to be in the apex tree
- Without the fix, mi_thermald shuts down A53 cores instead of A73 cores during thermal events
- This is backwards — it kills the efficiency cores and forces everything onto the hot performance cores
- **Fix**: Backport the mi_thermald fix from ChicKernel (already in patches/README.md as planned)

**Problem 21: No thermal cap integration with apex governor**
- The apex governor has `cpu_thermal_cap` in the policy table but it's not wired
- The governor should clamp policy->max when thermal events occur
- **Fix**: Wire apex_gov_set_thermal_cap() to the thermal cooling device

#### I. Security & Hardening (LOW-MEDIUM IMPACT)

**Problem 22: ARM64_BTI disabled**
- `# CONFIG_ARM64_BTI is not set` in chickernel
- BTI (Branch Target Identification) is an ARMv8.5 security feature
- Cortex-A73 doesn't support BTI (it's ARMv8.2-A), but the kernel should still enable it for forward compatibility
- Actually: A73 does NOT support BTI, so this is correctly disabled
- **No fix needed** — this is correct for the hardware

**Problem 23: ARM64_AMU_EXTN disabled**
- `# CONFIG_ARM64_AMU_EXTN is not set` in chickernel
- AMU (Activity Monitor Unit) provides hardware CPU utilization counters
- A73 does have AMU v1 (ARMv8.4 extension), but it's optional
- If present, AMU provides better utilization data to schedutil than PELT
- **Fix**: Check if the SoC supports AMU — if yes, enable it

**Problem 24: No STRICT_DEVMEM in chickernel**
- The hardening.config fragment specifies CONFIG_STRICT_DEVMEM=y
- But the chickernel defconfig doesn't have it
- **Fix**: Enable CONFIG_STRICT_DEVMEM=y and CONFIG_IO_STRICT_DEVMEM=y

#### J. Scheduler Features (MEDIUM IMPACT)

**Problem 25: SCHED_FEAT tuning not optimized**
- Current features.h has defaults from upstream
- For a phone with A73/A53, some features should be tuned:
  - `NEXT_BUDDY=false` (default) — correct for big.LITTLE (prevents cache-buddy from pinning to wrong cluster)
  - `SIS_PROP=true` — limits LLC scan, good for 2-cluster systems
  - `UTIL_EST=true` — good for schedutil responsiveness
  - `GENTLE_FAIR_SLEEPERS=true` — good for UI responsiveness
- **Potential improvement**: Consider `NONTASK_CAPACITY=true` (already true) and ensure `UTIL_EST_FASTUP=true` (already true)

**Problem 26: No PREEMPT_DYNAMIC**
- The scheduler.config targets PREEMPT_DYNAMIC but chickernel has CONFIG_PREEMPT=y (static)
- PREEMPT_DYNAMIC allows runtime switching between voluntary and full preemption
- On a phone, you want full preemption for UI but could switch to voluntary for gaming/battery
- **Fix**: Enable CONFIG_PREEMPT_DYNAMIC=y (if the tree supports it with PREEMPT=y)

#### K. Apex Governor Code Review (from Devin session)

**Issue 27: apex_dbs_update always calls apex_update**
```c
static unsigned int apex_dbs_update(struct cpufreq_policy *policy)
{
    struct policy_dbs_info *policy_dbs = policy->governor_data;
    if (policy_dbs->rate_mult)
        apex_update(policy);
    else
        apex_update(policy);
    return 0;
}
```
- Both branches call apex_update() — the rate_mult check is dead code
- The rate_mult exists in the dbs framework to slow down sampling during idle
- **Fix**: Use rate_mult to skip updates during low activity, or remove the dead branch

**Issue 28: apex_load_to_freq uses linear mapping**
- Linear load-to-frequency mapping is suboptimal for A73
- A73 has a non-linear power curve — below ~60% load, lower frequencies are much more efficient
- The mapping should use a curve that favors lower frequencies for mid-range loads
- **Fix**: Use a piecewise or quadratic mapping that biases toward lower frequencies

**Issue 29: No iowait boost in apex governor**
- schedutil has iowait_boost for I/O-bound tasks (boosts frequency on I/O completion)
- The apex governor doesn't implement iowait boost
- On UFS storage, I/O completion boost helps app launch latency
- **Fix**: Add iowait boost similar to schedutil's implementation

**Issue 30: No per-policy tunables**
- The apex governor uses global tunables (up_threshold, screen_off_pct)
- A73 and A53 clusters have different optimal thresholds
- A73 should have a higher up_threshold (it's already fast, don't ramp unnecessarily)
- A53 should have a lower up_threshold (ramp up quickly to avoid migration to A73)
- **Fix**: Make tunables per-policy, or use cluster-aware defaults

---

## 3. Improvement Priority Matrix

| # | Improvement | Impact | Effort | Category |
|---|---|---|---|---|
| 1 | Switch default governor from performance to schedutil | HIGH | LOW | CPUFreq |
| 2 | Enable WALT load tracking | HIGH | LOW | Scheduler |
| 3 | Enable CPU_IDLE_MULTIPLE_DRIVERS | HIGH | LOW | Power |
| 4 | Set HZ=200 with NO_HZ_IDLE | HIGH | LOW | Scheduler |
| 5 | Backport mi_thermald wrong-core fix | HIGH | MEDIUM | Thermal |
| 6 | Enable ARM_PSCI_CPUIDLE_DOMAIN | HIGH | LOW | Power |
| 7 | Fix apex governor dead code (rate_mult) | MEDIUM | LOW | CPUFreq |
| 8 | Add iowait boost to apex governor | MEDIUM | MEDIUM | CPUFreq |
| 9 | Non-linear load-to-freq mapping in apex | MEDIUM | MEDIUM | CPUFreq |
| 10 | Enable KSM with conservative scan | MEDIUM | LOW | Memory |
| 11 | Enable ZRAM_WRITEBACK | MEDIUM | LOW | Memory |
| 12 | Disable USERFAULTFD | MEDIUM | LOW | Security |
| 13 | Enable MQ_DEADLINE I/O scheduler | MEDIUM | LOW | I/O |
| 14 | Enable F2FS_IOSTAT | LOW | LOW | I/O |
| 15 | Per-policy tunables for apex governor | MEDIUM | HIGH | CPUFreq |
| 16 | Wire thermal cap to apex governor | MEDIUM | MEDIUM | Thermal |
| 17 | Enable STRICT_DEVMEM | LOW | LOW | Security |
| 18 | Enable CPU_IDLE_GOV_MENU | LOW | LOW | Power |
| 19 | Enable ARM_CPUIDLE | LOW | LOW | Power |
| 20 | GPU devfreq integration with apex | MEDIUM | HIGH | GPU |

---

## 4. Specific Kernel Code Improvements (Beyond Config)

### 4.1 WALT + Schedutil Integration
The tree has the full WALT implementation in `kernel/sched/walt/` but it's not enabled. Enabling WALT provides:
- Window-based load tracking (better than PELT for bursty phone workloads)
- Input boost (touch event → CPU frequency boost) via `walt/input-boost.c`
- Core control (dynamic CPU hotplug for power saving) via `walt/core_ctl.c`
- WALT-based schedutil updates (more responsive frequency selection)

The WALT code also includes:
- `walt_lb.c` — WALT-aware load balancer
- `walt_cfs.c` — WALT CFS integration
- `walt_rt.c` — WALT RT scheduler integration
- `walt_halt.c` — WALT-aware CPU halting

### 4.2 EPSS Fast Switch Optimization
The qcom-cpufreq-hw driver already supports fast_switch via direct EPSS register write:
```c
static unsigned int qcom_cpufreq_hw_fast_switch(struct cpufreq_policy *policy,
                                                unsigned int target_freq)
{
    writel_relaxed(index, data->base + soc_data->reg_perf_state);
    return policy->freq_table[index].frequency;
}
```
This means schedutil can do sub-microsecond frequency transitions. The key is ensuring:
1. `policy->fast_switch_possible = true` is set (it is, at line 265)
2. schedutil is the active governor (not performance)
3. WALT is feeding utilization data

### 4.3 LMH/DCVS Hardware Throttling
The EPSS driver has LMH (Limits Management Hardware) support:
- IRQ-based thermal throttling notification
- `dcvsh_freq_limit` — hardware-enforced frequency cap
- `disable_dcvsh_freq_limit` — userspace override (for benchmark mode)
- The apex governor should respect `dcvsh_freq_limit` by reading it before setting frequency

### 4.4 Interconnect Bandwidth Voting
The bengal interconnect driver provides per-path bandwidth voting via SMD-RPM:
- APPS→DDR (BIMC) bandwidth
- APPS→Config (CNOC) bandwidth  
- APPS→System (SNOC) bandwidth
- Without the interconnect module loaded, these paths run at default (likely max) bandwidth
- Loading the module allows dynamic bandwidth scaling based on CPU/GPU/modem demand

### 4.5 SM5602 Fuel Gauge Fix
ChicKernel fixed the SM5602 fuel gauge driver after the 5.15.149 merge:
- Commit 2b14b93963328af3fb023c02c9c8a705a71eb8a7
- Without this fix, fuel gauge reports wrong battery percentage after kernel upgrade
- This is in the patches/README.md as a planned backport

### 4.6 DWC3-MSM-Core USB Fix
ChicKernel fixed USB (dwc3-msm-core) after the 5.15.149 merge:
- Same commit as fuel gauge
- Without this fix, USB connectivity breaks (no adb, no charging via USB data)
- Also fixes kernel panic on USB tethering (commit 082c1c59)

### 4.7 KMSG Spam Suppression
ChicKernel suppressed vendor kmsg debugging from modules without source:
- Multiple commits (06af5ac8, 3cc1c53a, e6036fdd, 57c46727)
- Reduces dmesg noise from closed-source vendor modules
- Improves log readability for debugging

---

## 5. Recommended Config Changes (Unified Fragment)

```kconfig
# === CPU Frequency ===
# Switch from performance to schedutil as default
# CONFIG_CPU_FREQ_DEFAULT_GOV_PERFORMANCE is not set
CONFIG_CPU_FREQ_DEFAULT_GOV_SCHEDUTIL=y
CONFIG_CPU_FREQ_GOV_SCHEDUTIL=y

# === WALT Load Tracking ===
CONFIG_SCHED_WALT=y
# WALT sub-features (all useful for this SoC)
CONFIG_SCHED_WALT_DEBUG=n
CONFIG_SCHED_CONSERVATIVE_BOOST_LPM_BIAS=n

# === CPU Idle ===
CONFIG_CPU_IDLE_MULTIPLE_DRIVERS=y
CONFIG_CPU_IDLE_GOV_MENU=y
CONFIG_CPU_IDLE_GOV_TEO=y
CONFIG_ARM_CPUIDLE=y
CONFIG_ARM_PSCI_CPUIDLE=y
CONFIG_ARM_PSCI_CPUIDLE_DOMAIN=y

# === Tick Rate ===
# CONFIG_HZ_PERIODIC is not set
CONFIG_HZ_200=y
CONFIG_NO_HZ_IDLE=y
CONFIG_HZ=200

# === Memory ===
CONFIG_KSM=y
CONFIG_ZRAM_WRITEBACK=y
# CONFIG_USERFAULTFD is not set

# === I/O ===
CONFIG_MQ_DEADLINE=y
CONFIG_F2FS_IOSTAT=y

# === Security ===
CONFIG_STRICT_DEVMEM=y
CONFIG_IO_STRICT_DEVMEM=y

# === Interconnect (ensure modules load) ===
CONFIG_INTERCONNECT_QCOM=y
CONFIG_INTERCONNECT_QCOM_BENGAL=y

# === DCVS ===
CONFIG_QCOM_DCVS=y
```

---

## 6. Apex Governor Improvements (Code-Level)

### 6.1 Fix Dead Code
```c
static unsigned int apex_dbs_update(struct cpufreq_policy *policy)
{
    apex_update(policy);
    return 0;
}
```
Remove the dead rate_mult branch entirely.

### 6.2 Non-Linear Load Mapping
Replace linear mapping with a curve that favors lower frequencies:
```c
static unsigned int apex_load_to_freq(struct cpufreq_policy *policy,
                                      unsigned int load)
{
    unsigned int fmin = policy->min;
    unsigned int fmax = policy->max;
    
    if (load == 0) return fmin;
    if (load >= 100) return fmax;
    
    /* Quadratic mapping: lower frequencies get more load range */
    /* This biases toward staying at lower frequencies longer */
    unsigned int scaled = (load * load) / 100;
    return clamp_t(unsigned int, fmin + ((fmax - fmin) * scaled) / 100,
                   fmin, fmax);
}
```

### 6.3 Iowait Boost
Add iowait boost similar to schedutil:
```c
struct apex_cpu {
    bool iowait_boost_pending;
    unsigned int iowait_boost;
};

static void apex_iowait_boost(struct apex_cpu *cpu, unsigned int *target,
                              unsigned int max)
{
    if (cpu->iowait_boost_pending) {
        cpu->iowait_boost = max(cpu->iowait_boost * 2, IOWAIT_BOOST_MIN);
        *target = max(*target, cpu->iowait_boost);
    } else {
        cpu->iowait_boost >>= 1;
    }
    cpu->iowait_boost_pending = false;
}
```

### 6.4 Per-Cluster Defaults
Use policy->cpu to determine cluster and set different defaults:
```c
static int apex_init(struct dbs_data *dbs_data)
{
    struct apex_tuners *tuners;
    tuners = kzalloc(sizeof(*tuners), GFP_KERNEL);
    if (!tuners) return -ENOMEM;
    
    /* Defaults will be overridden in apex_start per-cluster */
    tuners->screen_off_pct = APEX_DEF_SCREEN_OFF_PCT;
    tuners->burst_threshold = APEX_DEF_BURST_THRESHOLD;
    /* ... */
}
```

### 6.5 LMH Awareness
Read the hardware throttle limit before setting frequency:
```c
static void apex_update(struct cpufreq_policy *policy)
{
    struct qcom_cpufreq_data *data = policy->driver_data;
    unsigned int hw_limit = policy->max;
    
    /* Respect hardware LMH throttle limit */
    if (data && data->dcvsh_freq_limit)
        hw_limit = min(hw_limit, data->dcvsh_freq_limit);
    
    /* Use hw_limit instead of policy->max for target computation */
}
```

---

## 7. Device-Specific Quirks (from ChicKernel)

These are known issues with the SM6225/khaje platform that the apex kernel must address:

1. **Fuel gauge (SM5602)**: Breaks after kernel 5.15.149 merge. Fix: backport from ChicKernel commit 2b14b93963328af3fb023c02c9c8a705a71eb8a7
2. **USB (DWC3-MSM-Core)**: Breaks after 5.15.149 merge. Fix: same commit
3. **USB tethering panic**: Kernel panics on USB tethering. Fix: commit 082c1c5974a03663cf955459aef88da8789b2238
4. **mi_thermald wrong cores**: Thermal daemon shuts down wrong CPU cores. Fix: commit 3e85c4293b4dd4b67e084e3e40ca70a978c1f2c8
5. **KMSG spam**: Vendor modules flood kernel log. Fix: commits 06af5ac8, 3cc1c53a, e6036fdd, 57c46727

All five fixes are already planned in `patches/README.md` but not yet applied.

---

## 8. Summary

The Redmi Note 12 4G / SM6225-AD is a budget SoC with a classic big.LITTLE A73/A53 arrangement. The kernel tree is a CAF bengal-5.15 branch with ChicKernel's customizations (CASS scheduler, ZSTD ZRAM, BFQ, F2FS compression). The apex project adds a custom cpufreq governor and a 4-input state machine for power management.

The highest-impact improvements are:
1. **Stop using `performance` governor as default** — switch to schedutil with WALT for adaptive frequency scaling
2. **Enable WALT** — Qualcomm's window-based load tracking is in the tree but unused; it dramatically improves schedutil's frequency selection quality
3. **Fix CPU idle** — per-cluster idle drivers, PSCI domain support, and MENU governor for better power states
4. **Set HZ=200** — the current default (100) is too coarse for 120 Hz display UI responsiveness
5. **Backport the 5 ChicKernel device fixes** — fuel gauge, USB, thermald, kmsg spam

The apex governor code is a good start but needs: dead code removal, non-linear load mapping, iowait boost, per-cluster tunables, and LMH awareness before it will outperform schedutil+WALT.
