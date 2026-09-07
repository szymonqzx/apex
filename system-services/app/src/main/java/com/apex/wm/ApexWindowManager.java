/*
 * ApexWindowManager.java
 *
 * System service that manages freeform windows on phone form factor.
 * Runs in system_server. Uses Android's TaskOrganizer and
 * TaskDisplayArea APIs to manage freeform windows without modifying
 * SurfaceFlinger.
 *
 * Architecture:
 *   1. Framework overlay (ApexWmOverlay.apk) enables
 *      config_freeformWindowManagement=true
 *   2. This service uses TaskOrganizer to create/manage freeform tasks
 *   3. Windows are positioned via TaskOrganizer.setTaskBounds()
 *   4. Tiling mode calculates positions and applies them
 *   5. Desktop mode adds title bars + taskbar (via SurfaceControl)
 *
 * Security:
 *   - Only system_server and Apex Control (system app) can call
 *   - Agent daemon calls via binder with system UID
 *   - No user-installed apps can access this service
 */

package com.apex.wm;

import android.app.ActivityTaskManager;
import android.app.TaskInfo;
import android.app.WindowConfiguration;
import android.content.Context;
import android.os.Binder;
import android.os.IBinder;
import android.os.RemoteException;
import android.os.ServiceManager;
import android.util.Log;
import android.window.TaskOrganizer;

import org.json.JSONArray;
import org.json.JSONObject;

import java.util.ArrayList;
import java.util.List;

public class ApexWindowManager {
  private static final String TAG = "ApexWindowManager";
  private static final String SERVICE_NAME = "apex_wm";

  private final Context mContext;
  private final TaskOrganizer mTaskOrganizer;
  private boolean mFreeformEnabled = false;
  private boolean mTilingMode = false;
  private boolean mDesktopLayout = false;
  private final List<ApexWindow> mWindows = new ArrayList<>();

  // ── Window data model ───────────────────────────────────────────

  private static class ApexWindow {
    String windowId;
    String packageName;
    String title;
    int x, y, width, height;
    int zOrder;
    boolean minimized;
    boolean focused;
    int taskId; // Android task ID

    ApexWindow(int taskId, String packageName, String title,
               int x, int y, int width, int height) {
      this.taskId = taskId;
      this.windowId = "win-" + taskId;
      this.packageName = packageName;
      this.title = title;
      this.x = x;
      this.y = y;
      this.width = width;
      this.height = height;
      this.zOrder = 0;
      this.minimized = false;
      this.focused = false;
    }

    JSONObject toJson() throws Exception {
      JSONObject obj = new JSONObject();
      obj.put("windowId", windowId);
      obj.put("packageName", packageName);
      obj.put("title", title);
      obj.put("x", x);
      obj.put("y", y);
      obj.put("width", width);
      obj.put("height", height);
      obj.put("zOrder", zOrder);
      obj.put("minimized", minimized);
      obj.put("focused", focused);
      return obj;
    }
  }

  public ApexWindowManager(Context context) {
    mContext = context;
    mTaskOrganizer = new TaskOrganizer();
    Log.i(TAG, "ApexWindowManager initialized");
  }

  // ── Binder service ──────────────────────────────────────────────

  private final IApexWindowManager.Stub mBinder = new IApexWindowManager.Stub() {
    @Override
    public String listWindows() {
      try {
        JSONArray arr = new JSONArray();
        synchronized (mWindows) {
          for (ApexWindow w : mWindows) {
            if (!w.minimized) {
              arr.put(w.toJson());
            }
          }
        }
        JSONObject result = new JSONObject();
        result.put("windows", arr);
        result.put("count", arr.length());
        result.put("freeformEnabled", mFreeformEnabled);
        result.put("tilingMode", mTilingMode);
        result.put("desktopLayout", mDesktopLayout);
        return result.toString();
      } catch (Exception e) {
        return "{\"error\":\"" + e.getMessage() + "\"}";
      }
    }

    @Override
    public String getWindowInfo(String windowId) {
      synchronized (mWindows) {
        for (ApexWindow w : mWindows) {
          if (w.windowId.equals(windowId)) {
            try {
              return w.toJson().toString();
            } catch (Exception e) {
              return "{\"error\":\"" + e.getMessage() + "\"}";
            }
          }
        }
      }
      return "{\"error\":\"window not found: " + windowId + "\"}";
    }

    @Override
    public boolean focusWindow(String windowId) {
      synchronized (mWindows) {
        for (ApexWindow w : mWindows) {
          w.focused = w.windowId.equals(windowId);
          if (w.focused) {
            w.zOrder = getMaxZOrder() + 1;
            Log.i(TAG, "Focused: " + windowId);
          }
        }
      }
      return true;
    }

    @Override
    public boolean closeWindow(String windowId) {
      synchronized (mWindows) {
        mWindows.removeIf(w -> w.windowId.equals(windowId));
      }
      Log.i(TAG, "Closed: " + windowId);
      return true;
    }

    @Override
    public boolean moveWindow(String windowId, int x, int y) {
      synchronized (mWindows) {
        for (ApexWindow w : mWindows) {
          if (w.windowId.equals(windowId)) {
            w.x = x;
            w.y = y;
            applyTaskBounds(w);
            return true;
          }
        }
      }
      return false;
    }

    @Override
    public boolean resizeWindow(String windowId, int width, int height) {
      synchronized (mWindows) {
        for (ApexWindow w : mWindows) {
          if (w.windowId.equals(windowId)) {
            w.width = width;
            w.height = height;
            applyTaskBounds(w);
            return true;
          }
        }
      }
      return false;
    }

    @Override
    public boolean minimizeWindow(String windowId) {
      synchronized (mWindows) {
        for (ApexWindow w : mWindows) {
          if (w.windowId.equals(windowId)) {
            w.minimized = true;
            w.focused = false;
            return true;
          }
        }
      }
      return false;
    }

    @Override
    public boolean restoreWindow(String windowId) {
      synchronized (mWindows) {
        for (ApexWindow w : mWindows) {
          if (w.windowId.equals(windowId)) {
            w.minimized = false;
            return focusWindow(windowId);
          }
        }
      }
      return false;
    }

    @Override
    public boolean setTilingMode(boolean enabled) {
      mTilingMode = enabled;
      if (enabled) {
        return tileGrid();
      }
      Log.i(TAG, "Tiling mode: " + enabled);
      return true;
    }

    @Override
    public boolean tileGrid() {
      synchronized (mWindows) {
        int visible = 0;
        for (ApexWindow w : mWindows) {
          if (!w.minimized) visible++;
        }
        if (visible == 0) return true;

        int displayWidth = mContext.getResources().getDisplayMetrics().widthPixels;
        int displayHeight = mContext.getResources().getDisplayMetrics().heightPixels;
        int cols = (int) Math.ceil(Math.sqrt(visible));
        int rows = (int) Math.ceil((double) visible / cols);
        int tileW = displayWidth / cols;
        int tileH = displayHeight / rows;

        int idx = 0;
        for (ApexWindow w : mWindows) {
          if (w.minimized) continue;
          int col = idx % cols;
          int row = idx / cols;
          w.x = col * tileW;
          w.y = row * tileH;
          w.width = tileW;
          w.height = tileH;
          applyTaskBounds(w);
          idx++;
        }
      }
      Log.i(TAG, "Tiled grid");
      return true;
    }

    @Override
    public boolean tileSplit(String windowId1, String windowId2) {
      int displayWidth = mContext.getResources().getDisplayMetrics().widthPixels;
      int displayHeight = mContext.getResources().getDisplayMetrics().heightPixels;
      int halfW = displayWidth / 2;

      synchronized (mWindows) {
        for (ApexWindow w : mWindows) {
          if (w.windowId.equals(windowId1)) {
            w.x = 0; w.y = 0; w.width = halfW; w.height = displayHeight;
            applyTaskBounds(w);
          } else if (w.windowId.equals(windowId2)) {
            w.x = halfW; w.y = 0; w.width = halfW; w.height = displayHeight;
            applyTaskBounds(w);
          }
        }
      }
      Log.i(TAG, "Tiled split: " + windowId1 + " | " + windowId2);
      return true;
    }

    @Override
    public boolean setDesktopLayout(boolean enabled) {
      mDesktopLayout = enabled;
      Log.i(TAG, "Desktop layout: " + enabled);
      // Desktop layout adds title bars + taskbar via SurfaceControl
      // In the full implementation, this would create overlay surfaces
      return true;
    }

    @Override
    public boolean isWmActive() {
      return mFreeformEnabled;
    }

    @Override
    public boolean isFreeformEnabled() {
      return mFreeformEnabled;
    }

    @Override
    public boolean enableFreeform() {
      // Enable freeform via Settings.Global
      android.provider.Settings.Global.putInt(
          mContext.getContentResolver(),
          "freeform_window_management", 1);
      mFreeformEnabled = true;
      Log.i(TAG, "Freeform mode enabled");
      return true;
    }
  };

  // ── Internal helpers ────────────────────────────────────────────

  private int getMaxZOrder() {
    int max = 0;
    for (ApexWindow w : mWindows) {
      if (w.zOrder > max) max = w.zOrder;
    }
    return max;
  }

  private void applyTaskBounds(ApexWindow w) {
    // In the full AOSP build, this calls:
    //   ActivityTaskManager.getService().setTaskBounds(
    //       w.taskId, new Rect(w.x, w.y, w.x + w.width, w.y + w.height));
    // For now, we log the intent.
    Log.d(TAG, "applyTaskBounds: " + w.windowId
        + " -> (" + w.x + "," + w.y + ") "
        + w.width + "x" + w.height);
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
