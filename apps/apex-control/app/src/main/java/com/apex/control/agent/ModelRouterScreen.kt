package com.apex.control.agent

import androidx.compose.foundation.layout.*
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.items
import androidx.compose.material3.*
import androidx.compose.runtime.*
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.text.font.FontFamily
import androidx.compose.ui.unit.dp
import kotlinx.coroutines.launch

/**
 * Model Router screen — lets the user select model tier without reboot.
 *
 * Shows:
 * - Current active model
 * - Available tiers with RAM/throughput info
 * - Download status for each model
 * - Switch button (calls IApexAgent.setModelTier)
 */
@Composable
fun ModelRouterScreen(
  repository: AgentRepository = remember { AgentRepository() },
) {
  var models by remember { mutableStateOf(ModelTiers.ALL) }
  var currentTier by remember { mutableStateOf("") }
  var status by remember { mutableStateOf<AgentStatus?>(null) }
  val scope = rememberCoroutineScope()

  // Fetch status and model list
  LaunchedEffect(Unit) {
    while (true) {
      status = repository.getAgentStatus()
      models = repository.listModels()
      currentTier = status?.currentModel ?: ""
      kotlinx.coroutines.delay(5000)
    }
  }

  Column(
    modifier = Modifier
      .fillMaxSize()
      .padding(16.dp),
    verticalArrangement = Arrangement.spacedBy(12.dp),
  ) {
    Text(
      text = "Model Router",
      style = MaterialTheme.typography.titleLarge,
    )

    // Current model
    if (status != null) {
      Card(modifier = Modifier.fillMaxWidth()) {
        Column(modifier = Modifier.padding(16.dp)) {
          Text("Active Model", style = MaterialTheme.typography.labelMedium)
          Text(
            text = status!!.currentModel.ifEmpty { "None" },
            style = MaterialTheme.typography.titleMedium,
            fontFamily = FontFamily.Monospace,
          )
          if (status!!.tokensPerSecond > 0) {
            Text(
              text = "${String.format("%.1f", status!!.tokensPerSecond)} tok/s",
              style = MaterialTheme.typography.bodySmall,
              color = MaterialTheme.colorScheme.onSurfaceVariant,
            )
          }
          if (status!!.fallbackMode) {
            Text(
              text = "⚠ Fallback mode (no LLM)",
              style = MaterialTheme.typography.bodySmall,
              color = MaterialTheme.colorScheme.error,
            )
          }
        }
      }
    }

    HorizontalDivider()

    // Model tier list
    LazyColumn(
      verticalArrangement = Arrangement.spacedBy(8.dp),
    ) {
      items(models) { model ->
        ModelTierCard(
          model = model,
          isActive = model.id == currentTier,
          onSwitch = {
            scope.launch {
              repository.setModelTier(model.id)
            }
          },
        )
      }
    }
  }
}

@Composable
private fun ModelTierCard(
  model: ModelInfo,
  isActive: Boolean,
  onSwitch: () -> Unit,
) {
  Card(
    modifier = Modifier.fillMaxWidth(),
    colors = CardDefaults.cardColors(
      containerColor = if (isActive) {
        MaterialTheme.colorScheme.primaryContainer
      } else {
        MaterialTheme.colorScheme.surface
      },
    ),
  ) {
    Column(
      modifier = Modifier.padding(16.dp),
      verticalArrangement = Arrangement.spacedBy(4.dp),
    ) {
      Row(
        modifier = Modifier.fillMaxWidth(),
        horizontalArrangement = Arrangement.SpaceBetween,
        verticalAlignment = Alignment.CenterVertically,
      ) {
        Text(
          text = model.displayName,
          style = MaterialTheme.typography.titleMedium,
          fontFamily = FontFamily.Monospace,
        )
        if (isActive) {
          Text(
            text = "ACTIVE",
            style = MaterialTheme.typography.labelSmall,
            color = MaterialTheme.colorScheme.primary,
          )
        }
      }

      Text(
        text = "File: ${model.fileSizeMb} MB · RAM: ${model.runtimeRamMb} MB · ~${model.throughputTokPerSec} tok/s",
        style = MaterialTheme.typography.bodySmall,
        color = MaterialTheme.colorScheme.onSurfaceVariant,
      )

      if (!model.isDownloaded) {
        Text(
          text = "Not downloaded — use Download Manager",
          style = MaterialTheme.typography.labelSmall,
          color = MaterialTheme.colorScheme.tertiary,
        )
      }

      if (!isActive && model.isDownloaded) {
        TextButton(onClick = onSwitch) {
          Text("Switch to this model")
        }
      }
    }
  }
}
