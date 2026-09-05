package com.apex.control.agent

/**
 * Model tier information for the model router UI.
 */
data class ModelInfo(
  val id: String,
  val displayName: String,
  val fileSizeMb: Int,
  val runtimeRamMb: Int,
  val throughputTokPerSec: String,
  val isAvailable: Boolean,
  val isDownloaded: Boolean,
)

/**
 * Available model tiers.
 */
object ModelTiers {
  val FALLBACK = ModelInfo(
    id = "qwen2.5-0.5b",
    displayName = "Qwen 2.5 0.5B Q4_K_M",
    fileSizeMb = 500,
    runtimeRamMb = 600,
    throughputTokPerSec = "15-20",
    isAvailable = true,
    isDownloaded = false,
  )

  val DEFAULT = ModelInfo(
    id = "qwen2.5-1.5b",
    displayName = "Qwen 2.5 1.5B Q4_K_M",
    fileSizeMb = 1100,
    runtimeRamMb = 1500,
    throughputTokPerSec = "5-10",
    isAvailable = true,
    isDownloaded = false,
  )

  val HIGH = ModelInfo(
    id = "qwen2.5-3b",
    displayName = "Qwen 2.5 3B Q4_K_M",
    fileSizeMb = 2200,
    runtimeRamMb = 3300,
    throughputTokPerSec = "3-5",
    isAvailable = true,
    isDownloaded = false,
  )

  val ALL = listOf(FALLBACK, DEFAULT, HIGH)

  fun byId(id: String): ModelInfo? = ALL.find { it.id == id }
}
