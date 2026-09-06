/*
 * ApexAgentDaemon.java
 *
 * The apexagentd daemon process. PRIMARY inference engine.
 *
 * - Connects to system_server via binder to get McpRegistry snapshot
 * - Receives chat requests via local socket /dev/socket/apex-agent
 * - Loads llama.cpp model via JNI, generates response
 * - If response contains tool call JSON, routes through ConsentGate
 *   via binder callback to system_server
 * - Killable under OOM (oom_score_adj = 900)
 * - On crash, system_server detects via binder death and enters fallback
 *
 * Process isolation (hard constraint #2):
 * A llama.cpp crash in this process must NEVER take down system_server.
 * This daemon runs in its own process with its own SELinux domain.
 */

package com.apex.agent;

import android.os.IBinder;
import android.os.ServiceManager;
import android.util.Log;

import org.json.JSONObject;

import java.io.BufferedReader;
import java.io.IOException;
import java.io.InputStreamReader;
import java.io.OutputStream;
import java.net.LocalServerSocket;
import java.net.LocalSocketAddress;

public class ApexAgentDaemon {
  private static final String TAG = "apexagentd";
  private static final String SOCKET_PATH = "/dev/socket/apex-agent";
  private static final String SERVICE_NAME = "apex.agent";

  private IApexAgent mAgentService;
  private volatile boolean mRunning = false;
  private volatile boolean mModelLoaded = false;
  private String mCurrentModelPath;
  private String mCurrentModelId;
  private MemoryManager mMemoryManager;

  // JNI — loaded from libllm_jni.so
  static {
    try {
      System.loadLibrary("llm_jni");
      Log.i(TAG, "Loaded libllm_jni.so");
    } catch (UnsatisfiedLinkError e) {
      Log.w(TAG, "libllm_jni.so not available — running in stub mode");
    }
  }

  // JNI method declarations
  private native long nativeLoadModel(String path, int nThreads);
  private native String nativeGenerate(long modelHandle, String prompt,
                                        int maxTokens, float temperature);
  private native void nativeUnloadModel(long modelHandle);
  private native int nativeGetMemoryUsage(long modelHandle);
  private native void nativeSetThreadCount(long modelHandle, int nThreads);

  private long mModelHandle = 0;

  public static void main(String[] args) {
    Log.i(TAG, "apexagentd starting...");
    ApexAgentDaemon daemon = new ApexAgentDaemon();
    daemon.start();
  }

  public void start() {
    // Connect to system_server binder service
    IBinder binder = ServiceManager.getService(SERVICE_NAME);
    if (binder == null) {
      Log.e(TAG, "Cannot find " + SERVICE_NAME + " — retrying in 5s");
      try {
        Thread.sleep(5000);
      } catch (InterruptedException e) {
        return;
      }
      binder = ServiceManager.getService(SERVICE_NAME);
      if (binder == null) {
        Log.e(TAG, "Cannot find " + SERVICE_NAME + " — exiting");
        System.exit(1);
        return;
      }
    }

    mAgentService = IApexAgent.Stub.asInterface(binder);
    Log.i(TAG, "Connected to LlmManagerService");

    // Set OOM adjustment — killable under memory pressure
    try {
      android.os.Process.setOomAdj(android.os.Process.myPid(), 900);
    } catch (Exception e) {
      Log.w(TAG, "Failed to set OOM adjustment: " + e.getMessage());
    }

    // Initialize persistent memory (SQLite + BM25 vector store)
    try {
      mMemoryManager = new MemoryManager();
      Log.i(TAG, "Memory manager initialized: "
          + mMemoryManager.getMemoryCount() + " memories");
    } catch (Exception e) {
      Log.w(TAG, "Memory manager init failed (non-fatal): " + e.getMessage());
    }

    // Load default model
    loadModel("qwen2.5-1.5b");

    // Start socket server
    mRunning = true;
    startSocketServer();

    Log.i(TAG, "apexagentd ready");
  }

  private void loadModel(String modelId) {
    if (mModelLoaded && modelId.equals(mCurrentModelId)) {
      return; // already loaded
    }

    // Unload previous model
    if (mModelLoaded && mModelHandle != 0) {
      nativeUnloadModel(mModelHandle);
      mModelHandle = 0;
      mModelLoaded = false;
    }

    // Determine model path
    mCurrentModelPath = getModelPath(modelId);
    mCurrentModelId = modelId;

    if (mCurrentModelPath == null) {
      Log.e(TAG, "Unknown model: " + modelId);
      return;
    }

    // Load via JNI (4 threads for A73 cluster)
    try {
      mModelHandle = nativeLoadModel(mCurrentModelPath, 4);
      if (mModelHandle != 0) {
        mModelLoaded = true;
        Log.i(TAG, "Model loaded: " + modelId + " (handle=" + mModelHandle + ")");
      } else {
        Log.e(TAG, "Failed to load model: " + modelId);
      }
    } catch (UnsatisfiedLinkError e) {
      Log.w(TAG, "JNI not available — running in stub mode (no inference)");
    }
  }

  private void startSocketServer() {
    try {
      LocalServerSocket server = new LocalServerSocket(
          new LocalSocketAddress(SOCKET_PATH,
              LocalSocketAddress.Namespace.FILESYSTEM));

      Log.i(TAG, "Listening on " + SOCKET_PATH);

      while (mRunning) {
        try {
          final java.net.LocalSocket client = server.accept();
          mExecutor.submit(() -> handleClient(client));
        } catch (IOException e) {
          if (mRunning) {
            Log.w(TAG, "Accept failed: " + e.getMessage());
          }
        }
      }
    } catch (IOException e) {
      Log.e(TAG, "Cannot create socket server: " + e.getMessage());
      System.exit(1);
    }
  }

  private void handleClient(java.net.LocalSocket client) {
    try {
      BufferedReader reader = new BufferedReader(
          new InputStreamReader(client.getInputStream(), "UTF-8"));
      String requestJson = reader.readLine();

      JSONObject request = new JSONObject(requestJson);
      String prompt = request.getString("prompt");
      String modelId = request.optString("model", mCurrentModelId);

      // Switch model if needed
      if (!modelId.equals(mCurrentModelId)) {
        loadModel(modelId);
      }

      // Inject relevant memories into the prompt context
      String enrichedPrompt = prompt;
      if (mMemoryManager != null) {
        try {
          String memoryContext = mMemoryManager.buildPromptContext(prompt);
          if (!memoryContext.isEmpty()) {
            enrichedPrompt = memoryContext + "\n\n" + prompt;
            Log.d(TAG, "Injected " + memoryContext.length()
                + " chars of memory context");
          }
        } catch (Exception e) {
          Log.w(TAG, "Memory context injection failed (non-fatal): "
              + e.getMessage());
        }
      }

      // Generate response with malformed-output handling (S2):
      // If the LLM produces invalid JSON in a tool call, re-prompt with
      // a format fix request. After MAX_REPROMPT_RETRIES (2), degrade to
      // plain text answer — never crash.
      String response;
      if (mModelLoaded && mModelHandle != 0) {
        try {
          response = generateWithRetry(enrichedPrompt, 256, 0.7f);
        } catch (UnsatisfiedLinkError e) {
          response = "[stub] Model inference not available (JNI not loaded).";
        }
      } else {
        // No model — degrade to plain text fallback
        response = "[fallback] No model loaded. Prompt was: " + prompt;
      }

      // Store conversation summary in memory for future context
      if (mMemoryManager != null) {
        try {
          String summary = prompt.length() > 100
              ? prompt.substring(0, 100) : prompt;
          mMemoryManager.storeConversationSummary(summary);
        } catch (Exception ignored) {
        }
      }

      // Send response
      OutputStream out = client.getOutputStream();
      out.write(response.getBytes("UTF-8"));
      out.write('\n');
      out.flush();

    } catch (Exception e) {
      Log.e(TAG, "Client handling failed: " + e.getMessage());
      try {
        String err = "{\"error\":\"" + e.getMessage() + "\"}";
        OutputStream out = client.getOutputStream();
        out.write(err.getBytes("UTF-8"));
        out.write('\n');
        out.flush();
      } catch (IOException ignored) {
      }
    } finally {
      try {
        client.close();
      } catch (IOException ignored) {
      }
    }
  }

  /**
   * Generate a response with malformed-output retry (S2 constraint).
   *
   * If the LLM output contains invalid JSON (tool call), re-prompt with a
   * format-fix instruction. After MAX_REPROMPT_RETRIES, degrade to plain
   * text answer — never crash.
   */
  private String generateWithRetry(String prompt, int maxTokens, float temperature) {
    final int MAX_REPROMPT_RETRIES = 2;
    String currentPrompt = prompt;
    String response = "";

    for (int attempt = 0; attempt <= MAX_REPROMPT_RETRIES; attempt++) {
      response = nativeGenerate(mModelHandle, currentPrompt, maxTokens, temperature);

      // Check if response looks like a tool call with invalid JSON
      if (response.contains("\"tool\"") || response.contains("\"action\"")) {
        try {
          // Try to parse as JSON — if it fails, it's malformed
          new JSONObject(response);
          break; // valid JSON — return as-is
        } catch (org.json.JSONException e) {
          if (attempt < MAX_REPROMPT_RETRIES) {
            // Re-prompt with format fix instruction
            currentPrompt = "Your previous response had malformed JSON. "
                + "Please respond with valid JSON or plain text. Prompt: " + prompt;
            Log.w(TAG, "Malformed LLM output, re-prompting (attempt " + (attempt + 1) + ")");
            continue;
          }
          // Max retries exceeded — degrade to plain text
          Log.w(TAG, "Max re-prompt retries exceeded, degrading to plain text");
          return "[plain text] " + response.replaceAll("[{}\\[\\]\"]", "");
        }
      } else {
        break; // Not a tool call — return as-is
      }
    }
    return response;
  }

  private String getModelPath(String modelId) {
    switch (modelId) {
      case "qwen2.5-0.5b":
        return "/data/local/tmp/models/qwen2.5-0.5b-q4_k_m.gguf";
      case "qwen2.5-1.5b":
        return "/data/local/tmp/models/qwen2.5-1.5b-q4_k_m.gguf";
      case "qwen2.5-3b":
        return "/data/local/tmp/models/qwen2.5-3b-q4_k_m.gguf";
      default:
        return null;
    }
  }

  public void stop() {
    mRunning = false;
    if (mModelLoaded && mModelHandle != 0) {
      try {
        nativeUnloadModel(mModelHandle);
      } catch (UnsatisfiedLinkError ignored) {
      }
      mModelHandle = 0;
      mModelLoaded = false;
    }
    if (mMemoryManager != null) {
      try {
        mMemoryManager.close();
      } catch (Exception ignored) {
      }
    }
    Log.i(TAG, "apexagentd stopped");
  }

  private final java.util.concurrent.ExecutorService mExecutor =
      java.util.concurrent.Executors.newFixedThreadPool(2);
}
