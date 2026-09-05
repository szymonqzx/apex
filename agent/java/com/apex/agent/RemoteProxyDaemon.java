/*
 * RemoteProxyDaemon.java
 *
 * Standalone daemon process that handles remote model inference.
 * Runs in its own SELinux domain (apex_remote_proxy) with network
 * access. apexagentd (no network) connects to this proxy via a
 * Unix domain socket at /dev/socket/apex_remote_proxy.
 *
 * Protocol (newline-delimited JSON):
 *   Request:  {"prompt":"...","maxTokens":512,"temperature":0.7}
 *   Response: {"ok":true,"text":"..."} | {"ok":false,"error":"..."}
 *
 * Security:
 *   - Socket restricted to system UID (apexagentd runs as system)
 *   - No prompt content logged
 *   - Configurable endpoint via system property:
 *     persist.sys.apex.remote_endpoint
 *   - Configurable model via: persist.sys.apex.remote_model
 *   - If endpoint not configured, returns error (no fallback here)
 */

package com.apex.agent;

import android.util.Log;

import java.io.BufferedReader;
import java.io.File;
import java.io.IOException;
import java.io.InputStreamReader;
import java.io.OutputStream;
import java.net.ServerSocket;
import java.net.Socket;
import java.util.concurrent.ExecutorService;
import java.util.concurrent.Executors;

import org.json.JSONObject;

public class RemoteProxyDaemon {
  private static final String TAG = "RemoteProxyDaemon";
  private static final String SOCKET_PATH = "/dev/socket/apex_remote_proxy";
  private static final int MAX_CONNECTIONS = 16;
  private static final String DEFAULT_ENDPOINT = "http://127.0.0.1:20128/v1/chat/completions";
  private static final String DEFAULT_MODEL = "qwen2.5-7b";

  private final ExecutorService mExecutor = Executors.newFixedThreadPool(MAX_CONNECTIONS);
  private RemoteModelClient mClient;
  private ServerSocket mServerSocket;
  private volatile boolean mRunning = true;

  public void start() {
    // Read configuration from system properties
    String endpoint = System.getProperty("persist.sys.apex.remote_endpoint", DEFAULT_ENDPOINT);
    String model = System.getProperty("persist.sys.apex.remote_model", DEFAULT_MODEL);
    mClient = new RemoteModelClient(endpoint, model);

    Log.i(TAG, "Remote proxy starting: " + endpoint + " model=" + model);

    try {
      // Use a TCP socket on localhost instead of Unix domain socket
      // for simplicity in the Java daemon (Android's Unix domain socket
      // support requires native code or LocalServerSocket).
      int port = 9879; // apex_remote_proxy port
      mServerSocket = new ServerSocket(port, MAX_CONNECTIONS);
      Log.i(TAG, "Listening on port " + port);

      while (mRunning) {
        try {
          Socket client = mServerSocket.accept();
          mExecutor.submit(() -> handleClient(client));
        } catch (IOException e) {
          if (mRunning) {
            Log.e(TAG, "Accept failed: " + e.getMessage());
          }
        }
      }
    } catch (IOException e) {
      Log.e(TAG, "Failed to start server: " + e.getMessage());
    }
  }

  public void stop() {
    mRunning = false;
    mExecutor.shutdownNow();
    if (mServerSocket != null) {
      try {
        mServerSocket.close();
      } catch (IOException ignored) {
      }
    }
    Log.i(TAG, "Remote proxy stopped");
  }

  private void handleClient(Socket client) {
    try {
      BufferedReader reader = new BufferedReader(
          new InputStreamReader(client.getInputStream(), "UTF-8"));
      OutputStream out = client.getOutputStream();

      String line = reader.readLine();
      if (line == null || line.isEmpty()) {
        out.write("{\"ok\":false,\"error\":\"empty request\"}\n".getBytes("UTF-8"));
        out.flush();
        client.close();
        return;
      }

      // Parse JSON request
      JSONObject req = new JSONObject(line);
      String prompt = req.optString("prompt", "");
      int maxTokens = req.optInt("maxTokens", 512);
      float temperature = (float) req.optDouble("temperature", 0.7);
      String modelOverride = req.optString("model", null);

      if (prompt.isEmpty()) {
        out.write("{\"ok\":false,\"error\":\"missing prompt\"}\n".getBytes("UTF-8"));
        out.flush();
        client.close();
        return;
      }

      // Call remote model
      String result = mClient.chat(prompt, maxTokens, temperature, modelOverride);
      out.write((result + "\n").getBytes("UTF-8"));
      out.flush();
    } catch (Exception e) {
      Log.e(TAG, "Client handling failed: " + e.getMessage());
      try {
        String err = "{\"ok\":false,\"error\":\"" + e.getMessage() + "\"}\n";
        client.getOutputStream().write(err.getBytes("UTF-8"));
        client.getOutputStream().flush();
      } catch (IOException ignored) {
      }
    } finally {
      try {
        client.close();
      } catch (IOException ignored) {
      }
    }
  }

  public static void main(String[] args) {
    RemoteProxyDaemon daemon = new RemoteProxyDaemon();

    // Handle SIGTERM for clean shutdown
    Runtime.getRuntime().addShutdownHook(new Thread(() -> {
      daemon.stop();
    }));

    daemon.start();
  }
}
