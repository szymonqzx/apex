# 11 — Chroot Bridge

## Overview

`apex-bridge` is a userspace C daemon that bridges the Android framework to the APEX kernel state machine. It listens on a Unix domain socket at `/dev/socket/apex-bridge`, accepts commands from privileged clients (Apex Control, system services), and translates them into sysfs writes to `/sys/class/apex/`. It also monitors hardware state (display, charging, battery, thermal) and feeds it to the kernel.

## Source

- **File**: `chroot/bridge/apex-bridge.c`
- **Lines**: 980
- **Language**: C
- **Build**: `cc -o apex-bridge apex-bridge.c -lpthread`
- **Runtime**: as root via init.rc

## Socket Protocol

Unix domain socket at `/dev/socket/apex-bridge`, restricted to root-only (0600). Client UID verified via `SO_PEERCRED`.

### Commands (newline-terminated text)

| Command | Action | Target |
|---------|--------|--------|
| `screen_on` | Write `screen_on` to policy | `/sys/class/apex/policy` |
| `screen_off` | Write `screen_off` to policy | `/sys/class/apex/policy` |
| `game 0\|1` | Write game state to policy | `/sys/class/apex/policy` |
| `charge 0\|1` | Write charge state to policy | `/sys/class/apex/policy` |
| `audio 0\|1` | Write audio state to policy | `/sys/class/apex/policy` |
| `status` | Read current state | `/sys/class/apex/state` |
| `version` | Read APEX version | `/sys/class/apex/version` |
| `governor` | Read governor info | `/sys/class/apex/governor` |
| `watchdog` | Read watchdog status | `/sys/class/apex/watchdog` |
| `health` | Read health summary | `/sys/class/apex/health` |
| `thermal_profile` | Read thermal profile | `/sys/class/apex/thermal_profile` |
| `modules` | Read loaded modules | `/sys/class/apex/modules` |

### Constants
- `MAX_CLIENTS`: 16
- `BUF_SIZE`: 8192
- `SOCK_BUF_SIZE`: 16384
- `BATTERY_LOW_PCT`: 15
- `BATTERY_HIGH_PCT`: 80
- `THERMAL_WARN_MC`: 55000 (55°C)
- `THERMAL_CRIT_MC`: 65000 (65°C)

## Hardware Monitoring

The daemon continuously monitors:

### Display State
- Reads backlight brightness from sysfs
- Detects screen on/off transitions
- Sends `screen_on` / `screen_off` to kernel policy

### Charging State
- Reads `power_supply` status (charging/discharging/full)
- Reads battery capacity percentage
- Sends `charge 0|1` to kernel policy
- Low battery warning at 15%
- High battery notification at 80%

### Thermal Zones
- Reads thermal zone temperatures in millidegrees
- Warning at 55°C (THERMAL_WARN_MC)
- Critical at 65°C (THERMAL_CRIT_MC)
- Logs incidents on critical threshold

## Incident Logging

The daemon logs incidents to the Android log and optionally to the kernel incident ring buffer via `/sys/class/apex/policy`. The kernel's `/sys/class/apex/incidents` is read-only (0444), so the daemon uses the policy write interface to signal incidents.

Incident types:
- Thermal critical threshold exceeded
- Battery low warning
- Charging state anomalies
- Watchdog health check failures
- NFC/IR hardware access errors

## NFC and IR Hardware Access

The bridge provides access to NFC and IR hardware from the chroot environment:

### NFC (ST21NFC)
- Opens `/dev/st21nfc` for raw frame access
- Currently a stub: opens device, logs, but does not write frames
- Planned: full APDU passthrough for NFCForge

### IR (LIRC)
- Opens `/dev/lirc0` for raw IR frame access
- Currently a stub: opens device, logs, but does not write frames
- Planned: full IR transceiver support

## SELinux Domain

The bridge runs in the `apex_chroot` SELinux domain:

```te
type apex_chroot, domain;
type apex_chroot_exec, file_type, exec_type;

init_daemon_domain(apex_chroot)

# Binder communication with system_server
binder_call(apex_chroot, system_server)
binder_call(system_server, apex_chroot)

# Hardware device node access
allow apex_chroot apex_chroot:chr_file { read write open ioctl getattr };

# Battery/charge status reads
allow apex_chroot apex_charge_proc:file { read open getattr };
allow apex_chroot apex_charge_proc:dir { search read };
```

## Boot

Started by `apex_agent.rc` (or a dedicated init script):
```
service apex-bridge /system/bin/apex-bridge
    class core
    user root
    group root
    seclabel u:r:apex_chroot:s0
    onrestart
```

The socket is created with permissions 0600 (root-only). The daemon verifies client UID via `SO_PEERCRED` on every connection.

## Thread Model

- **Main thread**: accepts connections, spawns worker threads
- **Monitor thread**: polls hardware state every 2 seconds
- **Worker threads**: one per client connection (up to 16)

The daemon uses `pthread` for threading. The `running` flag is `sig_atomic_t` for clean signal handling (SIGTERM/SIGINT set `running = 0`).
