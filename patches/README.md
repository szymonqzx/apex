# Kernel patches

Each subdirectory holds one patch (or a series of patches) for a specific
kernel subsystem.

## Patches

| Directory | Purpose | Status |
| :--- | :--- | :--- |
| `apex-governor/` | Per-cluster CPU governor with non-linear power curve, iowait boost, hysteresis, fast_switch | **Written** |
| `apex-state/` | 4-input+gaming compiled state machine, thermal, GPU devfreq, health tick, incidents | **Written** |
| `apex-watchdog/` | 5-min in-kernel self-heal with 3-strike panic | **Written** |
| `apex-immortal/` | OOM-immortal task whitelist (desk clock, alarm, bridge) | **Written** |
| `apex-autoload/` | USB VID:PID → request_module autoloader | **Written** |
| `apex-baseband-guard/` | BBG efisp exploit mode: ABL/efisp partition whitelisting via cmdline | **Written** |
| `device-backports/` | SM5602 fuel gauge, DWC3 USB, mi-thermald, USB tether panic, kmsg spam | **Written** |

## Apply order

```bash
# Apply all apex patches
for d in patches/apex-*; do
    [ -f "$d/apply.sh" ] && bash "$d/apply.sh" ./kernel
done

# Apply device backports
bash patches/device-backports/apply.sh ./kernel
```

## Architecture

```
apex-governor (drivers/cpufreq/cpufreq_apex.c)
  ├── non-linear power curve (quadratic, tunable exponent)
  ├── iowait boost (UFS app launch latency)
  ├── hysteresis (prevent freq oscillation)
  ├── fast_switch (EPSS sub-μs transitions)
  ├── per-cluster auto-tuning (A73 aggressive, A53 conservative)
  ├── screen-off ceiling (screen_off_pct)
  ├── burst passthrough (burst_threshold)
  └── gaming mode override

apex-state (drivers/apex/apex.c)
  ├── 5-input decision table (screen, charging, audio, fg-uid, gaming)
  ├── /proc/apex/* procfs surface
  ├── thermal zone monitoring (auto-throttle at 45/55/65°C)
  ├── GPU devfreq integration
  ├── power_supply notifier (auto-detect charging)
  ├── RTC wakealarm mirror
  ├── 5-min health tick
  ├── 7-day routine learner (framework)
  ├── panic incident ring
  └── propagates screen/gaming state to governor

apex-watchdog (drivers/apex/apex_watchdog.c)
  ├── 5-min periodic delayed_work
  ├── CPU online mask check + cpu_up() recovery
  ├── GPU device presence check
  ├── thermal zone critical check
  ├── ZRAM block device check
  ├── battery power_supply check
  ├── 3-strike → panic
  └── /proc/apex/watchdog status

apex-immortal (drivers/apex/apex_immortal.c)
  ├── apex_oom_immortal() called by mm/oom_kill.c
  ├── built-in whitelist (deskclock, poweroffalarm, apex-bridge, alarmkeeper)
  ├── runtime sysctl additions (kernel.apex_oom_whitelist)
  └── patches mm/oom_kill.c via apply.sh

apex-autoload (drivers/usb/core/apex_autoload.c)
  ├── VID:PID → request_module() for pentest drivers
  ├── Wi-Fi monitor mode adapters (8812au, ath9k_htc, etc.)
  ├── SDR (RTL-SDR)
  └── zero idle drain (modules load only on hardware attach)

device-backports/
  ├── sm5602-fuelgauge.patch — IRQ probe fix for 5.15.149+
  ├── dwc3-msm-core.patch — PHY binding order fix for 5.15.149+
  ├── mi-thermald-wrong-core.patch — correct cluster shutdown order
  ├── usb-tether-panic.patch — completion wait before endpoint cleanup
  └── kmsg-spam-suppress.patch — reduce vendor module log noise

apex-baseband-guard/
  ├── bbg-kconfig-recovery.patch — add CONFIG_BBG_BLOCK_RECOVERY option
  ├── bbg-efisp-exploit.patch — efisp exploit allowlist + oplusboot.secure_user_mode cmdline
  ├── anykernel-bbg-efisp-menu.patch — volume-key menu in AnyKernel3 installer
  └── apply.sh — idempotent patch applier (BBG submodule + anykernel3)
```
