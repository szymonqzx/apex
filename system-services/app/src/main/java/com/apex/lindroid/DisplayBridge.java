/*
 * DisplayBridge.java
 *
 * Display forwarding bridge between the Lindroid Linux container
 * and Android's SurfaceFlinger.
 *
 * Two modes:
 *   1. X11 forwarding: Container X11 apps → Termux:X11 server → Android
 *   2. Wayland proxy: Container Wayland apps → Wayland proxy → SurfaceFlinger
 *
 * X11 mode is the proven approach (Termux:X11 already works on this device).
 * Wayland mode is aspirational — would need a custom Wayland compositor
 * that bridges to SurfaceFlinger via SurfaceControl.
 *
 * Window integration:
 *   Linux app windows appear as freeform windows in APEX WM.
 *   Each X11 top-level window gets mapped to an Android TaskDisplayArea.
 */

package com.apex.lindroid;

import android.util.Log;

import org.json.JSONObject;

import java.io.BufferedReader;
import java.io.InputStreamReader;

public class DisplayBridge {
  private static final String TAG = "DisplayBridge";

  private final ContainerConfig mConfig;
  private String mMode;
  private boolean mRunning = false;
  private Process mBridgeProcess;

  // X11 server socket path (Termux:X11)
  private static final String X11_SOCKET = "/tmp/.X11-unix/X0";

  // Wayland socket path
  private static final String WAYLAND_SOCKET = "/tmp/wayland-0";

  public DisplayBridge(ContainerConfig config) {
    mConfig = config;
    mMode = config.getDisplayMode();
    Log.i(TAG, "DisplayBridge initialized: mode=" + mMode);
  }

  /**
   * Start the display bridge.
   * For X11: ensures Termux:X11 server is running and socket is accessible.
   * For Wayland: starts the Wayland proxy compositor.
   */
  public String start() {
    if (mRunning) {
      return "{\"status\":\"ok\",\"message\":\"already running\"}";
    }

    try {
      if ("x11".equals(mMode)) {
        return startX11Bridge();
      } else if ("wayland".equals(mMode)) {
        return startWaylandBridge();
      } else {
        return "{\"error\":\"unknown display mode: " + mMode + "\"}";
      }
    } catch (Exception e) {
      Log.e(TAG, "Start failed: " + e.getMessage());
      return "{\"error\":\"" + e.getMessage() + "\"}";
    }
  }

  /**
   * Stop the display bridge.
   */
  public String stop() {
    if (!mRunning) {
      return "{\"status\":\"ok\",\"message\":\"not running\"}";
    }

    try {
      if (mBridgeProcess != null) {
        mBridgeProcess.destroy();
        mBridgeProcess.waitFor();
      }
      mRunning = false;
      Log.i(TAG, "Display bridge stopped");
      return "{\"status\":\"ok\",\"message\":\"bridge stopped\"}";
    } catch (Exception e) {
      return "{\"error\":\"" + e.getMessage() + "\"}";
    }
  }

  /**
   * Get the display bridge status.
   */
  public String getStatus() {
    try {
      JSONObject status = new JSONObject();
      status.put("running", mRunning);
      status.put("mode", mMode);
      status.put("resolution", mConfig.getDisplayWidth() + "x" + mConfig.getDisplayHeight());
      if ("x11".equals(mMode)) {
        status.put("socket", X11_SOCKET);
      } else {
        status.put("socket", WAYLAND_SOCKET);
      }
      return status.toString();
    } catch (Exception e) {
      return "{\"error\":\"" + e.getMessage() + "\"}";
    }
  }

  /**
   * Launch a GUI application in the container with display forwarding.
   * Sets DISPLAY/WAYLAND_DISPLAY env vars and executes the app.
   */
  public String launchApp(String appName) {
    if (!mRunning) {
      return "{\"error\":\"display bridge not running\"}";
    }

    try {
      String[] env = mConfig.buildDisplayEnv();
      StringBuilder envCmd = new StringBuilder();
      for (String e : env) {
        envCmd.append("export ").append(e).append("; ");
      }

      ProcessBuilder pb = new ProcessBuilder("sh", "-c",
          envCmd.toString() + appName + " &");
      pb.redirectErrorStream(true);
      Process p = pb.start();

      BufferedReader reader = new BufferedReader(
          new InputStreamReader(p.getInputStream()));
      String output = reader.readLine();
      Log.i(TAG, "Launched app: " + appName);

      return "{\"status\":\"ok\",\"app\":\"" + appName
          + "\",\"display\":\"" + mMode + "\"}";
    } catch (Exception e) {
      return "{\"error\":\"" + e.getMessage() + "\"}";
    }
  }

  /**
   * List visible windows from the display bridge.
   * For X11: uses xwininfo to list top-level windows.
   * These can be mapped to APEX WM freeform windows.
   */
  public String listWindows() {
    if (!mRunning) {
      return "{\"status\":\"ok\",\"windows\":[]}";
    }

    try {
      ProcessBuilder pb = new ProcessBuilder("sh", "-c",
          "DISPLAY=:0 xwininfo -tree -root 2>/dev/null | grep '0x' | head -20");
      pb.redirectErrorStream(true);
      Process p = pb.start();

      BufferedReader reader = new BufferedReader(
          new InputStreamReader(p.getInputStream()));
      StringBuilder sb = new StringBuilder();
      String line;
      while ((line = reader.readLine()) != null) {
        sb.append(line).append("\n");
      }

      return "{\"status\":\"ok\",\"windows\":\""
          + sb.toString().trim() + "\"}";
    } catch (Exception e) {
      return "{\"error\":\"" + e.getMessage() + "\"}";
    }
  }

  // ── Private methods ──────────────────────────────────────────────

  private String startX11Bridge() {
    try {
      // Check if Termux:X11 socket exists
      ProcessBuilder pb = new ProcessBuilder("sh", "-c",
          "ls -la " + X11_SOCKET + " 2>/dev/null && echo 'X11 socket exists' "
              + "|| (termux-x11 :0 &>/dev/null & sleep 2 && echo 'X11 server started')");
      pb.redirectErrorStream(true);
      mBridgeProcess = pb.start();

      BufferedReader reader = new BufferedReader(
          new InputStreamReader(mBridgeProcess.getInputStream()));
      String output = reader.readLine();

      mRunning = true;
      Log.i(TAG, "X11 bridge started: " + output);
      return "{\"status\":\"ok\",\"mode\":\"x11\",\"message\":\""
          + (output != null ? output : "started") + "\"}";
    } catch (Exception e) {
      return "{\"error\":\"" + e.getMessage() + "\"}";
    }
  }

  private String startWaylandBridge() {
    // Wayland proxy is aspirational — not yet implemented
    Log.w(TAG, "Wayland mode not yet implemented — falling back to X11");
    mMode = "x11";
    return startX11Bridge();
  }
}
