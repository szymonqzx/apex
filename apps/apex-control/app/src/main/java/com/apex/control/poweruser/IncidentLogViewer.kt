/*
 * IncidentLogViewer.kt
 *
 * Apex Control screen for viewing the APEX incident log.
 * Reads /persist/apex/incidents.log and displays crash history,
 * watchdog events, and safe-mode triggers.
 *
 * Log format (one entry per line):
 *   [timestamp] [severity] [source] message
 *
 * Severities: INFO, WARN, ERROR, CRITICAL
 * Sources: watchdog, kernel, agent, bridge, thermald, safe_mode
 */

package com.apex.control.poweruser

import androidx.compose.foundation.layout.*
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.items
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.verticalScroll
import androidx.compose.material3.*
import androidx.compose.runtime.*
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.text.font.FontFamily
import androidx.compose.ui.unit.dp
import androidx.lifecycle.ViewModel
import androidx.lifecycle.viewModelScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.launch

data class IncidentEntry(
    val timestamp: String,
    val severity: String,
    val source: String,
    val message: String
)

class IncidentLogViewModel : ViewModel() {
    var incidents by mutableStateOf<List<IncidentEntry>>(emptyList())
        private set
    var isLoading by mutableStateOf(false)
        private set
    var filterSeverity by mutableStateOf("")
        private set

    fun loadLog() {
        viewModelScope.launch(Dispatchers.IO) {
            isLoading = true
            try {
                val raw = java.io.File("/persist/apex/incidents.log").readText()
                incidents = parseLog(raw)
            } catch (e: Exception) {
                // File might not exist yet
                incidents = emptyList()
            }
            isLoading = false
        }
    }

    fun setFilter(severity: String) {
        filterSeverity = severity
    }

    val filteredIncidents: List<IncidentEntry>
        get() = if (filterSeverity.isEmpty()) incidents
                else incidents.filter { it.severity == filterSeverity }

    private fun parseLog(raw: String): List<IncidentEntry> {
        return raw.lines()
            .filter { it.isNotBlank() }
            .map { line ->
                // Parse: [timestamp] [severity] [source] message
                val regex = Regex("""\[([^\]]+)\]\s*\[([^\]]+)\]\s*\[([^\]]+)\]\s*(.*)""")
                val match = regex.find(line)
                if (match != null) {
                    IncidentEntry(
                        timestamp = match.groupValues[1],
                        severity = match.groupValues[2],
                        source = match.groupValues[3],
                        message = match.groupValues[4]
                    )
                } else {
                    IncidentEntry("", "INFO", "unknown", line)
                }
            }
            .reversed() // newest first
    }
}

@Composable
fun IncidentLogViewer(viewModel: IncidentLogViewModel = androidx.lifecycle.viewmodel.compose.viewModel()) {
    LaunchedEffect(Unit) { viewModel.loadLog() }

    Column(
        modifier = Modifier
            .fillMaxSize()
            .padding(16.dp)
    ) {
        Text("Incident Log", style = MaterialTheme.typography.headlineMedium)
        Spacer(modifier = Modifier.height(8.dp))
        Text(
            "Crash history, watchdog events, and safe-mode triggers.",
            style = MaterialTheme.typography.bodyMedium,
            color = MaterialTheme.colorScheme.onSurfaceVariant
        )
        Spacer(modifier = Modifier.height(12.dp))

        // Filter chips
        Row(
            modifier = Modifier.fillMaxWidth(),
            horizontalArrangement = Arrangement.spacedBy(8.dp)
        ) {
            FilterChip(
                selected = viewModel.filterSeverity.isEmpty(),
                onClick = { viewModel.setFilter("") },
                label = { Text("All") }
            )
            listOf("INFO", "WARN", "ERROR", "CRITICAL").forEach { sev ->
                FilterChip(
                    selected = viewModel.filterSeverity == sev,
                    onClick = { viewModel.setFilter(sev) },
                    label = { Text(sev) }
                )
            }
        }

        Spacer(modifier = Modifier.height(12.dp))

        if (viewModel.isLoading) {
            CircularProgressIndicator(modifier = Modifier.align(Alignment.CenterHorizontally))
        } else if (viewModel.filteredIncidents.isEmpty()) {
            Text(
                "No incidents recorded.",
                modifier = Modifier.padding(32.dp),
                color = MaterialTheme.colorScheme.onSurfaceVariant
            )
        } else {
            LazyColumn(modifier = Modifier.fillMaxSize()) {
                items(viewModel.filteredIncidents) { incident ->
                    IncidentRow(incident)
                    HorizontalDivider(modifier = Modifier.padding(vertical = 2.dp))
                }
            }
        }
    }
}

@Composable
private fun IncidentRow(incident: IncidentEntry) {
    val sevColor = when (incident.severity) {
        "CRITICAL" -> Color.Red
        "ERROR" -> Color(0xFFCC4400)
        "WARN" -> Color(0xFFDDAA00)
        else -> MaterialTheme.colorScheme.onSurfaceVariant
    }

    Row(
        modifier = Modifier
            .fillMaxWidth()
            .padding(vertical = 6.dp, horizontal = 4.dp),
        verticalAlignment = Alignment.Top
    ) {
        Column(modifier = Modifier.weight(1f)) {
            Row(
                modifier = Modifier.fillMaxWidth(),
                horizontalArrangement = Arrangement.SpaceBetween
            ) {
                Text(
                    incident.source,
                    style = MaterialTheme.typography.labelSmall,
                    color = sevColor,
                    fontFamily = FontFamily.Monospace
                )
                Text(
                    incident.timestamp,
                    style = MaterialTheme.typography.labelSmall,
                    color = MaterialTheme.colorScheme.onSurfaceVariant
                )
            }
            Text(
                incident.message,
                style = MaterialTheme.typography.bodySmall,
                fontFamily = FontFamily.Monospace
            )
        }
    }
}
