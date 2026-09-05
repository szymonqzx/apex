package com.apex.control.agent

import androidx.compose.foundation.layout.*
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.items
import androidx.compose.material3.*
import androidx.compose.runtime.*
import androidx.compose.ui.Modifier
import androidx.compose.ui.text.font.FontFamily
import androidx.compose.ui.unit.dp

/**
 * Agent Debug Log Viewer (T8).
 *
 * Shows structured debug log entries from apexagentd.
 * Separate from the consent audit log — this is for engineering
 * diagnostics, not user-facing audit.
 */
@Composable
fun AgentDebugLogViewer(
  repository: AgentRepository = remember { AgentRepository() },
) {
  var entries by remember { mutableStateOf<List<DebugLogEntry>>(emptyList()) }

  LaunchedEffect(Unit) {
    while (true) {
      entries = repository.getDebugLog(200)
      kotlinx.coroutines.delay(5000)
    }
  }

  Column(
    modifier = Modifier
      .fillMaxSize()
      .padding(16.dp),
    verticalArrangement = Arrangement.spacedBy(8.dp),
  ) {
    Text(
      text = "Agent Debug Log",
      style = MaterialTheme.typography.titleLarge,
    )
    Text(
      text = "Engineering diagnostics · auto-refresh 5s",
      style = MaterialTheme.typography.labelSmall,
      color = MaterialTheme.colorScheme.onSurfaceVariant,
    )

    HorizontalDivider()

    if (entries.isEmpty()) {
      Text(
        text = "No debug entries",
        style = MaterialTheme.typography.bodyMedium,
        color = MaterialTheme.colorScheme.onSurfaceVariant,
        modifier = Modifier.padding(16.dp),
      )
    } else {
      LazyColumn(
        verticalArrangement = Arrangement.spacedBy(2.dp),
      ) {
        items(entries) { entry ->
          DebugLogLine(entry)
        }
      }
    }
  }
}

@Composable
private fun DebugLogLine(entry: DebugLogEntry) {
  val color = when (entry.level) {
    DebugLogLevel.DEBUG -> MaterialTheme.colorScheme.onSurfaceVariant
    DebugLogLevel.INFO -> MaterialTheme.colorScheme.primary
    DebugLogLevel.WARN -> MaterialTheme.colorScheme.tertiary
    DebugLogLevel.ERROR -> MaterialTheme.colorScheme.error
  }

  Text(
    text = "${entry.timestamp} ${entry.level.label.padEnd(5)} [${entry.component}] ${entry.message}",
    style = MaterialTheme.typography.labelSmall,
    fontFamily = FontFamily.Monospace,
    color = color,
    modifier = Modifier.padding(vertical = 1.dp),
  )
}
