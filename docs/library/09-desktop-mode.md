# 09 — Desktop Mode

## Overview

APEX Desktop Mode turns the phone into a desktop computer by mirroring the display to a PC via scrcpy and switching the window manager to desktop layout. The phone's USB-C port is USB 2.0 only (no DisplayPort alt mode), so display output is handled by scrcpy over ADB transport (USB) or TCP.

## Architecture

```
1. User triggers desktop mode via Apex Control or agent MCP tool
2. DesktopModeService starts scrcpy-server on the device via app_process
3. A scrcpy client on a connected PC (USB or TCP) renders the display
4. APEX WM switches to desktop layout (title bars, taskbar)
5. Keyboard/mouse input from scrcpy client controls the phone
```

## DesktopModeService (179 lines)

System service running in system_server. Binder service name: `apex_desktop`.

### IDesktopMode.aidl (17 lines)
```java
interface IDesktopMode {
    String startDesktop();
    String stopDesktop();
    String getStatus();
    boolean isRunning();
}
```

### scrcpy Server Launch
```java
ProcessBuilder pb = new ProcessBuilder(
    "app_process",
    "/",
    "com.genymobile.scrcpy.Server",
    "tunnel_forward=true",
    "port=27183",
    "max_size=1920",
    "max_fps=60",
    "bitrate=8000000",
    "video_codec=h264",
    "audio=true"
);
```

### Configuration
- **Server path**: `/system/bin/scrcpy-server.jar`
- **Port**: 27183 (default scrcpy port)
- **Max resolution**: 1920px
- **Max FPS**: 60
- **Bitrate**: 8 Mbps
- **Video codec**: H.264
- **Audio**: enabled

### Connection Modes
- **USB**: scrcpy client on PC connects via ADB tunnel forward
- **TCP**: scrcpy client connects over network (useful with Tailscale)

### Status Reporting
```json
{
  "active": true,
  "connection": "usb tunnel forward :27183",
  "scrcpyPath": "/system/bin/scrcpy-server.jar",
  "port": 27183
}
```

## Integration with APEX WM

When desktop mode starts:
1. DesktopModeService calls `ApexWindowManager.setDesktopLayout(true)`
2. WM switches to desktop layout: title bars appear, taskbar shows at bottom
3. Windows resize to desktop-appropriate sizes
4. Input events from scrcpy (mouse/keyboard) are routed to the focused window

When desktop mode stops:
1. DesktopModeService kills scrcpy-server process
2. WM reverts to phone layout: title bars hidden, windows return to phone-sized
3. Normal touch input resumes

## Agent Integration

The agent can control desktop mode via MCP tools:
- `apex-desktop-start` — start desktop mode (consent required)
- `apex-desktop-stop` — stop desktop mode (consent required)

This enables voice commands like "start desktop mode" or "connect to my PC".

## SELinux Policy (apex_desktop.te)

```te
# DesktopModeService runs inside system_server (like WM).
# It launches scrcpy-server via app_process.
#
# scrcpy-server needs:
#   - Network socket (TCP for tunnel forwarding)
#   - Access to /system/bin/scrcpy-server.jar
#   - app_process execution
#   - SurfaceFlinger access (screen capture)
#   - AudioFlinger access (audio capture)

# system_server already has surfaceflinger and audio access.
```

## Prerequisites

- scrcpy-server.jar must be pre-installed at `/system/bin/scrcpy-server.jar`
- scrcpy client must be installed on the PC (USB mode) or accessible via network (TCP mode)
- ADB debugging must be enabled (USB mode) or network ADB configured (TCP mode)
- APEX WM must be active (framework overlay installed)

## Not Yet Implemented

- scrcpy-server.jar is not packaged in the KSU module — needs to be built from source and added
- No `build-scrcpy-server.sh` build script exists yet
- No automatic detection of PC connection (user must manually trigger)
- No clipboard sharing between phone and PC (scrcpy supports this but not wired in APEX UI)
