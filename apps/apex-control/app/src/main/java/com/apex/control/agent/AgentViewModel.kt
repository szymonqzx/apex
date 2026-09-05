package com.apex.control.agent

import android.util.Log
import androidx.lifecycle.ViewModel
import androidx.lifecycle.viewModelScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asStateFlow
import kotlinx.coroutines.launch
import kotlinx.coroutines.withContext

/**
 * AgentViewModel — connects Apex Control UI to the IApexAgent binder service.
 *
 * Manages:
 * - Chat state (idle, processing, consent-pending, response)
 * - Model tier selection (nano, small, medium, remote)
 * - Audit log retrieval
 * - Debug log retrieval
 * - Agent status polling
 *
 * The ViewModel survives configuration changes and owns the coroutine scope.
 * The UI observes StateFlows and reacts to state changes.
 */
class AgentViewModel : ViewModel() {

  private val TAG = "AgentViewModel"

  // ── Chat state ──────────────────────────────────────────────────

  private val _chatState = MutableStateFlow<ChatState>(ChatState.Idle)
  val chatState: StateFlow<ChatState> = _chatState.asStateFlow()

  private val _chatHistory = MutableStateFlow<List<ChatMessage>>(emptyList())
  val chatHistory: StateFlow<List<ChatMessage>> = _chatHistory.asStateFlow()

  // ── Model state ─────────────────────────────────────────────────

  private val _currentTier = MutableStateFlow("small")
  val currentTier: StateFlow<String> = _currentTier.asStateFlow()

  private val _availableModels = MutableStateFlow<List<ModelInfo>>(emptyList())
  val availableModels: StateFlow<List<ModelInfo>> = _availableModels.asStateFlow()

  private val _modelDownloadProgress = MutableStateFlow<Map<String, Float>>(emptyMap())
  val modelDownloadProgress: StateFlow<Map<String, Float>> = _modelDownloadProgress.asStateFlow()

  // ── Audit log ───────────────────────────────────────────────────

  private val _auditLog = MutableStateFlow<List<AuditLogEntry>>(emptyList())
  val auditLog: StateFlow<List<AuditLogEntry>> = _auditLog.asStateFlow()

  // ── Debug log ───────────────────────────────────────────────────

  private val _debugLog = MutableStateFlow("")
  val debugLog: StateFlow<String> = _debugLog.asStateFlow()

  // ── Agent status ────────────────────────────────────────────────

  private val _agentStatus = MutableStateFlow<AgentStatus?>(null)
  val agentStatus: StateFlow<AgentStatus?> = _agentStatus.asStateFlow()

  // ── Consent ─────────────────────────────────────────────────────

  private val _pendingConsent = MutableStateFlow<ConsentRequest?>(null)
  val pendingConsent: StateFlow<ConsentRequest?> = _pendingConsent.asStateFlow()

  private var agentRepository: AgentRepository? = null

  /**
   * Initialize the ViewModel with the agent repository.
   * Called when the Apex Control app binds to the IApexAgent service.
   */
  fun initialize(repo: AgentRepository) {
    agentRepository = repo
    refreshStatus()
    refreshModels()
    refreshAuditLog()
  }

  /**
   * Send a chat prompt to the agent.
   * Updates chat state through processing → response (or consent-pending).
   */
  fun sendPrompt(prompt: String) {
    if (prompt.isBlank()) return

    _chatState.value = ChatState.Processing
    _chatHistory.value = _chatHistory.value + ChatMessage.user(prompt)

    viewModelScope.launch {
      try {
        val response = withContext(Dispatchers.IO) {
          agentRepository?.chat(prompt) ?: "[error] Agent not connected"
        }

        // Check if response contains a consent request
        if (response.startsWith("[consent]")) {
          _chatState.value = ChatState.ConsentPending(
              toolName = response.substringAfter("[consent] ").substringBefore(" "),
              description = response.substringAfter("description=").substringBefore(";"),
              action = response.substringAfter("action=").substringBefore(";")
          )
        } else {
          _chatHistory.value = _chatHistory.value + ChatMessage.assistant(response)
          _chatState.value = ChatState.Idle
        }
      } catch (e: Exception) {
        Log.e(TAG, "Chat failed: ${e.message}")
        _chatHistory.value = _chatHistory.value + ChatMessage.error(e.message ?: "Unknown error")
        _chatState.value = ChatState.Idle
      }
    }
  }

  /**
   * Approve a pending consent request.
   */
  fun approveConsent() {
    val state = _chatState.value
    if (state is ChatState.ConsentPending) {
      viewModelScope.launch {
        withContext(Dispatchers.IO) {
          agentRepository?.approveConsent(state.toolName, state.action)
        }
        _pendingConsent.value = null
        _chatState.value = ChatState.Processing
      }
    }
  }

  /**
   * Deny a pending consent request.
   */
  fun denyConsent() {
    val state = _chatState.value
    if (state is ChatState.ConsentPending) {
      viewModelScope.launch {
        withContext(Dispatchers.IO) {
          agentRepository?.denyConsent(state.toolName, state.action)
        }
        _pendingConsent.value = null
        _chatHistory.value = _chatHistory.value + ChatMessage.assistant("[denied] Tool call denied by user.")
        _chatState.value = ChatState.Idle
      }
    }
  }

  /**
   * Switch the model tier. Valid: "nano", "small", "medium", "remote".
   */
  fun setModelTier(tier: String) {
    viewModelScope.launch {
      withContext(Dispatchers.IO) {
        agentRepository?.setModelTier(tier)
      }
      _currentTier.value = tier
      refreshStatus()
    }
  }

  /**
   * Download a model. Updates progress flow.
   */
  fun downloadModel(modelId: String) {
    viewModelScope.launch {
      withContext(Dispatchers.IO) {
        agentRepository?.downloadModel(modelId) { progress ->
          _modelDownloadProgress.value = _modelDownloadProgress.value + (modelId to progress)
        }
      }
      _modelDownloadProgress.value = _modelDownloadProgress.value - modelId
      refreshModels()
    }
  }

  /**
   * Refresh agent status from the binder service.
   */
  fun refreshStatus() {
    viewModelScope.launch {
      val status = withContext(Dispatchers.IO) {
        agentRepository?.getStatus()
      }
      _agentStatus.value = status
    }
  }

  /**
   * Refresh available models from the binder service.
   */
  fun refreshModels() {
    viewModelScope.launch {
      val models = withContext(Dispatchers.IO) {
        agentRepository?.listModels() ?: emptyList()
      }
      _availableModels.value = models
    }
  }

  /**
   * Refresh the audit log.
   */
  fun refreshAuditLog() {
    viewModelScope.launch {
      val entries = withContext(Dispatchers.IO) {
        agentRepository?.getAuditLog(50) ?: emptyList()
      }
      _auditLog.value = entries
    }
  }

  /**
   * Refresh the debug log.
   */
  fun refreshDebugLog() {
    viewModelScope.launch {
      val log = withContext(Dispatchers.IO) {
        agentRepository?.getDebugLog() ?: ""
      }
      _debugLog.value = log
    }
  }

  /**
   * Clear chat history.
   */
  fun clearChat() {
    _chatHistory.value = emptyList()
    _chatState.value = ChatState.Idle
  }

  override fun onCleared() {
    super.onCleared()
    agentRepository?.unbind()
  }
}

// ── Data classes for the ViewModel ────────────────────────────────

data class ChatMessage(
    val role: String,
    val content: String,
    val timestamp: Long = System.currentTimeMillis()
) {
  companion object {
    fun user(text: String) = ChatMessage("user", text)
    fun assistant(text: String) = ChatMessage("assistant", text)
    fun error(text: String) = ChatMessage("error", text)
  }
}

data class AgentStatus(
    val daemonAlive: Boolean,
    val fallbackMode: Boolean,
    val currentTier: String,
    val modelLoaded: Boolean,
    val throughputTokPerSec: String,
    val memoryUsageMb: Int,
    val kernelDetected: Boolean
)

data class ConsentRequest(
    val toolName: String,
    val description: String,
    val action: String,
    val timestamp: Long = System.currentTimeMillis()
)
