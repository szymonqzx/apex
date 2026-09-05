// IDesktopMode.aidl — Binder interface for APEX Desktop Mode
package com.apex.desktop;

/** @hide */
interface IDesktopMode {
    /** Start desktop mode (launch scrcpy server) */
    String startDesktop();

    /** Stop desktop mode (kill scrcpy server) */
    String stopDesktop();

    /** Get current desktop mode status as JSON */
    String getStatus();

    /** Check if desktop mode is running */
    boolean isRunning();
}
