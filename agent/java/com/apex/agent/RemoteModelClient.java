/*
 * RemoteModelClient.java
 *
 * HTTP client for remote model inference via OmniRoute-compatible API.
 * Runs inside the apex_remote_proxy process (separate SELinux domain
 * with network access). apexagentd communicates with this proxy via
 * a local Unix domain socket — apexagentd itself has no network access.
 *
 * Protocol (socket, newline-delimited JSON):
 *   Request:  {"prompt":"...","maxTokens":512,"temperature":0.7,"model":"qwen2.5-7b"}
 *   Response: {"ok":true,"text":"..."}  |  {"ok":false,"error":"..."}
 *
 * Security:
 *   - No prompt content is logged or persisted
 *   - Connection timeout: 10s, read timeout: 30s
 *   - Falls back to error response (not local model — that's the daemon's job)
 *   - Rate limited: max 10 concurrent requests
 */

package com.apex.agent;

import android.util.Log;

import java.io.BufferedReader;
import java.io.IOException;
import java.io.InputStreamReader;
import java.io.OutputStream;
import java.net.HttpURLConnection;
import java.net.URL;
import java.util.concurrent.Semaphore;
import java.util.concurrent.TimeUnit;

import org.json.JSONArray;
import org.json.JSONObject;

public class RemoteModelClient {
  private static final String TAG = "RemoteModelClient";
  private static final int CONNECT_TIMEOUT_MS = 10_000;
  private static final int READ_TIMEOUT_MS = 30_000;
  private static final int MAX_CONCURRENT = 10;

  private final Semaphore mRateLimiter = new Semaphore(MAX_CONCURRENT, true);
  private String mEndpoint;
  private String mDefaultModel;

  public RemoteModelClient(String endpoint, String model) {
    mEndpoint = endpoint;
    mDefaultModel = model;
  }

  public void configure(String endpoint, String model) {
    mEndpoint = endpoint;
    mDefaultModel = model;
    Log.i(TAG, "Reconfigured: " + endpoint + " model=" + model);
  }

  /**
   * Send a chat completion request to the remote endpoint.
   * Returns the generated text, or an error message.
   */
  public String chat(String prompt, int maxTokens, float temperature, String modelOverride) {
    if (!mRateLimiter.tryAcquire()) {
      return "{\"ok\":false,\"error\":\"rate limited — too many concurrent requests\"}";
    }

    try {
      return doChat(prompt, maxTokens, temperature, modelOverride);
    } catch (Exception e) {
      Log.w(TAG, "Remote chat failed: " + e.getMessage());
      return "{\"ok\":false,\"error\":\"" + escapeJson(e.getMessage()) + "\"}";
    } finally {
      mRateLimiter.release();
    }
  }

  private String doChat(String prompt, int maxTokens, float temperature,
                         String modelOverride) throws Exception {
    String model = (modelOverride != null && !modelOverride.isEmpty())
        ? modelOverride : mDefaultModel;

    URL url = new URL(mEndpoint);
    HttpURLConnection conn = (HttpURLConnection) url.openConnection();
    conn.setRequestMethod("POST");
    conn.setRequestProperty("Content-Type", "application/json");
    conn.setRequestProperty("User-Agent", "APEX-Agent/1.0");
    conn.setConnectTimeout(CONNECT_TIMEOUT_MS);
    conn.setReadTimeout(READ_TIMEOUT_MS);

    // Build OpenAI-compatible request body
    JSONObject body = new JSONObject();
    body.put("model", model);
    JSONArray messages = new JSONArray();
    JSONObject msg = new JSONObject();
    msg.put("role", "user");
    msg.put("content", prompt);
    messages.put(msg);
    body.put("messages", messages);
    body.put("max_tokens", maxTokens);
    body.put("temperature", (double) temperature);
    body.put("stream", false);

    conn.setDoOutput(true);
    OutputStream os = conn.getOutputStream();
    os.write(body.toString().getBytes("UTF-8"));
    os.flush();
    os.close();

    int responseCode = conn.getResponseCode();
    if (responseCode != 200) {
      String errorBody = readStream(conn.getErrorStream());
      return "{\"ok\":false,\"error\":\"HTTP " + responseCode
          + ": " + escapeJson(errorBody) + "\"}";
    }

    String responseBody = readStream(conn.getInputStream());
    JSONObject response = new JSONObject(responseBody);
    JSONArray choices = response.optJSONArray("choices");
    if (choices != null && choices.length() > 0) {
      JSONObject choice = choices.getJSONObject(0);
      JSONObject msgObj = choice.optJSONObject("message");
      if (msgObj != null) {
        String content = msgObj.optString("content", "");
        return "{\"ok\":true,\"text\":\"" + escapeJson(content) + "\"}";
      }
    }
    return "{\"ok\":false,\"error\":\"no choices in response\"}";
  }

  private String readStream(java.io.InputStream is) throws IOException {
    if (is == null) return "";
    BufferedReader reader = new BufferedReader(new InputStreamReader(is, "UTF-8"));
    StringBuilder sb = new StringBuilder();
    String line;
    while ((line = reader.readLine()) != null) {
      sb.append(line);
    }
    reader.close();
    return sb.toString();
  }

  private static String escapeJson(String s) {
    if (s == null) return "";
    return s.replace("\\", "\\\\")
        .replace("\"", "\\\"")
        .replace("\n", "\\n")
        .replace("\r", "\\r")
        .replace("\t", "\\t");
  }
}
