package com.apex.control.agent

import androidx.compose.foundation.layout.*
import androidx.compose.material3.*
import androidx.compose.runtime.*
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.text.font.FontFamily
import androidx.compose.ui.unit.dp
import kotlinx.coroutines.launch

/**
 * Model Download Manager — download GGUF model files.
 *
 * Features:
 * - Progress bar with percentage
 * - Storage check before download
 * - SHA-256 checksum verification post-download
 * - Trusted sources only (HuggingFace)
 */
@Composable
fun ModelDownloadManager(
  repository: AgentRepository = remember { AgentRepository() },
) {
  var models by remember { mutableStateOf(ModelTiers.ALL) }
  var downloading by remember { mutableStateOf<String?>(null) }
  var progress by remember { mutableStateOf<DownloadProgress?>(null) }
  val scope = rememberCoroutineScope()

  LaunchedEffect(Unit) {
    models = repository.listModels()
  }

  // Poll download progress
  LaunchedEffect(downloading) {
    if (downloading != null) {
      while (true) {
        progress = repository.downloadModel(downloading!!)
        if (progress?.state == DownloadState.COMPLETE ||
            progress?.state == DownloadState.FAILED) {
          downloading = null
          break
        }
        kotlinx.coroutines.delay(2000)
      }
    }
  }

  Column(
    modifier = Modifier
      .fillMaxSize()
      .padding(16.dp),
    verticalArrangement = Arrangement.spacedBy(12.dp),
  ) {
    Text(
      text = "Model Downloads",
      style = MaterialTheme.typography.titleLarge,
    )
    Text(
      text = "Trusted sources only · SHA-256 verified",
      style = MaterialTheme.typography.labelSmall,
      color = MaterialTheme.colorScheme.onSurfaceVariant,
    )

    HorizontalDivider()

    models.forEach { model ->
      DownloadCard(
        model = model,
        isDownloading = downloading == model.id,
        progress = if (downloading == model.id) progress else null,
        onDownload = {
          downloading = model.id
          scope.launch {
            // Trigger download via repository
            progress = repository.downloadModel(model.id)
          }
        },
      )
    }
  }
}

@Composable
private fun DownloadCard(
  model: ModelInfo,
  isDownloading: Boolean,
  progress: DownloadProgress?,
  onDownload: () -> Unit,
) {
  Card(modifier = Modifier.fillMaxWidth()) {
    Column(
      modifier = Modifier.padding(16.dp),
      verticalArrangement = Arrangement.spacedBy(8.dp),
    ) {
      Row(
        modifier = Modifier.fillMaxWidth(),
        horizontalArrangement = Arrangement.SpaceBetween,
        verticalAlignment = Alignment.CenterVertically,
      ) {
        Column {
          Text(
            text = model.displayName,
            style = MaterialTheme.typography.titleMedium,
            fontFamily = FontFamily.Monospace,
          )
          Text(
            text = "${model.fileSizeMb} MB · ${model.runtimeRamMb} MB RAM",
            style = MaterialTheme.typography.bodySmall,
            color = MaterialTheme.colorScheme.onSurfaceVariant,
          )
        }
        if (model.isDownloaded) {
          Text(
            text = "✓ Downloaded",
            style = MaterialTheme.typography.labelMedium,
            color = MaterialTheme.colorScheme.primary,
          )
        }
      }

      if (isDownloading && progress != null) {
        // Progress bar
        LinearProgressIndicator(
          progress = { progress.percent / 100f },
          modifier = Modifier.fillMaxWidth(),
        )
        Text(
          text = "${progress.state.label} · ${progress.percent}% · ${progress.message}",
          style = MaterialTheme.typography.labelSmall,
          fontFamily = FontFamily.Monospace,
        )
      } else if (!model.isDownloaded) {
        // Storage check warning
        Text(
          text = "Requires ${model.fileSizeMb} MB free storage",
          style = MaterialTheme.typography.labelSmall,
          color = MaterialTheme.colorScheme.onSurfaceVariant,
        )
        Button(
          onClick = onDownload,
          enabled = !isDownloading,
        ) {
          Text("Download")
        }
      }
    }
  }
}
