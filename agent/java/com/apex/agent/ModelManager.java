/*
 * ModelManager.java
 *
 * Manages model lifecycle: loading, unloading, tier switching, and
 * memory-pressure-aware degradation.
 *
 * Runs inside apexagentd (NOT system_server). The daemon uses this
 * to manage the llama.cpp model handle via JNI.
 *
 * Thread safety: all model operations are synchronized on mLock.
 */

package com.apex.agent;

import android.util.Log;

import java.io.File;
import java.util.LinkedHashMap;
import java.util.Map;

public class ModelManager {
  private static final String TAG = "ModelManager";

  // Model tier constants
  public static final String TIER_FALLBACK = "qwen2.5-0.5b";
  public static final String TIER_DEFAULT = "qwen2.5-1.5b";
  public static final String TIER_HIGH = "qwen2.5-3b";

  // Remote model tier (OmniRoute-compatible) — opt-in per request
  public static final String TIER_REMOTE = "remote-omniroute";
  private static final String REMOTE_DEFAULT_URL = "http://127.0.0.1:20128/v1/chat/completions";
  private static final String REMOTE_DEFAULT_MODEL = "qwen2.5-7b";
  private String mRemoteEndpoint = REMOTE_DEFAULT_URL;
  private String mRemoteModel = REMOTE_DEFAULT_MODEL;

  // Model storage path
  private static final String MODEL_DIR = "/data/local/tmp/models";

  // Thread count for inference (A73 cluster)
  private static final int INFERENCE_THREADS = 4;

  private final Object mLock = new Object();
  private long mModelHandle = 0;
  private String mCurrentTier = null;
  private boolean mJniAvailable = false;
  private int mActiveThreads = INFERENCE_THREADS;

  // Model metadata
  private static final Map<String, ModelInfo> MODELS = new LinkedHashMap<>();
  static {
    MODELS.put(TIER_FALLBACK, new ModelInfo(
        TIER_FALLBACK, "Qwen 2.5 0.5B Q4_K_M",
        MODEL_DIR + "/qwen2.5-0.5b-q4_k_m.gguf",
        500, 600, "15-20"));
    MODELS.put(TIER_DEFAULT, new ModelInfo(
        TIER_DEFAULT, "Qwen 2.5 1.5B Q4_K_M",
        MODEL_DIR + "/qwen2.5-1.5b-q4_k_m.gguf",
        1100, 1500, "5-10"));
    MODELS.put(TIER_HIGH, new ModelInfo(
        TIER_HIGH, "Qwen 2.5 3B Q4_K_M",
        MODEL_DIR + "/qwen2.5-3b-q4_k_m.gguf",
        2200, 3300, "3-5"));
    // Remote model entry — no local file, runtime depends on network
    MODELS.put(TIER_REMOTE, new ModelInfo(
        TIER_REMOTE, "Remote (OmniRoute)",
        null, 0, 0, "network-dependent"));
  }

  public ModelManager() {
    try {
      System.loadLibrary("llm_jni");
      mJniAvailable = true;
      Log.i(TAG, "JNI available — native inference enabled");
    } catch (UnsatisfiedLinkError e) {
      mJniAvailable = false;
      Log.w(TAG, "JNI not available — stub mode only");
    }
  }

  /**
   * Load a model tier. Unloads the previous model first.
   * Returns true on success, false on failure.
   */
  public boolean loadTier(String tier) {
    synchronized (mLock) {
      // Already loaded?
      if (tier.equals(mCurrentTier) && mModelHandle != 0) {
        return true;
      }

      ModelInfo info = MODELS.get(tier);
      if (info == null) {
        Log.e(TAG, "Unknown tier: " + tier);
        return false;
      }

      // Check if model file exists
      File modelFile = new File(info.path);
      if (!modelFile.exists()) {
        Log.e(TAG, "Model file not found: " + info.path);
        return false;
      }

      // Unload previous
      if (mModelHandle != 0) {
        unloadCurrent();
      }

      // Load via JNI
      if (TIER_REMOTE.equals(tier)) {
        // Remote model — no local loading needed, just mark as active
        mCurrentTier = tier;
        Log.i(TAG, "Remote model tier selected: " + mRemoteEndpoint + " model=" + mRemoteModel);
        return true;
      }
      if (mJniAvailable) {
        try {
          mModelHandle = nativeLoadModel(info.path, mActiveThreads);
          if (mModelHandle != 0) {
            mCurrentTier = tier;
            Log.i(TAG, "Loaded: " + info.displayName +
                " (handle=" + mModelHandle + ")");
            return true;
          } else {
            Log.e(TAG, "nativeLoadModel returned 0 for " + tier);
            return false;
          }
        } catch (UnsatisfiedLinkError e) {
          Log.w(TAG, "JNI call failed: " + e.getMessage());
          mJniAvailable = false;
        }
      }

      // Stub mode
      mCurrentTier = tier;
      Log.w(TAG, "Loaded in stub mode: " + info.displayName);
      return true;
    }
  }

  /**
   * Unload the current model and free memory.
   */
  public void unloadCurrent() {
    synchronized (mLock) {
      if (mModelHandle != 0 && mJniAvailable) {
        try {
          nativeUnloadModel(mModelHandle);
        } catch (UnsatisfiedLinkError ignored) {
        }
      }
      mModelHandle = 0;
      mCurrentTier = null;
      Log.i(TAG, "Model unloaded");
    }
  }

  /**
   * Generate text using the current model.
   * Returns generated text or error message.
   */
  public String generate(String prompt, int maxTokens, float temperature) {
    synchronized (mLock) {
      if (mModelHandle == 0 || !mJniAvailable) {
        return "[stub] No model loaded. Prompt: " + prompt;
      }
      try {
        return nativeGenerate(mModelHandle, prompt, maxTokens, temperature);
      } catch (UnsatisfiedLinkError e) {
        Log.e(TAG, "JNI generate failed: " + e.getMessage());
        return "[error] Inference failed: " + e.getMessage();
      }
    }
  }

  /**
   * Get current tier identifier.
   */
  public String getCurrentTier() {
    synchronized (mLock) {
      return mCurrentTier;
    }
  }

  /**
   * Get current model info.
   */
  public ModelInfo getCurrentInfo() {
    synchronized (mLock) {
      if (mCurrentTier == null) return null;
      return MODELS.get(mCurrentTier);
    }
  }

  /**
   * Check if a model is loaded.
   */
  public boolean isLoaded() {
    synchronized (mLock) {
      return mCurrentTier != null;
    }
  }

  /**
   * Check if JNI (native inference) is available.
   */
  public boolean isJniAvailable() {
    return mJniAvailable;
  }

  /**
   * Get memory usage in MB.
   */
  public int getMemoryUsageMb() {
    synchronized (mLock) {
      if (mModelHandle == 0 || !mJniAvailable) return 0;
      try {
        return nativeGetMemoryUsage(mModelHandle);
      } catch (UnsatisfiedLinkError e) {
        return 0;
      }
    }
  }

  /**
   * Reduce thread count (thermal throttling).
   */
  public void reduceThreads(int count) {
    synchronized (mLock) {
      mActiveThreads = count;
      if (mModelHandle != 0 && mJniAvailable) {
        try {
          nativeSetThreadCount(mModelHandle, count);
        } catch (UnsatisfiedLinkError ignored) {
        }
      }
      Log.i(TAG, "Thread count reduced to " + count);
    }
  }

  /**
   * List all available model tiers.
   */
  public static Map<String, ModelInfo> getAvailableModels() {
    return MODELS;
  }

  /**
   * Check if a model file exists on disk.
   */
  public static boolean isModelAvailable(String tier) {
    ModelInfo info = MODELS.get(tier);
    if (info == null) return false;
    return new File(info.path).exists();
  }

  /**
   * Degrade to the next lower tier.
   * Returns the new tier, or null if already at lowest.
   */
  public String degrade() {
    synchronized (mLock) {
      if (TIER_HIGH.equals(mCurrentTier)) {
        loadTier(TIER_DEFAULT);
        return TIER_DEFAULT;
      } else if (TIER_DEFAULT.equals(mCurrentTier)) {
        loadTier(TIER_FALLBACK);
        return TIER_FALLBACK;
      }
      return null; // already at lowest
    }
  }

  // ── Model info data class ───────────────────────────────────────

  public static class ModelInfo {
    public final String id;
    public final String displayName;
    public final String path;
    public final int fileSizeMb;
    public final int runtimeRamMb;
    public final String throughputTokPerSec;

    public ModelInfo(String id, String displayName, String path,
                     int fileSizeMb, int runtimeRamMb,
                     String throughputTokPerSec) {
      this.id = id;
      this.displayName = displayName;
      this.path = path;
      this.fileSizeMb = fileSizeMb;
      this.runtimeRamMb = runtimeRamMb;
      this.throughputTokPerSec = throughputTokPerSec;
    }
  }

  // ── Remote model support (OmniRoute-compatible) ─────────────────

  /**
   * Configure the remote model endpoint.
   * @param endpoint URL of the OmniRoute-compatible API (e.g. http://127.0.0.1:20128/v1/chat/completions)
   * @param model    Model name to use on the remote endpoint
   */
  public void configureRemote(String endpoint, String model) {
    mRemoteEndpoint = endpoint;
    mRemoteModel = model;
    Log.i(TAG, "Remote configured: " + endpoint + " model=" + model);
  }

  /**
   * Generate a response using the remote model endpoint.
   * Falls back to local model on network failure.
   *
   * NOTE: Remote inference sends data off-device. The caller MUST verify
   * that the user has given explicit per-request consent for remote use.
   */
  public String generateRemote(String prompt, int maxTokens, float temperature) {
    if (!TIER_REMOTE.equals(mCurrentTier)) {
      Log.w(TAG, "Remote generation called but remote tier not active");
      return generateLocal(prompt, maxTokens, temperature);
    }
    try {
      java.net.URL url = new java.net.URL(mRemoteEndpoint);
      java.net.HttpURLConnection conn = (java.net.HttpURLConnection) url.openConnection();
      conn.setRequestMethod("POST");
      conn.setRequestProperty("Content-Type", "application/json");
      conn.setConnectTimeout(10000);
      conn.setReadTimeout(30000);

      // Build OpenAI-compatible request body
      org.json.JSONObject body = new org.json.JSONObject();
      body.put("model", mRemoteModel);
      org.json.JSONArray messages = new org.json.JSONArray();
      org.json.JSONObject msg = new org.json.JSONObject();
      msg.put("role", "user");
      msg.put("content", prompt);
      messages.put(msg);
      body.put("messages", messages);
      body.put("max_tokens", maxTokens);
      body.put("temperature", (double) temperature);
      body.put("stream", false);

      conn.setDoOutput(true);
      java.io.OutputStream os = conn.getOutputStream();
      os.write(body.toString().getBytes("UTF-8"));
      os.flush();
      os.close();

      int responseCode = conn.getResponseCode();
      if (responseCode != 200) {
        Log.w(TAG, "Remote returned " + responseCode + " — falling back to local");
        return generateLocal(prompt, maxTokens, temperature);
      }

      java.io.BufferedReader reader = new java.io.BufferedReader(
          new java.io.InputStreamReader(conn.getInputStream(), "UTF-8"));
      StringBuilder sb = new StringBuilder();
      String line;
      while ((line = reader.readLine()) != null) {
        sb.append(line);
      }
      reader.close();

      org.json.JSONObject response = new org.json.JSONObject(sb.toString());
      org.json.JSONArray choices = response.optJSONArray("choices");
      if (choices != null && choices.length() > 0) {
        org.json.JSONObject choice = choices.getJSONObject(0);
        org.json.JSONObject msgObj = choice.optJSONObject("message");
        if (msgObj != null) {
          return msgObj.optString("content", "");
        }
      }
      Log.w(TAG, "Remote response had no choices — falling back to local");
      return generateLocal(prompt, maxTokens, temperature);
    } catch (Exception e) {
      Log.w(TAG, "Remote generation failed: " + e.getMessage() + " — falling back to local");
      return generateLocal(prompt, maxTokens, temperature);
    }
  }

  /**
   * Generate using local JNI model (or stub if JNI unavailable).
   */
  public String generateLocal(String prompt, int maxTokens, float temperature) {
    synchronized (mLock) {
      if (mModelHandle == 0 || !mJniAvailable) {
        return "[stub] Model inference not available (JNI not loaded).";
      }
      try {
        return nativeGenerate(mModelHandle, prompt, maxTokens, temperature);
      } catch (UnsatisfiedLinkError e) {
        return "[stub] Model inference not available (JNI not loaded).";
      }
    }
  }

  /**
   * Check if the current tier is the remote model.
   */
  public boolean isRemoteTier() {
    return TIER_REMOTE.equals(mCurrentTier);
  }

  /**
   * Get the configured remote endpoint URL.
   */
  public String getRemoteEndpoint() {
    return mRemoteEndpoint;
  }

  // ── JNI method declarations ─────────────────────────────────────
  // These match the native methods in ApexAgentDaemon.java.
  // ModelManager calls them via its own native method declarations.

  private native long nativeLoadModel(String path, int nThreads);
  private native String nativeGenerate(long modelHandle, String prompt,
                                        int maxTokens, float temperature);
  private native void nativeUnloadModel(long modelHandle);
  private native int nativeGetMemoryUsage(long modelHandle);
  private native void nativeSetThreadCount(long modelHandle, int nThreads);
}
