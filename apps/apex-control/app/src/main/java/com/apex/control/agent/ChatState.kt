package com.apex.control.agent

/**
 * Sealed class hierarchy representing the states of an agent chat interaction.
 *
 * The UI observes these states to render the appropriate surface:
 * processing indicator, consent prompt, final response, or error.
 */
sealed class ChatState {
  /** Idle state — no active interaction. */
  object Idle : ChatState()

  /** The agent is processing the prompt; no user action needed. */
  object Processing : ChatState()

  /**
   * The agent requests user consent before executing a tool.
   *
   * @property toolName Fully qualified tool name (shown in monospace).
   * @property description Human-readable description of what the tool does.
   * @property proposedAction The exact action the tool will perform (shown in monospace).
   */
  data class ConsentRequested(
    val toolName: String,
    val description: String,
    val proposedAction: String,
  ) : ChatState()

  /** The agent produced a text response. */
  data class Response(val text: String) : ChatState()

  /** An error occurred during chat processing. */
  data class Error(val message: String) : ChatState()
}
