// IApexWindowManager.aidl
//
// Binder interface for the APEX Window Manager service.
// Manages freeform windows on phone form factor.
//
// Runs in system_server. The agent daemon and Apex Control app
// call these methods via binder.

package com.apex.wm;

import com.apex.wm.ApexWindowInfo;

/** @hide */
interface IApexWindowManager {

    // ── Window enumeration ───────────────────────────────────────

    /** Returns a list of all freeform windows as JSON */
    String listWindows();

    /** Get info for a specific window by ID */
    String getWindowInfo(String windowId);

    // ── Window operations ────────────────────────────────────────

    /** Focus (bring to front) a window by ID */
    boolean focusWindow(String windowId);

    /** Close a window by ID */
    boolean closeWindow(String windowId);

    /** Move a window to a new position */
    boolean moveWindow(String windowId, int x, int y);

    /** Resize a window */
    boolean resizeWindow(String windowId, int width, int height);

    /** Minimize a window */
    boolean minimizeWindow(String windowId);

    /** Restore a minimized window */
    boolean restoreWindow(String windowId);

    // ── Tiling mode ──────────────────────────────────────────────

    /** Enable/disable tiling mode */
    boolean setTilingMode(boolean enabled);

    /** Tile all windows in a grid layout */
    boolean tileGrid();

    /** Tile two windows side by side */
    boolean tileSplit(String windowId1, String windowId2);

    // ── Desktop mode ─────────────────────────────────────────────

    /** Switch to desktop layout (title bars, taskbar) */
    boolean setDesktopLayout(boolean enabled);

    // ── Status ───────────────────────────────────────────────────

    /** Check if WM is active */
    boolean isWmActive();

    /** Check if freeform mode is enabled */
    boolean isFreeformEnabled();

    /** Enable freeform mode (requires framework overlay) */
    boolean enableFreeform();
}
