package com.apex.control.agent

import com.apex.control.data.BridgeClient
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.withContext
import org.json.JSONObject
import org.json.JSONException

/**
 * Repository for agent-related operations.
 *
 * Communicates with the APEX agent service via the bridge client.
 * In production, this would use the IApexAgent AIDL binder directly,
 * but the bridge client provides a fallback path via the existing
 * socket/procfs infrastructure.
 */
class AgentRepository(private val client: BridgeClient = BridgeClient()) {

  /**
   * Send a chat message to the agent and return the response state.
   */
  suspend fun sendChat(message: String): ChatState = withContext(Dispatchers.IO) {
    try {
      val response = client.sendCommand("agent chat $message")
      parseChatResponse(response)
    } catch (e: Exception) {
      ChatState.Error(e.message ?: "Unknown error")
    }
  }

  /**
   * Send a chat message with a specific model tier.
   */
  suspend fun sendChatWithModel(message: String, modelId: String): ChatState =
    withContext(Dispatchers.IO) {
      try {
        val response = client.sendCommand("agent chat $message model $modelId")
        parseChatResponse(response)
      } catch (e: Exception) {
        ChatState.Error(e.message ?: "Unknown error")
      }
    }

  /**
   * Get the current agent status.
   */
  suspend fun getAgentStatus(): AgentStatus = withContext(Dispatchers.IO) {
    try {
      val raw = client.sendCommand("agent status")
      parseAgentStatus(raw)
    } catch (e: Exception) {
      AgentStatus(
        daemonRunning = false,
        currentModel = "",
        loadedModelSizeMb = 0,
        tokensPerSecond = 0f,
        fallbackMode = true,
      )
    }
  }

  /**
   * Set the model tier (no reboot required).
   */
  suspend fun setModelTier(tierId: String): Boolean = withContext(Dispatchers.IO) {
    val result = client.sendCommand("agent set_model $tierId")
    !result.startsWith("ERROR")
  }

  /**
   * List available models.
   */
  suspend fun listModels(): List<ModelInfo> = withContext(Dispatchers.IO) {
    try {
      val raw = client.sendCommand("agent list_models")
      parseModelList(raw)
    } catch (e: Exception) {
      ModelTiers.ALL
    }
  }

  /**
   * Get consent audit log entries.
   */
  suspend fun getAuditLog(limit: Int = 50): List<AuditLogEntry> = withContext(Dispatchers.IO) {
    try {
      val raw = client.sendCommand("agent audit_log $limit")
      parseAuditLog(raw)
    } catch (e: Exception) {
      emptyList()
    }
  }

  /**
   * Approve a pending consent request.
   */
  suspend fun approveConsent(toolName: String): Boolean = withContext(Dispatchers.IO) {
    val result = client.sendCommand("agent consent approve $toolName")
    !result.startsWith("ERROR")
  }

  /**
   * Deny a pending consent request.
   */
  suspend fun denyConsent(toolName: String): Boolean = withContext(Dispatchers.IO) {
    val result = client.sendCommand("agent consent deny $toolName")
    !result.startsWith("ERROR")
  }

  /**
   * Transcribe voice input via the agent's whisper.cpp JNI bridge.
   * Records audio from the microphone and returns the transcript.
   * Returns empty string on failure.
   */
  suspend fun transcribeVoice(): String = withContext(Dispatchers.IO) {
    try {
      val result = client.sendCommand("agent transcribe")
      val json = JSONObject(result)
      json.optString("transcript", "")
    } catch (e: Exception) {
      ""
    }
  }

  /**
   * Download a model.
   */
  suspend fun downloadModel(modelId: String): DownloadProgress = withContext(Dispatchers.IO) {
    try {
      val raw = client.sendCommand("agent download_model $modelId")
      parseDownloadProgress(raw)
    } catch (e: Exception) {
      DownloadProgress(
        modelId = modelId,
        state = DownloadState.FAILED,
        percent = 0,
        message = e.message ?: "Download failed",
      )
    }
  }

  /**
   * Get agent debug log entries (T8).
   */
  suspend fun getDebugLog(limit: Int = 100): List<DebugLogEntry> = withContext(Dispatchers.IO) {
    try {
      val raw = client.sendCommand("agent debug_log $limit")
      parseDebugLog(raw)
    } catch (e: Exception) {
      emptyList()
    }
  }

  // ── Parsing helpers ─────────────────────────────────────────────

  private fun parseChatResponse(raw: String): ChatState {
    return try {
      val json = JSONObject(raw)
      when (json.optString("state", "response")) {
        "processing" -> ChatState.Processing
        "consent" -> ChatState.ConsentRequested(
          toolName = json.optString("tool_name", ""),
          description = json.optString("description", ""),
          proposedAction = json.optString("proposed_action", ""),
        )
        "response" -> ChatState.Response(json.optString("text", ""))
        "error" -> ChatState.Error(json.optString("message", "Unknown error"))
        else -> ChatState.Response(raw)
      }
    } catch (e: JSONException) {
      ChatState.Response(raw)
    }
  }

  private fun parseAgentStatus(raw: String): AgentStatus {
    return try {
      val json = JSONObject(raw)
      AgentStatus(
        daemonRunning = json.optBoolean("daemon_running", false),
        currentModel = json.optString("current_model", ""),
        loadedModelSizeMb = json.optInt("loaded_model_size_mb", 0),
        tokensPerSecond = json.optDouble("tokens_per_second", 0.0).toFloat(),
        fallbackMode = json.optBoolean("fallback_mode", true),
      )
    } catch (e: JSONException) {
      AgentStatus(
        daemonRunning = false,
        currentModel = "",
        loadedModelSizeMb = 0,
        tokensPerSecond = 0f,
        fallbackMode = true,
      )
    }
  }

  private fun parseModelList(raw: String): List<ModelInfo> {
    return try {
      val json = JSONObject(raw)
      val arr = json.optJSONArray("models")
      if (arr != null) {
        (0 until arr.length()).map { i ->
          val m = arr.getJSONObject(i)
          ModelInfo(
            id = m.optString("id", ""),
            displayName = m.optString("display_name", ""),
            fileSizeMb = m.optInt("file_size_mb", 0),
            runtimeRamMb = m.optInt("runtime_ram_mb", 0),
            throughputTokPerSec = m.optString("throughput", ""),
            isAvailable = m.optBoolean("available", false),
            isDownloaded = m.optBoolean("downloaded", false),
          )
        }
      } else {
        ModelTiers.ALL
      }
    } catch (e: JSONException) {
      ModelTiers.ALL
    }
  }

  private fun parseAuditLog(raw: String): List<AuditLogEntry> {
    return try {
      val json = JSONObject(raw)
      val arr = json.optJSONArray("entries")
      if (arr != null) {
        (0 until arr.length()).map { i ->
          val e = arr.getJSONObject(i)
          AuditLogEntry(
            id = e.optLong("id", 0),
            timestamp = e.optString("timestamp", ""),
            toolName = e.optString("tool_name", ""),
            description = e.optString("description", ""),
            action = e.optString("action", ""),
            result = AuditResult.fromString(e.optString("result", "DENIED")),
            durationMs = e.optLong("duration_ms", 0),
          )
        }
      } else {
        emptyList()
      }
    } catch (e: JSONException) {
      emptyList()
    }
  }

  private fun parseDownloadProgress(raw: String): DownloadProgress {
    return try {
      val json = JSONObject(raw)
      DownloadProgress(
        modelId = json.optString("model_id", ""),
        state = DownloadState.fromString(json.optString("state", "idle")),
        percent = json.optInt("percent", 0),
        message = json.optString("message", ""),
      )
    } catch (e: JSONException) {
      DownloadProgress(
        modelId = "",
        state = DownloadState.FAILED,
        percent = 0,
        message = "Parse error: ${e.message}",
      )
    }
  }

  private fun parseDebugLog(raw: String): List<DebugLogEntry> {
    return try {
      val json = JSONObject(raw)
      val arr = json.optJSONArray("entries")
      if (arr != null) {
        (0 until arr.length()).map { i ->
          val e = arr.getJSONObject(i)
          DebugLogEntry(
            timestamp = e.optString("timestamp", ""),
            level = DebugLogLevel.fromString(e.optString("level", "INFO")),
            component = e.optString("component", ""),
            message = e.optString("message", ""),
          )
        }
      } else {
        emptyList()
      }
    } catch (e: JSONException) {
      emptyList()
    }
  }
}

// ── Supporting data classes ────────────────────────────────────────

data class AgentStatus(
  val daemonRunning: Boolean,
  val currentModel: String,
  val loadedModelSizeMb: Int,
  val tokensPerSecond: Float,
  val fallbackMode: Boolean,
)

data class DownloadProgress(
  val modelId: String,
  val state: DownloadState,
  val percent: Int,
  val message: String,
)

enum class DownloadState(val label: String) {
  IDLE("Idle"),
  DOWNLOADING("Downloading"),
  VERIFYING("Verifying"),
  COMPLETE("Complete"),
  FAILED("Failed"),
  ;

  companion object {
    fun fromString(s: String): DownloadState =
      entries.find { it.name.equals(s, ignoreCase = true) } ?: IDLE
  }
}

data class DebugLogEntry(
  val timestamp: String,
  val level: DebugLogLevel,
  val component: String,
  val message: String,
)

enum class DebugLogLevel(val label: String) {
  DEBUG("DEBUG"),
  INFO("INFO"),
  WARN("WARN"),
  ERROR("ERROR"),
  ;

  companion object {
    fun fromString(s: String): DebugLogLevel =
      entries.find { it.name.equals(s, ignoreCase = true) } ?: INFO
  }
}
