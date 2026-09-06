package com.apex.control.agent

import androidx.compose.foundation.layout.*
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.items
import androidx.compose.foundation.text.BasicTextField
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.filled.Send
import androidx.compose.material.icons.filled.Mic
import androidx.compose.material3.*
import androidx.compose.runtime.*
import androidx.compose.runtime.saveable.rememberSaveable
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.text.font.FontFamily
import androidx.compose.ui.unit.dp
import kotlinx.coroutines.launch

/**
 * Chat surface for the APEX agent.
 *
 * Shows:
 * - Message input field
 * - Processing state (spinner + "Thinking...")
 * - Consent request card (approve/deny buttons)
 * - Response text
 * - Error messages
 *
 * The consent card includes anti-phishing affordances (T5):
 * - Tool name displayed in monospace
 * - Description in plain language
 * - Proposed action shown verbatim
 * - 60s countdown timer
 * - Approve button is NOT highlighted (equal weight to deny)
 */
@Composable
fun AgentChatSurface(
  repository: AgentRepository = remember { AgentRepository() },
) {
  var input by rememberSaveable { mutableStateOf("") }
  var chatState by remember { mutableStateOf<ChatState>(ChatState.Idle) }
  var messages by remember { mutableStateOf(listOf<ChatMessage>()) }
  var consentCountdown by remember { mutableStateOf(60) }
  var isRecording by remember { mutableStateOf(false) }
  val scope = rememberCoroutineScope()

  Column(
    modifier = Modifier
      .fillMaxSize()
      .padding(16.dp),
    verticalArrangement = Arrangement.spacedBy(12.dp),
  ) {
    Text(
      text = "Agent Chat",
      style = MaterialTheme.typography.titleLarge,
    )

    // Agent status badge
    var status by remember { mutableStateOf<AgentStatus?>(null) }
    LaunchedEffect(Unit) {
      while (true) {
        status = repository.getAgentStatus()
        kotlinx.coroutines.delay(5000)
      }
    }
    if (status != null) {
      AgentStatusBadge(status!!)
    }

    // Message list
    LazyColumn(
      modifier = Modifier.weight(1f),
      verticalArrangement = Arrangement.spacedBy(8.dp),
    ) {
      items(messages) { msg ->
        ChatMessageBubble(msg)
      }
      // Current state card
      when (val state = chatState) {
        is ChatState.Processing -> item {
          Row(
            verticalAlignment = Alignment.CenterVertically,
            horizontalArrangement = Arrangement.spacedBy(8.dp),
          ) {
            CircularProgressIndicator(modifier = Modifier.size(20.dp), strokeWidth = 2.dp)
            Text("Thinking...", style = MaterialTheme.typography.bodyMedium)
          }
        }
        is ChatState.ConsentRequested -> item {
          ConsentCard(
            toolName = state.toolName,
            description = state.description,
            proposedAction = state.proposedAction,
            countdown = consentCountdown,
            onApprove = {
              scope.launch {
                repository.approveConsent(state.toolName)
                chatState = ChatState.Processing
              }
            },
            onDeny = {
              scope.launch {
                repository.denyConsent(state.toolName)
                chatState = ChatState.Idle
                messages = messages + ChatMessage(
                  text = "[Consent denied for ${state.toolName}]",
                  isUser = false,
                )
              }
            },
          )
        }
        is ChatState.Response -> item {
          ChatMessageBubble(ChatMessage(state.text, isUser = false))
          LaunchedEffect(state) {
            messages = messages + ChatMessage(state.text, isUser = false)
            chatState = ChatState.Idle
          }
        }
        is ChatState.Error -> item {
          Card(
            colors = CardDefaults.cardColors(
              containerColor = MaterialTheme.colorScheme.errorContainer,
            ),
          ) {
            Text(
              text = state.message,
              modifier = Modifier.padding(16.dp),
              style = MaterialTheme.typography.bodyMedium,
              color = MaterialTheme.colorScheme.onErrorContainer,
            )
          }
          LaunchedEffect(state) {
            chatState = ChatState.Idle
          }
        }
        ChatState.Idle -> { /* nothing */ }
      }
    }

    // Input row
    Row(
      modifier = Modifier.fillMaxWidth(),
      verticalAlignment = Alignment.CenterVertically,
      horizontalArrangement = Arrangement.spacedBy(8.dp),
    ) {
      OutlinedTextField(
        value = input,
        onValueChange = { input = it },
        modifier = Modifier.weight(1f),
        placeholder = { Text("Ask the agent...") },
        singleLine = true,
        enabled = chatState !is ChatState.Processing && !isRecording,
      )
      // Push-to-talk voice input button
      IconButton(
        onClick = {
          if (!isRecording) {
            isRecording = true
            scope.launch {
              // Start voice recording via agent service
              val transcript = repository.transcribeVoice()
              isRecording = false
              if (transcript.isNotBlank()) {
                input = transcript
              }
            }
          }
        },
        enabled = chatState !is ChatState.Processing && !isRecording,
      ) {
        Icon(
          Icons.Default.Mic,
          contentDescription = "Push to talk",
          tint = if (isRecording) {
            MaterialTheme.colorScheme.error
          } else {
            MaterialTheme.colorScheme.onSurface
          },
        )
      }
      IconButton(
        onClick = {
          if (input.isNotBlank() && chatState !is ChatState.Processing) {
            val userMsg = input
            messages = messages + ChatMessage(userMsg, isUser = true)
            input = ""
            chatState = ChatState.Processing
            scope.launch {
              chatState = repository.sendChat(userMsg)
            }
          }
        },
        enabled = input.isNotBlank() && chatState !is ChatState.Processing,
      ) {
        Icon(Icons.Default.Send, contentDescription = "Send")
      }
    }
  }
}

@Composable
private fun AgentStatusBadge(status: AgentStatus) {
  val color = if (status.fallbackMode) {
    MaterialTheme.colorScheme.tertiary
  } else {
    MaterialTheme.colorScheme.primary
  }
  val text = buildString {
    if (status.fallbackMode) append("FALLBACK")
    else if (status.daemonRunning) append("ONLINE")
    else append("OFFLINE")
    if (status.currentModel.isNotEmpty()) {
      append(" · ")
      append(status.currentModel)
    }
    if (status.tokensPerSecond > 0) {
      append(" · ")
      append(String.format("%.1f", status.tokensPerSecond))
      append(" tok/s")
    }
  }
  Text(
    text = text,
    style = MaterialTheme.typography.labelSmall,
    color = color,
    fontFamily = FontFamily.Monospace,
  )
}

@Composable
private fun ConsentCard(
  toolName: String,
  description: String,
  proposedAction: String,
  countdown: Int,
  onApprove: () -> Unit,
  onDeny: () -> Unit,
) {
  // Countdown timer
  LaunchedEffect(countdown) {
    if (countdown > 0) {
      kotlinx.coroutines.delay(1000)
      consentCountdown = countdown - 1
    }
  }
  var currentCountdown by remember { mutableStateOf(countdown) }
  LaunchedEffect(countdown) {
    currentCountdown = countdown
    while (currentCountdown > 0) {
      kotlinx.coroutines.delay(1000)
      currentCountdown--
    }
  }

  Card(
    modifier = Modifier.fillMaxWidth(),
    colors = CardDefaults.cardColors(
      containerColor = MaterialTheme.colorScheme.secondaryContainer,
    ),
  ) {
    Column(
      modifier = Modifier.padding(16.dp),
      verticalArrangement = Arrangement.spacedBy(8.dp),
    ) {
      Text("Consent Required", style = MaterialTheme.typography.titleMedium)

      // Anti-phishing: tool name in monospace, clearly labeled
      Text(
        text = "Tool: $toolName",
        style = MaterialTheme.typography.bodyMedium,
        fontFamily = FontFamily.Monospace,
      )

      // Plain language description
      Text(
        text = description,
        style = MaterialTheme.typography.bodyMedium,
      )

      // Proposed action shown verbatim
      HorizontalDivider()
      Text(
        text = "Action: $proposedAction",
        style = MaterialTheme.typography.bodySmall,
        fontFamily = FontFamily.Monospace,
        color = MaterialTheme.colorScheme.onSecondaryContainer,
      )

      // Countdown
      Text(
        text = "Auto-deny in ${currentCountdown}s",
        style = MaterialTheme.typography.labelSmall,
        color = if (currentCountdown <= 10) {
          MaterialTheme.colorScheme.error
        } else {
          MaterialTheme.colorScheme.onSecondaryContainer
        },
      )

      // Equal-weight buttons (anti-phishing: no highlighted approve)
      Row(
        modifier = Modifier.fillMaxWidth(),
        horizontalArrangement = Arrangement.spacedBy(8.dp),
      ) {
        OutlinedButton(
          onClick = onApprove,
          modifier = Modifier.weight(1f),
        ) { Text("Approve") }
        OutlinedButton(
          onClick = onDeny,
          modifier = Modifier.weight(1f),
        ) { Text("Deny") }
      }
    }
  }
}

@Composable
private fun ChatMessageBubble(msg: ChatMessage) {
  Row(
    modifier = Modifier.fillMaxWidth(),
    horizontalArrangement = if (msg.isUser) {
      Arrangement.End
    } else {
      Arrangement.Start
    },
  ) {
    Card(
      modifier = Modifier.widthIn(max = 280.dp),
      colors = CardDefaults.cardColors(
        containerColor = if (msg.isUser) {
          MaterialTheme.colorScheme.primaryContainer
        } else {
          MaterialTheme.colorScheme.surfaceVariant
        },
      ),
    ) {
      Text(
        text = msg.text,
        modifier = Modifier.padding(12.dp),
        style = MaterialTheme.typography.bodyMedium,
      )
    }
  }
}

// ── Chat message data class ────────────────────────────────────────

data class ChatMessage(
  val text: String,
  val isUser: Boolean,
)
