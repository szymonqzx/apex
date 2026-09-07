# 08 — Window Manager

## Overview

APEX WM is a freeform window manager for phone form factor. It enables desktop-like window management on the Redmi Note 12 4G's 6.5" display, allowing multiple apps in resizable, movable windows. It runs inside system_server and uses Android's TaskOrganizer and TaskDisplayArea APIs — no SurfaceFlinger modifications.

## Architecture

```
1. Framework overlay (ApexWmOverlay.apk) enables config_freeformWindowManagement=true
2. ApexWindowManager uses TaskOrganizer to create/manage freeform tasks
3. Windows are positioned via TaskOrganizer.setTaskBounds()
4. Tiling mode calculates positions and applies them
5. Desktop mode adds title bars + taskbar (via SurfaceControl)
```

## Components

### ApexWindowManager.java (349 lines)
System service running in system_server. Binder service name: `apex_wm`.

### IApexWindowManager.aidl (70 lines)
Binder interface:
```java
interface IApexWindowManager {
    String listWindows();
    String focusWindow(String windowId);
    String moveWindow(String windowId, int x, int y);
    String resizeWindow(String windowId, int width, int height);
    String minimizeWindow(String windowId);
    String closeWindow(String windowId);
    String toggleTilingMode();
    String setDesktopLayout(boolean enabled);
    String getMode();
}
```

### ApexWindowInfo.aidl (15 lines)
Parcelable containing: windowId, packageName, title, x, y, width, height, zOrder, minimized, focused.

### Framework Overlay
- `wm/overlay/res/values/config.xml` — sets `config_freeformWindowManagement=true`
- `wm/overlay/res/xml/overlay_map.xml` — maps overlay to framework package
- `wm/overlay/AndroidManifest.xml` — overlay package declaration
- `wm/overlay/Android.bp` — build blueprint

## Window Data Model

```java
class ApexWindow {
    String windowId;     // "win-" + taskId
    String packageName;
    String title;
    int x, y;            // position
    int width, height;   // dimensions
    int zOrder;          // stacking order
    boolean minimized;
    boolean focused;
    int taskId;          // Android task ID
}
```

## Modes

### Freeform Mode
- Windows are freely positioned and resized
- User can drag windows by title bar
- Multiple windows visible simultaneously
- Z-order managed by focus

### Tiling Mode
- Windows are automatically positioned in a grid
- No overlapping — each window gets a portion of the screen
- Useful for side-by-side app usage on phone display
- `toggleTilingMode()` switches between freeform and tiled

### Desktop Layout
- Enabled when Desktop Mode (scrcpy) is active
- Adds title bars and taskbar via SurfaceControl
- Designed for mouse/keyboard input from PC client
- Windows are larger (desktop resolution)

## Security

- Only system_server and Apex Control (system app) can call
- Agent daemon calls via binder with system UID
- No user-installed apps can access this service
- Runs in system_server context (no separate SELinux domain needed — system_server already has TaskOrganizer permissions)

### SELinux Policy (apex_wm.te)
```te
# ApexWindowManager runs inside system_server (no separate domain).
# It uses TaskOrganizer and ActivityTaskManager APIs which are
# already available to system_server.

# Allow system_app to set freeform window management properties
allow system_app freeform_window_prop:property_service { set };
```

## Agent Integration

The agent can control windows via MCP tools:
- `apex-wm-list` — list all freeform windows (read-only, no consent)
- `apex-wm-focus` — focus a specific window (consent required)

This allows voice commands like "switch to my browser window" to work through the agent.

## Limitations

- Cannot modify SurfaceFlinger — uses framework-level APIs only
- Title bars and taskbar in desktop mode are SurfaceControl overlays, not native window decorations
- No window snapping (half-screen, quarter-screen) — planned but not implemented
- No multi-monitor support — single display only
- USB-C is USB 2.0 only on topaz — no wired display output, so desktop mode requires scrcpy over USB/TCP
