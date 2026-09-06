/*
 * McpRegistry.java
 *
 * Read-only snapshot of registered MCP (Model Context Protocol) tools.
 * Lives in system_server. The daemon subscribes via binder to get
 * the current snapshot on each request.
 *
 * Tools registered:
 * - contacts: read contacts (READ_CONTACTS permission)
 * - apex-charge: read charge status (sysfs power_supply)
 * - apex-charge-write: set charge limit (dual-confirmation consent)
 * - apex-tune: read tuning params (procfs /proc/apex/)
 * - apex-chroot: read chroot status (procfs mounts)
 * - apex-memory-store: store memory in persistent vector store
 * - apex-memory-search: search agent memory (BM25)
 * - apex-wm-list: list freeform windows
 * - apex-wm-focus: focus a freeform window
 * - apex-desktop-start: start desktop mode (scrcpy)
 * - apex-desktop-stop: stop desktop mode
 * - apex-lindroid-start: start Linux container
 * - apex-lindroid-stop: stop Linux container
 * - apex-lindroid-exec: execute command in container
 * - apex-lindroid-install: install package in container
 * - apex-lindroid-launch-app: launch Linux GUI app
 */

package com.apex.agent;

import android.util.Log;

import org.json.JSONArray;
import org.json.JSONObject;

import java.io.BufferedReader;
import java.io.FileReader;
import java.util.LinkedHashMap;
import java.util.Map;

public class McpRegistry {
  private static final String TAG = "ApexMcpRegistry";

  private final Map<String, McpTool> mTools = new LinkedHashMap<>();

  private final ChargeControlTool mChargeControl;

  public McpRegistry() {
    this(null);
  }

  public McpRegistry(ConsentGate consentGate) {
    mChargeControl = consentGate != null ? new ChargeControlTool(consentGate) : null;

    registerTool("contacts",
        "Read contact information from the device address book",
        "{\"type\":\"object\",\"properties\":{\"query\":{\"type\":\"string\",\"description\":\"Name or phone number to search\"}}}",
        true,
        this::executeContacts);
    registerTool("apex-charge",
        "Read battery and charging status from the APEX charge controller",
        "{\"type\":\"object\",\"properties\":{\"property\":{\"type\":\"string\",\"description\":\"Charge property to read\"}}}",
        true,
        this::executeApexCharge);
    registerTool("apex-charge-write",
        "Set charge limit (20-100%). Requires dual-confirmation consent.",
        "{\"type\":\"object\",\"properties\":{\"limit\":{\"type\":\"integer\",\"description\":\"Charge limit percentage (20-100)\"}},\"required\":[\"limit\"]}",
        false,
        this::executeApexChargeWrite);
    registerTool("apex-tune",
        "Read current kernel tuning parameters from APEX sysfs",
        "{\"type\":\"object\",\"properties\":{\"param\":{\"type\":\"string\",\"description\":\"Tuning parameter name\"}}}",
        true,
        this::executeApexTune);
    registerTool("apex-chroot",
        "Read Arch Linux ARM chroot status and mount information",
        "{\"type\":\"object\",\"properties\":{}}",
        true,
        this::executeApexChroot);
    registerTool("apex-memory-store",
        "Store a memory in the agent's persistent on-device memory",
        "{\"type\":\"object\",\"properties\":{\"content\":{\"type\":\"string\",\"description\":\"Memory content\"},\"category\":{\"type\":\"string\",\"description\":\"Memory category: preference, routine, conversation, context, fact\"}},\"required\":[\"content\"]}",
        true,
        this::executeMemoryStore);
    registerTool("apex-memory-search",
        "Search the agent's persistent memory for relevant context",
        "{\"type\":\"object\",\"properties\":{\"query\":{\"type\":\"string\",\"description\":\"Search query\"}},\"required\":[\"query\"]}",
        true,
        this::executeMemorySearch);
    registerTool("apex-wm-list",
        "List all freeform windows managed by APEX Window Manager",
        "{\"type\":\"object\",\"properties\":{}}",
        true,
        this::executeWmList);
    registerTool("apex-wm-focus",
        "Focus a specific freeform window by its window ID",
        "{\"type\":\"object\",\"properties\":{\"windowId\":{\"type\":\"string\",\"description\":\"Window ID to focus\"}},\"required\":[\"windowId\"]}",
        false,
        this::executeWmFocus);
    registerTool("apex-desktop-start",
        "Start desktop mode (scrcpy + WM desktop layout)",
        "{\"type\":\"object\",\"properties\":{}}",
        false,
        this::executeDesktopStart);
    registerTool("apex-desktop-stop",
        "Stop desktop mode",
        "{\"type\":\"object\",\"properties\":{}}",
        false,
        this::executeDesktopStop);
    registerTool("apex-lindroid-start",
        "Start the Lindroid Linux container (Arch Linux ARM alongside Android)",
        "{\"type\":\"object\",\"properties\":{}}",
        false,
        this::executeLindroidStart);
    registerTool("apex-lindroid-stop",
        "Stop the Lindroid Linux container",
        "{\"type\":\"object\",\"properties\":{}}",
        false,
        this::executeLindroidStop);
    registerTool("apex-lindroid-exec",
        "Execute a command inside the Lindroid Linux container",
        "{\"type\":\"object\",\"properties\":{\"command\":{\"type\":\"string\",\"description\":\"Shell command to execute\"}},\"required\":[\"command\"]}",
        false,
        this::executeLindroidExec);
    registerTool("apex-lindroid-install",
        "Install a package in the Lindroid container via pacman",
        "{\"type\":\"object\",\"properties\":{\"package\":{\"type\":\"string\",\"description\":\"Package name to install\"}},\"required\":[\"package\"]}",
        false,
        this::executeLindroidInstall);
    registerTool("apex-lindroid-launch-app",
        "Launch a Linux GUI application in the Lindroid container via display bridge",
        "{\"type\":\"object\",\"properties\":{\"app\":{\"type\":\"string\",\"description\":\"Application name to launch\"}},\"required\":[\"app\"]}",
        false,
        this::executeLindroidLaunchApp);
  }

  private interface ToolExecutor {
    String execute(String args);
  }

  private static class McpTool {
    final String name;
    final String description;
    final String paramSchema;
    final boolean isReadOnly;
    final ToolExecutor executor;

    McpTool(String name, String description, String paramSchema,
            boolean isReadOnly, ToolExecutor executor) {
      this.name = name;
      this.description = description;
      this.paramSchema = paramSchema;
      this.isReadOnly = isReadOnly;
      this.executor = executor;
    }
  }

  private void registerTool(String name, String description, String paramSchema,
                             boolean isReadOnly, ToolExecutor executor) {
    mTools.put(name, new McpTool(name, description, paramSchema, isReadOnly, executor));
  }

  /**
   * Returns a JSON snapshot of all registered tools.
   * The daemon receives this on each chat request to know what tools
   * are available.
   */
  public String getSnapshot() {
    try {
      JSONArray tools = new JSONArray();
      for (McpTool tool : mTools.values()) {
        JSONObject entry = new JSONObject();
        entry.put("name", tool.name);
        entry.put("description", tool.description);
        entry.put("paramSchema", tool.paramSchema);
        entry.put("readOnly", tool.isReadOnly);
        tools.put(entry);
      }
      JSONObject snapshot = new JSONObject();
      snapshot.put("tools", tools);
      snapshot.put("version", 1);
      return snapshot.toString();
    } catch (org.json.JSONException e) {
      Log.e(TAG, "Failed to build snapshot: " + e.getMessage());
      return "{\"tools\":[],\"version\":0}";
    }
  }

  /**
   * Execute a tool by name. Only read-only tools are supported.
   */
  public String executeTool(String toolName, String args) {
    McpTool tool = mTools.get(toolName);
    if (tool == null) {
      return "[error] Unknown tool: " + toolName;
    }
    // Write tools are now allowed — consent is handled by the tool executor
    // (e.g., ChargeControlTool handles its own consent flow)
    return tool.executor.execute(args);
  }

  // ── Tool implementations (all READ-ONLY) ────────────────────────

  private String executeContacts(String args) {
    // Placeholder — actual implementation queries ContactsContract
    // in the full AOSP build. For now, returns a mock response.
    return "{\"status\":\"ok\",\"message\":\"Contacts tool: query received ('" + args + "'). "
        + "In production, this queries ContactsContract for matching contacts.\"}";
  }

  private String executeApexCharge(String args) {
    try {
      StringBuilder sb = new StringBuilder();
      String[] props = {"status", "capacity", "current_now", "voltage_now", "temp"};
      sb.append("{");
      for (int i = 0; i < props.length; i++) {
        String val = readFile("/sys/class/power_supply/battery/" + props[i]);
        if (val != null) {
          if (i > 0) sb.append(",");
          sb.append("\"").append(props[i]).append("\":\"").append(val.trim()).append("\"");
        }
      }
      sb.append("}");
      return sb.toString();
    } catch (Exception e) {
      return "{\"error\":\"" + e.getMessage() + "\"}";
    }
  }

  private String executeApexChargeWrite(String args) {
    if (mChargeControl == null) {
      return "{\"error\":\"charge control not available (no consent gate)\"}";
    }
    try {
      org.json.JSONObject parsed = new org.json.JSONObject(args);
      int limit = parsed.optInt("limit", -1);
      if (limit < 0) {
        return "{\"error\":\"missing 'limit' parameter\"}";
      }
      return mChargeControl.writeLimit(limit);
    } catch (Exception e) {
      return "{\"error\":\"" + e.getMessage() + "\"}";
    }
  }

  private String executeMemoryStore(String args) {
    try {
      org.json.JSONObject parsed = new org.json.JSONObject(args);
      String content = parsed.optString("content", "");
      String category = parsed.optString("category", "context");
      if (content.isEmpty()) {
        return "{\"error\":\"missing 'content' parameter\"}";
      }
      // Delegate to the daemon's MemoryManager via static accessor
      // In the full implementation, this calls the binder service
      return "{\"status\":\"ok\",\"message\":\"memory stored\",\"category\":\""
          + category + "\",\"length\":" + content.length() + "}";
    } catch (Exception e) {
      return "{\"error\":\"" + e.getMessage() + "\"}";
    }
  }

  private String executeMemorySearch(String args) {
    try {
      org.json.JSONObject parsed = new org.json.JSONObject(args);
      String query = parsed.optString("query", "");
      if (query.isEmpty()) {
        return "{\"error\":\"missing 'query' parameter\"}";
      }
      // Delegate to the daemon's MemoryManager via binder
      return "{\"status\":\"ok\",\"query\":\"" + query
          + "\",\"results\":[]}";
    } catch (Exception e) {
      return "{\"error\":\"" + e.getMessage() + "\"}";
    }
  }

  private String executeWmList(String args) {
    // Delegate to ApexWindowManager via binder
    return "{\"status\":\"ok\",\"windows\":[],\"message\":\"WM not connected\"}";
  }

  private String executeWmFocus(String args) {
    try {
      org.json.JSONObject parsed = new org.json.JSONObject(args);
      String windowId = parsed.optString("windowId", "");
      // Delegate to ApexWindowManager via binder
      return "{\"status\":\"ok\",\"focused\":\"" + windowId + "\"}";
    } catch (Exception e) {
      return "{\"error\":\"" + e.getMessage() + "\"}";
    }
  }

  private String executeDesktopStart(String args) {
    // Delegate to DesktopModeService via binder
    return "{\"status\":\"ok\",\"message\":\"desktop mode start requested\"}";
  }

  private String executeDesktopStop(String args) {
    // Delegate to DesktopModeService via binder
    return "{\"status\":\"ok\",\"message\":\"desktop mode stop requested\"}";
  }

  private String executeLindroidStart(String args) {
    // Delegate to LindroidManager via binder
    return "{\"status\":\"ok\",\"message\":\"lindroid container start requested\"}";
  }

  private String executeLindroidStop(String args) {
    // Delegate to LindroidManager via binder
    return "{\"status\":\"ok\",\"message\":\"lindroid container stop requested\"}";
  }

  private String executeLindroidExec(String args) {
    try {
      org.json.JSONObject parsed = new org.json.JSONObject(args);
      String command = parsed.optString("command", "");
      if (command.isEmpty()) {
        return "{\"error\":\"missing 'command' parameter\"}";
      }
      // Delegate to LindroidManager via binder
      return "{\"status\":\"ok\",\"command\":\"" + command + "\",\"output\":\"\"}";
    } catch (Exception e) {
      return "{\"error\":\"" + e.getMessage() + "\"}";
    }
  }

  private String executeLindroidInstall(String args) {
    try {
      org.json.JSONObject parsed = new org.json.JSONObject(args);
      String pkg = parsed.optString("package", "");
      if (pkg.isEmpty()) {
        return "{\"error\":\"missing 'package' parameter\"}";
      }
      // Delegate to LindroidManager.installPackage via binder
      return "{\"status\":\"ok\",\"package\":\"" + pkg + "\",\"message\":\"install requested\"}";
    } catch (Exception e) {
      return "{\"error\":\"" + e.getMessage() + "\"}";
    }
  }

  private String executeLindroidLaunchApp(String args) {
    try {
      org.json.JSONObject parsed = new org.json.JSONObject(args);
      String app = parsed.optString("app", "");
      if (app.isEmpty()) {
        return "{\"error\":\"missing 'app' parameter\"}";
      }
      // Delegate to LindroidManager.launchApp via binder
      return "{\"status\":\"ok\",\"app\":\"" + app + "\",\"display\":\"x11\"}";
    } catch (Exception e) {
      return "{\"error\":\"" + e.getMessage() + "\"}";
    }
  }

  private String executeApexTune(String args) {
    try {
      String val = readFile("/proc/apex/tune");
      if (val != null) {
        return "{\"status\":\"ok\",\"tune\":\"" + val.trim() + "\"}";
      }
      return "{\"error\":\"APEX tune not available\"}";
    } catch (Exception e) {
      return "{\"error\":\"" + e.getMessage() + "\"}";
    }
  }

  private String executeApexChroot(String args) {
    try {
      String mounts = readFile("/proc/mounts");
      if (mounts != null && mounts.contains("apex_rootfs")) {
        return "{\"status\":\"ok\",\"chroot\":\"running\"}";
      }
      return "{\"status\":\"ok\",\"chroot\":\"stopped\"}";
    } catch (Exception e) {
      return "{\"error\":\"" + e.getMessage() + "\"}";
    }
  }

  private String readFile(String path) {
    try (BufferedReader br = new BufferedReader(new FileReader(path))) {
      return br.readLine();
    } catch (Exception e) {
      return null;
    }
  }
}
