/*
 * DesktopModeService.java
 *
 * Manages APEX Desktop Mode: scrcpy-based desktop experience.
 *
 * Architecture:
 *   1. User triggers desktop mode via Apex Control or agent MCP tool
 *   2. This service starts scrcpy-server on the device
 *   3. A scrcpy client on a connected PC (USB or TCP) renders the display
 *   4. APEX WM switches to desktop layout (title bars, taskbar)
 *   5. Keyboard/mouse input from scrcpy client controls the phone
 *
 * USB-C is USB 2.0 only on topaz — no wired display output.
 * scrcpy uses ADB transport (USB) or TCP for display mirroring.
 *
 * The scrcpy server jar is pre-installed at /system/bin/scrcpy-server.jar
 * and launched via app_process.
 */

package com.apex.desktop;

import android.content.Context;
import android.os.Binder;
import android.os.IBinder;
import android.os.ServiceManager;
import android.util.Log;

import org.json.JSONObject;

import java.io.BufferedReader;
import java.io.IOException;
import java.io.InputStreamReader;

public class DesktopModeService {
  private static final String TAG = "DesktopModeService";
  private static final String SERVICE_NAME = "apex_desktop";
  private static final String SCRCPY_SERVER_PATH = "/system/bin/scrcpy-server.jar";
  private static final int SCRCPY_PORT = 27183; // default scrcpy port

  private final Context mContext;
  private Process mScrcpyProcess;
  private boolean mDesktopActive = false;
  private String mConnectionInfo = "disconnected";

  public DesktopModeService(Context context) {
    mContext = context;
    Log.i(TAG, "DesktopModeService initialized");
  }

  // ── Binder interface ────────────────────────────────────────────

  private final IDesktopMode.Stub mBinder = new IDesktopMode.Stub() {
    @Override
    public String startDesktop() {
      return startDesktopMode();
    }

    @Override
    public String stopDesktop() {
      return stopDesktopMode();
    }

    @Override
    public String getStatus() {
      try {
        JSONObject status = new JSONObject();
        status.put("active", mDesktopActive);
        status.put("connection", mConnectionInfo);
        status.put("scrcpyPath", SCRCPY_SERVER_PATH);
        status.put("port", SCRCPY_PORT);
        return status.toString();
      } catch (Exception e) {
        return "{\"error\":\"" + e.getMessage() + "\"}";
      }
    }

    @Override
    public boolean isRunning() {
      return mDesktopActive;
    }
  };

  // ── Desktop mode lifecycle ──────────────────────────────────────

  private String startDesktopMode() {
    if (mDesktopActive) {
      return "{\"status\":\"ok\",\"message\":\"already running\",\"connection\":\""
          + mConnectionInfo + "\"}";
    }

    try {
      // Launch scrcpy server via app_process
      ProcessBuilder pb = new ProcessBuilder(
          "app_process",
          "/",
          "com.genymobile.scrcpy.Server",
          "tunnel_forward=true",
          "port=" + SCRCPY_PORT,
          "max_size=1920",
          "max_fps=60",
          "video_bit_rate=8000000",
          "audio=true",
          "video=true"
      );
      pb.redirectErrorStream(true);
      mScrcpyProcess = pb.start();

      // Read initial output for connection info
      BufferedReader reader = new BufferedReader(
          new InputStreamReader(mScrcpyProcess.getInputStream()));
      String firstLine = reader.readLine();
      if (firstLine != null) {
        mConnectionInfo = "scrcpy:" + firstLine.trim();
      } else {
        mConnectionInfo = "scrcpy:listening on port " + SCRCPY_PORT;
      }

      mDesktopActive = true;
      Log.i(TAG, "Desktop mode started: " + mConnectionInfo);

      // Notify WM to switch to desktop layout
      notifyWmDesktopLayout(true);

      return "{\"status\":\"ok\",\"message\":\"desktop mode started\",\"connection\":\""
          + mConnectionInfo + "\",\"port\":" + SCRCPY_PORT + "}";
    } catch (IOException e) {
      Log.e(TAG, "Failed to start scrcpy: " + e.getMessage());
      mDesktopActive = false;
      mConnectionInfo = "error: " + e.getMessage();
      return "{\"error\":\"failed to start scrcpy: " + e.getMessage() + "\"}";
    }
  }

  private String stopDesktopMode() {
    if (!mDesktopActive) {
      return "{\"status\":\"ok\",\"message\":\"not running\"}";
    }

    // Kill scrcpy process
    if (mScrcpyProcess != null) {
      mScrcpyProcess.destroy();
      mScrcpyProcess = null;
    }

    mDesktopActive = false;
    mConnectionInfo = "disconnected";
    Log.i(TAG, "Desktop mode stopped");

    // Notify WM to revert desktop layout
    notifyWmDesktopLayout(false);

    return "{\"status\":\"ok\",\"message\":\"desktop mode stopped\"}";
  }

  private void notifyWmDesktopLayout(boolean enabled) {
    // Call ApexWindowManager.setDesktopLayout(enabled) via binder
    IBinder wmBinder = ServiceManager.getService("apex_wm");
    if (wmBinder != null) {
      try {
        // In the full implementation, this would call:
        // IApexWindowManager.Stub.asInterface(wmBinder).setDesktopLayout(enabled);
        Log.i(TAG, "Notified WM: desktop layout=" + enabled);
      } catch (Exception e) {
        Log.w(TAG, "Failed to notify WM: " + e.getMessage());
      }
    }
  }

  // ── Service registration ────────────────────────────────────────

  public void publish() {
    ServiceManager.addService(SERVICE_NAME, mBinder);
    Log.i(TAG, "Published as '" + SERVICE_NAME + "'");
  }

  public IBinder getBinder() {
    return mBinder;
  }
}
