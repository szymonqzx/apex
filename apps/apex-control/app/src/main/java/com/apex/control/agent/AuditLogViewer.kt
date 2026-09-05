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
 * Audit Log Viewer — shows consent audit entries.
 *
 * The audit log is append-only, SELinux-protected, stored in SQLite
 * at /data/system/apex/consent_audit.db.
 */
@Composable
fun AuditLogViewer(
  repository: AgentRepository = remember { AgentRepository() },
) {
  var entries by remember { mutableStateOf<List<AuditLogEntry>>(emptyList()) }

  LaunchedEffect(Unit) {
    while (true) {
      entries = repository.getAuditLog(100)
      kotlinx.coroutines.delay(10000)
    }
  }

  Column(
    modifier = Modifier
      .fillMaxSize()
      .padding(16.dp),
    verticalArrangement = Arrangement.spacedBy(8.dp),
  ) {
    Text(
      text = "Consent Audit Log",
      style = MaterialTheme.typography.titleLarge,
    )
    Text(
      text = "Append-only · SELinux-protected · SQLite",
      style = MaterialTheme.typography.labelSmall,
      color = MaterialTheme.colorScheme.onSurfaceVariant,
    )

    HorizontalDivider()

    if (entries.isEmpty()) {
      Text(
        text = "No audit entries yet",
        style = MaterialTheme.typography.bodyMedium,
        color = MaterialTheme.colorScheme.onSurfaceVariant,
        modifier = Modifier.padding(16.dp),
      )
    } else {
      LazyColumn(
        verticalArrangement = Arrangement.spacedBy(4.dp),
      ) {
        items(entries) { entry ->
          AuditEntryCard(entry)
        }
      }
    }
  }
}

@Composable
private fun AuditEntryCard(entry: AuditLogEntry) {
  val resultColor = when (entry.result) {
    AuditResult.APPROVED -> MaterialTheme.colorScheme.primary
    AuditResult.DENIED -> MaterialTheme.colorScheme.error
    AuditResult.TIMEOUT -> MaterialTheme.colorScheme.tertiary
  }

  Card(
    modifier = Modifier.fillMaxWidth(),
    colors = CardDefaults.cardColors(
      containerColor = MaterialTheme.colorScheme.surfaceVariant,
    ),
  ) {
    Column(
      modifier = Modifier.padding(12.dp),
      verticalArrangement = Arrangement.spacedBy(2.dp),
    ) {
      Row(
        modifier = Modifier.fillMaxWidth(),
        horizontalArrangement = Arrangement.SpaceBetween,
      ) {
        Text(
          text = entry.toolName,
          style = MaterialTheme.typography.labelMedium,
          fontFamily = FontFamily.Monospace,
        )
        Text(
          text = entry.result.label,
          style = MaterialTheme.typography.labelMedium,
          color = resultColor,
        )
      }
      Text(
        text = entry.timestamp,
        style = MaterialTheme.typography.labelSmall,
        color = MaterialTheme.colorScheme.onSurfaceVariant,
        fontFamily = FontFamily.Monospace,
      )
      if (entry.description.isNotEmpty()) {
        Text(
          text = entry.description,
          style = MaterialTheme.typography.bodySmall,
        )
      }
      if (entry.action.isNotEmpty()) {
        Text(
          text = entry.action,
          style = MaterialTheme.typography.bodySmall,
          fontFamily = FontFamily.Monospace,
          color = MaterialTheme.colorScheme.onSurfaceVariant,
        )
      }
      Text(
        text = "${entry.durationMs}ms",
        style = MaterialTheme.typography.labelSmall,
        color = MaterialTheme.colorScheme.onSurfaceVariant,
      )
    }
  }
}
