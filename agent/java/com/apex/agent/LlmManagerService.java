/*
 * LlmManagerService.java
 *
 * System service running inside system_server. Manages the agent model
 * registry, tier switching, and binder dispatch. Does NOT run inference
 * — dispatches to apexagentd via local socket.
 *
 * Hybrid architecture:
 * - system_server: LlmManagerService (this), McpRegistry, ConsentGate,
 *   HitlConsentStore — survive daemon crashes
 * - apexagentd: inference (llama.cpp), tool dispatch — killable under OOM
 *
 * When apexagentd crashes (binder death), this service switches to
 * fallback mode: returns plain-text error, keeps registry/consent alive.
 */

package com.apex.agent;

import android.content.Context;
import android.os.Binder;
import android.os.IBinder;
import android.os.RemoteException;
import android.os.ServiceManager;
import android.util.Log;

import org.json.JSONObject;

import java.io.IOException;
import java.io.InputStream;
import java.io.OutputStream;
import java.net.LocalSocket;
import java.net.LocalSocketAddress;
import java.util.ArrayList;
import java.util.List;
import java.util.concurrent.ConcurrentHashMap;
import java.util.concurrent.CopyOnWriteArrayList;
import java.util.concurrent.ExecutorService;
import java.util.concurrent.Executors;
import java.util.concurrent.TimeUnit;

public class LlmManagerService extends IApexAgent.Stub {

  private static final String TAG = "ApexLlmManager";
  private static final String SOCKET_PATH = "/dev/socket/apex-agent";
  private static final long DAEMON_TIMEOUT_MS = 5000;

  private final Context mContext;
  private final McpRegistry mMcpRegistry;
  private final ConsentGate mConsentGate;
  private final HitlConsentStore mConsentStore;

  private final CopyOnWriteArrayList<IApexToolCallback> mCallbacks =
      new CopyOnWriteArrayList<>();
  private final ExecutorService mExecutor = Executors.newCachedThreadPool();

  // Model registry
  private final ConcurrentHashMap<String, ModelEntry> mModels = new ConcurrentHashMap<>();
  private volatile String mCurrentTier = "small"; // default 1.5B
  private volatile boolean mDaemonAlive = false;
  private volatile boolean mFallbackMode = false;

  private IBinder.DeathRecipient mDaemonDeathRecipient =
      new IBinder.DeathRecipient() {
        @Override
        public void binderDied() {
          Log.w(TAG, "apexagentd died — entering fallback mode");
          mDaemonAlive = false;
          mFallbackMode = true;
        }
      };

  // Model entry
  private static class ModelEntry {
    final String id;
    final String name;
    final String tier;
    final int sizeMB;
    final String path;

    ModelEntry(String id, String name, String tier, int sizeMB, String path) {
      this.id = id;
      this.name = name;
      this.tier = tier;
      this.sizeMB = sizeMB;
      this.path = path;
    }
  }

  public LlmManagerService(Context context) {
    mContext = context;
    mConsentStore = new HitlConsentStore(context);
    mConsentGate = new ConsentGate(mConsentStore);
    mMcpRegistry = new McpRegistry();

    registerDefaultModels();
    Log.i(TAG, "LlmManagerService initialized (tier=" + mCurrentTier + ")");
  }

  private void registerDefaultModels() {
    mModels.put("qwen2.5-0.5b", new ModelEntry(
        "qwen2.5-0.5b", "Qwen 2.5 0.5B", "nano", 600,
        "/data/local/tmp/models/qwen2.5-0.5b-q4_k_m.gguf"));
    mModels.put("qwen2.5-1.5b", new ModelEntry(
        "qwen2.5-1.5b", "Qwen 2.5 1.5B", "small", 1100,
        "/data/local/tmp/models/qwen2.5-1.5b-q4_k_m.gguf"));
    mModels.put("qwen2.5-3b", new ModelEntry(
        "qwen2.5-3b", "Qwen 2.5 3B", "medium", 2200,
        "/data/local/tmp/models/qwen2.5-3b-q4_k_m.gguf"));
    // Remote model (OmniRoute-compatible) — opt-in per request
    mModels.put("remote-omniroute", new ModelEntry(
        "remote-omniroute", "Remote (OmniRoute)", "remote", 0,
        null));
  }

  public void publish() {
    ServiceManager.addService("apex.agent", this);
    Log.i(TAG, "Published as ServiceManager 'apex.agent'");
  }

  // ── IApexAgent.Stub implementation ──────────────────────────────

  @Override
  public String chat(String prompt) {
    return chatWithModel(prompt, getModelIdForTier(mCurrentTier));
  }

  @Override
  public String chatWithModel(String prompt, String modelId) {
    if (mFallbackMode || !mDaemonAlive) {
      return "[fallback] Agent daemon unavailable. "
          + "Registry and consent are still active. "
          + "Please retry after apexagentd restarts.";
    }

    try {
      return dispatchToDaemon(prompt, modelId);
    } catch (IOException e) {
      Log.e(TAG, "Daemon dispatch failed: " + e.getMessage());
      mFallbackMode = true;
      mDaemonAlive = false;
      return "[fallback] Lost connection to agent daemon: " + e.getMessage();
    }
  }

  @Override
  public void setModelTier(String tier) {
    String modelId = getModelIdForTier(tier);
    if (modelId == null) {
      Log.w(TAG, "Unknown model tier: " + tier);
      return;
    }
    mCurrentTier = tier;
    Log.i(TAG, "Model tier set to " + tier + " (model: " + modelId + ")");
  }

  @Override
  public String getModelTier() {
    return mCurrentTier;
  }

  @Override
  public List<String> listAvailableModels() {
    return new ArrayList<>(mModels.keySet());
  }

  @Override
  public ApexAgentStatus getStatus() {
    ModelEntry entry = mModels.get(getModelIdForTier(mCurrentTier));
    int sizeMB = (entry != null) ? entry.sizeMB : 0;
    return new ApexAgentStatus(
        mDaemonAlive,
        entry != null ? entry.name : "unknown",
        sizeMB,
        0.0f, // updated by daemon heartbeat
        mFallbackMode);
  }

  @Override
  public void registerToolCallback(IApexToolCallback cb) {
    if (cb != null) {
      mCallbacks.add(cb);
      try {
        cb.asBinder().linkToDeath(
            new IBinder.DeathRecipient() {
              @Override
              public void binderDied() {
                mCallbacks.remove(cb);
              }
            }, 0);
      } catch (RemoteException e) {
        Log.w(TAG, "Failed to link death recipient for callback");
      }
    }
  }

  @Override
  public void unregisterToolCallback(IApexToolCallback cb) {
    if (cb != null) {
      mCallbacks.remove(cb);
    }
  }

  // ── Daemon communication ────────────────────────────────────────

  private String dispatchToDaemon(String prompt, String modelId) throws IOException {
    LocalSocket socket = new LocalSocket();
    try {
      socket.connect(new LocalSocketAddress(
          SOCKET_PATH, LocalSocketAddress.Namespace.FILESYSTEM));
      socket.setSoTimeout((int) DAEMON_TIMEOUT_MS);

      OutputStream out = socket.getOutputStream();
      InputStream in = socket.getInputStream();

      // Send request as JSON
      JSONObject request = new JSONObject();
      try {
        request.put("prompt", prompt);
        request.put("model", modelId);
        request.put("mcp_snapshot", mMcpRegistry.getSnapshot());
      } catch (org.json.JSONException e) {
        throw new IOException("Failed to build request JSON", e);
      }

      out.write(request.toString().getBytes("UTF-8"));
      out.write('\n');
      out.flush();

      // Read response
      StringBuilder sb = new StringBuilder();
      byte[] buf = new byte[4096];
      int read;
      while ((read = in.read(buf)) != -1) {
        sb.append(new String(buf, 0, read, "UTF-8"));
        if (sb.toString().contains("\n}")) break;
      }

      String response = sb.toString().trim();
      // Check for tool call in response
      if (response.contains("\"tool_call\"")) {
        return handleToolCall(response);
      }
      return response;
    } finally {
      socket.close();
    }
  }

  private String handleToolCall(String response) {
    try {
      JSONObject json = new JSONObject(response);
      String toolName = json.optString("tool_call", "");
      String description = json.optString("tool_description", "");
      String action = json.optString("tool_action", "");

      if (toolName.isEmpty()) return response;

      // Route through consent gate
      String requestId = mConsentGate.requestConsent(toolName, description, action);

      // Notify registered callbacks
      for (IApexToolCallback cb : mCallbacks) {
        try {
          cb.onToolConsentRequested(toolName, description, action);
        } catch (RemoteException e) {
          Log.w(TAG, "Callback failed: " + e.getMessage());
        }
      }

      // Wait for consent decision (60s timeout built into ConsentGate)
      ConsentGate.ConsentState state = mConsentGate.waitForDecision(requestId, 60, TimeUnit.SECONDS);

      switch (state) {
        case APPROVED:
          // Execute the tool call (read-only tools only)
          return executeTool(toolName, action);
        case DENIED:
          return "[denied] Tool call denied by user.";
        case TIMEOUT:
          return "[timeout] Tool call denied by timeout (60s).";
        default:
          return "[error] Unexpected consent state: " + state;
      }
    } catch (org.json.JSONException e) {
      // S2: malformed LLM output — re-prompt with format fix
      Log.w(TAG, "Malformed tool call JSON: " + e.getMessage());
      return "[error] Malformed tool call — please rephrase.";
    }
  }

  private String executeTool(String toolName, String action) {
    // Agent is READ-ONLY over hardware. Only read operations allowed.
    // Actual tool execution delegated to McpRegistry tool handlers.
    return mMcpRegistry.executeTool(toolName, action);
  }

  // ── Daemon lifecycle ────────────────────────────────────────────

  public void onDaemonConnected(IBinder daemonBinder) {
    mDaemonAlive = true;
    mFallbackMode = false;
    try {
      daemonBinder.linkToDeath(mDaemonDeathRecipient, 0);
    } catch (RemoteException e) {
      Log.w(TAG, "Failed to link daemon death recipient");
    }
    Log.i(TAG, "apexagentd connected — exiting fallback mode");
  }

  private String getModelIdForTier(String tier) {
    switch (tier) {
      case "nano": return "qwen2.5-0.5b";
      case "small": return "qwen2.5-1.5b";
      case "medium": return "qwen2.5-3b";
      case "remote": return "remote-omniroute";
      default: return null;
    }
  }

  public McpRegistry getMcpRegistry() {
    return mMcpRegistry;
  }

  public ConsentGate getConsentGate() {
    return mConsentGate;
  }

  public HitlConsentStore getConsentStore() {
    return mConsentStore;
  }
}
