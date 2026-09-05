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
 * - apex-tune: read tuning params (procfs /proc/apex/)
 * - apex-chroot: read chroot status (procfs mounts)
 *
 * All tools are READ-ONLY. The agent cannot write to hardware.
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

  public McpRegistry() {
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
    registerTool("apex-tune",
        "Read current kernel tuning parameters from APEX sysfs",
        "{\"type\":\"object\",\"properties\":{\"param\":{\"type\":\"string\",\"description\":\"Tuning parameter name\"}}}",
        true,
        this::executeApexTune);
    registerTool("apex-chroot",
        "Read Arch Linux ARM chroot status and mount information",
        "{\"type\":\"object\",\"properties\":{}",
        true,
        this::executeApexChroot);
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
    if (!tool.isReadOnly) {
      return "[error] Tool is not read-only: " + toolName;
    }
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
