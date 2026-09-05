/*
 * LindroidManager.java
 *
 * Manages a Linux container (Arch Linux ARM) running alongside Android.
 * Upgrade path from the existing chroot + apex-bridge approach.
 *
 * Architecture:
 *   - Container uses Linux namespaces (pid, net, mount, user)
 *   - Android is host, Arch Linux ARM is container
 *   - Shared display via X11 forwarding to Termux:X11 or Wayland proxy
 *   - Shared filesystem: /data/adb/apex/arch mounted in both
 *   - Network: veth pair, container gets its own IP
 *   - No KVM (SM6225 doesn't support it) — container, not VM
 *
 * The container is managed via shell scripts that call unshare/nsenter
 * for namespace isolation. This Java service handles lifecycle and
 * provides a binder interface for the agent and Apex Control.
 */

package com.apex.lindroid;

import android.content.Context;
import android.os.Binder;
import android.os.IBinder;
import android.os.ServiceManager;
import android.util.Log;

import org.json.JSONObject;

import java.io.BufferedReader;
import java.io.InputStreamReader;

public class LindroidManager {
  private static final String TAG = "LindroidManager";
  private static final String SERVICE_NAME = "apex_lindroid";
  private static final String CONTAINER_ROOT = "/data/adb/apex/arch";
  private static final String INIT_SCRIPT = "/system/bin/lindroid-start.sh";
  private static final String STOP_SCRIPT = "/system/bin/lindroid-stop.sh";
  private static final String EXEC_SCRIPT = "/system/bin/lindroid-exec.sh";
  private static final String MIGRATE_SCRIPT = "/system/bin/lindroid-migrate.sh";

  private final Context mContext;
  private boolean mRunning = false;
  private Process mContainerProcess;

  public LindroidManager(Context context) {
    mContext = context;
    Log.i(TAG, "LindroidManager initialized");
  }

  private final ILindroid.Stub mBinder = new ILindroid.Stub() {
    @Override
    public String startContainer() {
      return doStart();
    }

    @Override
    public String stopContainer() {
      return doStop();
    }

    @Override
    public String exec(String command) {
      return doExec(command);
    }

    @Override
    public String installPackage(String packageName) {
      return doExec("pacman -Sy --noconfirm " + packageName);
    }

    @Override
    public String launchApp(String appName) {
      // Launch with DISPLAY set to the X11/Wayland bridge
      return doExec("DISPLAY=:0 " + appName + " &");
    }

    @Override
    public String getStatus() {
      try {
        JSONObject status = new JSONObject();
        status.put("running", mRunning);
        status.put("containerRoot", CONTAINER_ROOT);
        status.put("display", "x11-bridge");
        return status.toString();
      } catch (Exception e) {
        return "{\"error\":\"" + e.getMessage() + "\"}";
      }
    }

    @Override
    public boolean isRunning() {
      return mRunning;
    }

    @Override
    public String migrate() {
      return doMigrate();
    }
  };

  private String doStart() {
    if (mRunning) {
      return "{\"status\":\"ok\",\"message\":\"already running\"}";
    }
    try {
      ProcessBuilder pb = new ProcessBuilder("sh", INIT_SCRIPT);
      pb.redirectErrorStream(true);
      mContainerProcess = pb.start();

      BufferedReader reader = new BufferedReader(
          new InputStreamReader(mContainerProcess.getInputStream()));
      String line = reader.readLine();
      String output = line != null ? line : "started";

      mRunning = true;
      Log.i(TAG, "Container started: " + output);
      return "{\"status\":\"ok\",\"message\":\"" + output + "\"}";
    } catch (Exception e) {
      Log.e(TAG, "Start failed: " + e.getMessage());
      return "{\"error\":\"" + e.getMessage() + "\"}";
    }
  }

  private String doStop() {
    if (!mRunning) {
      return "{\"status\":\"ok\",\"message\":\"not running\"}";
    }
    try {
      ProcessBuilder pb = new ProcessBuilder("sh", STOP_SCRIPT);
      pb.redirectErrorStream(true);
      Process p = pb.start();
      p.waitFor();
      mRunning = false;
      mContainerProcess = null;
      Log.i(TAG, "Container stopped");
      return "{\"status\":\"ok\",\"message\":\"container stopped\"}";
    } catch (Exception e) {
      Log.e(TAG, "Stop failed: " + e.getMessage());
      return "{\"error\":\"" + e.getMessage() + "\"}";
    }
  }

  private String doExec(String command) {
    if (!mRunning) {
      return "{\"error\":\"container not running\"}";
    }
    try {
      ProcessBuilder pb = new ProcessBuilder("sh", EXEC_SCRIPT, command);
      pb.redirectErrorStream(true);
      Process p = pb.start();

      BufferedReader reader = new BufferedReader(
          new InputStreamReader(p.getInputStream()));
      StringBuilder sb = new StringBuilder();
      String line;
      while ((line = reader.readLine()) != null) {
        sb.append(line).append("\n");
      }
      p.waitFor();

      String output = sb.toString().trim();
      return "{\"status\":\"ok\",\"output\":\"" + escapeJson(output) + "\"}";
    } catch (Exception e) {
      return "{\"error\":\"" + e.getMessage() + "\"}";
    }
  }

  private String doMigrate() {
    try {
      ProcessBuilder pb = new ProcessBuilder("sh", MIGRATE_SCRIPT);
      pb.redirectErrorStream(true);
      Process p = pb.start();

      BufferedReader reader = new BufferedReader(
          new InputStreamReader(p.getInputStream()));
      StringBuilder sb = new StringBuilder();
      String line;
      while ((line = reader.readLine()) != null) {
        sb.append(line).append("\n");
      }
      p.waitFor();

      return "{\"status\":\"ok\",\"output\":\"" + escapeJson(sb.toString().trim()) + "\"}";
    } catch (Exception e) {
      return "{\"error\":\"" + e.getMessage() + "\"}";
    }
  }

  private static String escapeJson(String s) {
    if (s == null) return "";
    return s.replace("\\", "\\\\")
        .replace("\"", "\\\"")
        .replace("\n", "\\n");
  }

  public void publish() {
    ServiceManager.addService(SERVICE_NAME, mBinder);
    Log.i(TAG, "Published as '" + SERVICE_NAME + "'");
  }

  public IBinder getBinder() {
    return mBinder;
  }
}
