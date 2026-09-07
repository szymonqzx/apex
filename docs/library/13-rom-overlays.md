# 13 — ROM Overlays

## Overview

APEX ROM modifies the Android system via dirty overlays applied by the KernelSU-Next module. No system partition is modified — all changes are applied as overlay files in the KSU module's `system/` directory, which KSU mounts over the real `/system` at boot. This means all changes are reversible by removing the KSU module.

## Overlay Structure

```
ksu-module/system/
├── build.prop.append          # PIF fingerprint spoofing + APEX properties
├── vendor.build.prop.append   # Vendor build.prop overlay
├── etc/
│   ├── init/                  # 17 init RC files
│   │   ├── apex_agent.rc
│   │   ├── apex_alarm.rc
│   │   ├── apex_desktop.rc
│   │   ├── apex_game_space.rc
│   │   ├── apex_gestures.rc
│   │   ├── apex_kernel_detect.rc
│   │   ├── apex_lindroid.rc
│   │   ├── apex_modules.rc
│   │   ├── apex_notifications.rc
│   │   ├── apex_pocket.rc
│   │   ├── apex_power.rc
│   │   ├── apex_power_user.rc
│   │   ├── apex_profiles.rc
│   │   ├── apex_reboot.rc
│   │   ├── apex_remote_proxy.rc
│   │   ├── apex_smart_charging.rc
│   │   ├── apex_tuning.rc
│   │   └── apex_wm.rc
│   └── thermald.conf          # Reference documentation (not consumed)
├── hidden_packages.list       # HMA-OSS package blacklist
├── bin/                       # Shell scripts
│   ├── apex_ab_verify.sh
│   ├── apex_agent_healthcheck.sh
│   ├── apex_kernel_detect.sh
│   ├── apex_ota_fallback.sh
│   ├── apex_pocket_detect.sh
│   ├── apex_screenshot_gesture.sh
│   ├── apex_smart_charge.sh
│   └── apex_tuning.sh
├── app/                       # Regular apps
│   ├── NFCForge/NFCForge.apk
│   └── PTKTUI/PTKTUI.apk
├── priv-app/                  # Privileged apps
│   ├── ApexControl/ApexControl.apk
│   └── ApexSystemServices/ApexSystemServices.apk
└── (vendor overlays via apex_power.rc etc.)
```

## build.prop Overlay

### PIF (Play Integrity Fix)
```
ro.build.fingerprint=xiaomi/tapas_global/tapas:13/TKQ1.221114.001/V816.0.7.0.UMGMIXM:user/release-keys
ro.build.type=user
ro.debuggable=0
ro.secure=1
ro.build.keys=release-keys
ro.boot.veritymode=enforcing
ro.boot.verifiedbootstate=yellow
```

### APEX Internal
```
ro.apex.hide=1
ro.apex.version=1.3.0
ro.apex.rom_base=lineage-23.2
```

### Feature Flags (persisted user settings override these defaults)
```
ro.apex.game_space=0
ro.apex.pocket_detect=0
ro.apex.smart_charge=0
ro.apex.screenshot_gesture=0
ro.apex.dt2w=0
ro.apex.tts=0
```

## Init RC Files

### apex_agent.rc
Starts the apexagentd daemon as a core system service. Configures OOM adjustment (900 = killable under pressure), SELinux domain (apex_agent), and restart behavior.

### apex_alarm.rc
APEX AlarmKeeper — mirrors RTC_WAKEUP alarms to `/proc/apex/wakealarm` so the kernel can program the PMIC RTC even when the SoC is off.

### apex_desktop.rc
Sets properties for scrcpy configuration. DesktopModeService runs inside system_server, so no separate service is needed.

### apex_game_space.rc
Game Space: enhanced gaming mode with:
- FPS unlock
- Sensor block (disables accelerometer/gyroscope for games that don't need them)
- Notification suppression (auto-DND)
- Immersive mode (hides navigation bar, status bar)
- Triggered by `setprop apex.game_space 1`

### apex_gestures.rc
Gesture controls:
- Tap-to-sleep (double-tap status bar)
- Double-tap-to-wake (DT2W)
- Three-finger screenshot
- Uses kernel gesture sysfs nodes (`apex_gestures` class)
- Input event monitoring for screenshot gesture

### apex_kernel_detect.rc
Init script for APEX kernel detection at boot. Sets properties that Apex Control reads to display a badge/notice. The ROM **warns** (never blocks boot) when not running the APEX kernel.

### apex_lindroid.rc
Init script for Lindroid container manager. Sets properties and provides a property-based trigger for container start/stop.

### apex_modules.rc
One-time KSU module installer for the hiding stack. Runs after `sys.boot_completed=1` + KSU initialization. Installs Zygisk-Next, Shamiko, HMA-OSS, TrickyStore from `/system/apex/modules/*.zip`. Only runs once (sentinel file at `/data/adb/apex_modules_installed`).

### apex_notifications.rc
Notification customization:
- Heads-up timeout adjustment
- Notification priority tuning
- DND auto-toggle for gaming/media
- Inspired by crDroid notification settings

### apex_pocket.rc
Pocket detection using proximity sensor:
- Detects when phone is in pocket
- Suppresses accidental touches
- Prevents screen wake from notifications
- Inspired by crDroid pocket detection

### apex_power.rc
Wires screen state, gaming mode, and hardening to the kernel apex state machine:
- Screen on/off → writes to `/sys/class/apex/policy`
- Gaming mode → `setprop apex.gaming 1` → kernel policy
- BT scan suppression via cgroup freezer
- Wi-Fi multicast lockdown (`cmd wifi set-wifi-multicast-enabled false`)

### apex_power_user.rc
Miscellaneous power-user features:
- Sensor block per-app
- Pocket detection integration
- USB config toggle (charging/file transfer/MIDI/PTP)
- App downgrade allowance
- Developer quick-toggles

### apex_profiles.rc
Profile switching for the APEX kernel:
- `setprop apex.profile battery` → conservative frequencies, max battery life
- `setprop apex.profile balanced` → default, good balance
- `setprop apex.profile performance` → max frequencies, max performance

### apex_reboot.rc
Advanced reboot options:
- Recovery: `setprop apex.reboot recovery`
- Bootloader: `setprop apex.reboot bootloader`
- Soft reboot: `setprop apex.reboot soft` (restarts system_server)
- Restart SystemUI: `setprop apex.reboot systemui`

### apex_remote_proxy.rc
Init service for the remote model proxy. Runs as a separate process from apexagentd, in its own SELinux domain (`apex_remote_proxy`). Listens on localhost:9879.

### apex_smart_charging.rc
Smart charging schedule: time-based charge limit to preserve battery health. User configures charging window (e.g., charge to 80% by 6am). The script uses `apex_smart_charge.sh` to manage charge thresholds.

### apex_tuning.rc
Runtime kernel parameter tuning. Applies sysctl and sysfs settings for performance/power balance. Calls `apex_tuning.sh` which writes to `/proc/sys/` and `/sys/class/apex/`.

### apex_wm.rc
Init script for APEX Window Manager. Sets properties for freeform window management. ApexWindowManager runs inside system_server, so no separate service is needed.

## Shell Scripts

### apex_agent_healthcheck.sh
Monitors apexagentd and restarts with circuit breaker:
- Checks daemon liveness every 60s
- If dead, restarts
- Circuit breaker: max 5 restarts per 10-minute window
- If circuit breaker trips, daemon stays down and logs an incident

### apex_tuning.sh
Runtime kernel parameters:
- Sets CPU governor parameters
- Configures ZRAM
- Adjusts kernel scheduler settings
- Applies sysctl tuning

### apex_kernel_detect.sh
Kernel detection script:
- Checks `/proc/version` for APEX kernel string
- Sets `ro.apex.kernel_detected=1` or `0`
- If not APEX kernel, sets warning property (never blocks boot)

### apex_pocket_detect.sh
Pocket detection implementation:
- Reads proximity sensor via sysfs
- When proximity = near, sets `apex.pocket=1`
- Suppresses touch events and notification wake

### apex_screenshot_gesture.sh
Three-finger screenshot:
- Monitors input events for three-finger swipe
- On detection, triggers `screencap` and saves to `/sdcard/Screenshots/`

### apex_smart_charge.sh
Smart charging schedule:
- Reads user-configured charging window from properties
- Manages `charge_control_limit_max` based on time of day
- Example: charge to 80% overnight, unlimited during day

### apex_ab_verify.sh
Virtual A/B verification:
- Checks current slot (A or B)
- Verifies slot is marked bootable
- Used by OTA update flow

### apex_ota_fallback.sh
OTA fallback:
- If OTA update fails, rolls back to previous slot
- Marks current slot as unsuccessful
- Reboots to previous slot

## Hidden Packages

`hidden_packages.list` (consumed by HMA-OSS):
```
com.topjohnwu.magisk
me.bmax.apatch
org.lsposed.manager
com.solohsu.android.edxp.manager
```

These are root management apps that should be hidden from package scanners. The full denylist (30+ packages) is in `hiding/denylist.conf`.

## Thermald Configuration

`thermald.conf` is **reference documentation only** — not consumed by any daemon. APEX has no userspace thermald. All thermal policy is enforced in-kernel. The file documents trip points for human reference.

The original `mi_thermald` is disabled by the ROM overlay because the kernel modules handle all thermal policy with lower latency and more granular control.
