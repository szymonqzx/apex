package com.apex.control.poweruser

import androidx.compose.foundation.layout.*
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.verticalScroll
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.filled.*
import androidx.compose.material3.*
import androidx.compose.runtime.*
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.text.font.FontFamily
import androidx.compose.ui.unit.dp

/**
 * Power-user features tab for Apex Control.
 *
 * Displays toggle cards for features ported from LineageOS-based ROMs:
 * - Game Space (FPS unlock, sensor block, DND)
 * - Pocket detection
 * - Smart charging schedule
 * - Gesture controls (DT2W, tap-to-sleep, screenshot gesture)
 * - Notification customization (heads-up timeout, flashlight blink)
 * - Misc power-user toggles (app downgrade, haptics, GPS)
 * - Advanced reboot menu
 */
@Composable
fun PowerUserScreen(
    state: PowerUserState,
    onGameSpaceChange: (Boolean) -> Unit,
    onSensorBlockChange: (Boolean) -> Unit,
    onPocketDetectionChange: (Boolean) -> Unit,
    onSmartChargingChange: (Boolean) -> Unit,
    onChargeLimitChange: (Int) -> Unit,
    onTopUpTimeChange: (String) -> Unit,
    onWakeTimeChange: (String) -> Unit,
    onDoubleTapToWakeChange: (Boolean) -> Unit,
    onTapToSleepChange: (Boolean) -> Unit,
    onScreenshotGestureChange: (Boolean) -> Unit,
    onHeadsUpChange: (Boolean) -> Unit,
    onHeadsUpTimeoutChange: (Int) -> Unit,
    onFlashlightBlinkChange: (Boolean) -> Unit,
    onAllowDowngradeChange: (Boolean) -> Unit,
    onDisableHapticsChange: (Boolean) -> Unit,
    onForceGpsChange: (Boolean) -> Unit,
    onRebootAction: (RebootAction) -> Unit,
) {
    var showRebootDialog by remember { mutableStateOf(false) }

    Column(
        modifier = Modifier
            .fillMaxSize()
            .verticalScroll(rememberScrollState())
            .padding(horizontal = 4.dp),
        verticalArrangement = Arrangement.spacedBy(12.dp),
    ) {
        // === Game Space ===
        FeatureCard(
            title = "Game Space",
            icon = Icons.Default.SportsEsports,
        ) {
            SwitchRow(
                label = "Game Space mode",
                subtitle = "FPS unlock, GPU lock, aggressive boost",
                checked = state.gameSpaceEnabled,
                onChange = onGameSpaceChange,
            )
            HorizontalDivider()
            SwitchRow(
                label = "Sensor block (non-FG)",
                subtitle = "Block sensors for background apps during gaming",
                checked = state.sensorBlockEnabled,
                onChange = onSensorBlockChange,
            )
            if (state.gameSpaceEnabled) {
                HorizontalDivider()
                InfoRow("FPS", "120 Hz locked")
                InfoRow("GPU", "650 MHz locked")
                InfoRow("DND", if (state.gameDndEnabled) "Active" else "Inactive")
            }
        }

        // === Pocket Detection ===
        FeatureCard(
            title = "Pocket Detection",
            icon = Icons.Default.Smartphone,
        ) {
            SwitchRow(
                label = "Pocket detection",
                subtitle = "Suppress accidental touches via proximity sensor",
                checked = state.pocketDetectionEnabled,
                onChange = onPocketDetectionChange,
            )
            if (state.pocketDetectionEnabled) {
                HorizontalDivider()
                InfoRow(
                    "Status",
                    if (state.pocketDetected) "In pocket" else "Clear",
                )
            }
        }

        // === Smart Charging ===
        FeatureCard(
            title = "Smart Charging",
            icon = Icons.Default.BatteryChargingFull,
        ) {
            SwitchRow(
                label = "Smart charging schedule",
                subtitle = "Limit charge overnight, top up before wake",
                checked = state.smartChargingEnabled,
                onChange = onSmartChargingChange,
            )
            if (state.smartChargingEnabled) {
                HorizontalDivider()
                Text(
                    "Charge limit: ${state.chargeLimitPercent}%",
                    style = MaterialTheme.typography.bodySmall,
                )
                Slider(
                    value = state.chargeLimitPercent.toFloat(),
                    onValueChange = { onChargeLimitChange(it.toInt()) },
                    valueRange = 50f..100f,
                    steps = 9,
                )
                Row(
                    modifier = Modifier.fillMaxWidth(),
                    horizontalArrangement = Arrangement.spacedBy(16.dp),
                ) {
                    OutlinedTextField(
                        value = state.topUpTime,
                        onValueChange = onTopUpTimeChange,
                        label = { Text("Top-up time") },
                        modifier = Modifier.weight(1f),
                        singleLine = true,
                    )
                    OutlinedTextField(
                        value = state.wakeTime,
                        onValueChange = onWakeTimeChange,
                        label = { Text("Wake time") },
                        modifier = Modifier.weight(1f),
                        singleLine = true,
                    )
                }
                InfoRow("State", state.smartChargeState)
            }
        }

        // === Gestures ===
        FeatureCard(
            title = "Gestures",
            icon = Icons.Default.Gesture,
        ) {
            SwitchRow(
                label = "Double-tap to wake",
                subtitle = "Double-tap screen to wake device",
                checked = state.doubleTapToWake,
                onChange = onDoubleTapToWakeChange,
            )
            HorizontalDivider()
            SwitchRow(
                label = "Tap to sleep",
                subtitle = "Tap status bar to sleep screen",
                checked = state.tapToSleep,
                onChange = onTapToSleepChange,
            )
            HorizontalDivider()
            SwitchRow(
                label = "Three-finger screenshot",
                subtitle = "Swipe down with 3 fingers to capture",
                checked = state.screenshotGesture,
                onChange = onScreenshotGestureChange,
            )
        }

        // === Notifications ===
        FeatureCard(
            title = "Notifications",
            icon = Icons.Default.Notifications,
        ) {
            SwitchRow(
                label = "Heads-up notifications",
                subtitle = "Show floating notification banners",
                checked = state.headsUpEnabled,
                onChange = onHeadsUpChange,
            )
            if (state.headsUpEnabled) {
                HorizontalDivider()
                Text(
                    "Heads-up timeout: ${state.headsUpTimeoutMs}ms",
                    style = MaterialTheme.typography.bodySmall,
                )
                Slider(
                    value = state.headsUpTimeoutMs.toFloat(),
                    onValueChange = { onHeadsUpTimeoutChange(it.toInt()) },
                    valueRange = 1000f..10000f,
                    steps = 17,
                )
            }
            HorizontalDivider()
            SwitchRow(
                label = "Flashlight blink on call",
                subtitle = "Blink flashlight for incoming calls",
                checked = state.flashlightBlinkOnCall,
                onChange = onFlashlightBlinkChange,
            )
        }

        // === Power User Misc ===
        FeatureCard(
            title = "Power User",
            icon = Icons.Default.Tune,
        ) {
            SwitchRow(
                label = "Allow app downgrade",
                subtitle = "Permit installing older app versions",
                checked = state.allowAppDowngrade,
                onChange = onAllowDowngradeChange,
            )
            HorizontalDivider()
            SwitchRow(
                label = "Disable haptics",
                subtitle = "Turn off all system vibration feedback",
                checked = state.disableHaptics,
                onChange = onDisableHapticsChange,
            )
            HorizontalDivider()
            SwitchRow(
                label = "Force GPS high-accuracy",
                subtitle = "Always use high-accuracy GPS mode",
                checked = state.forceGpsHighAccuracy,
                onChange = onForceGpsChange,
            )
        }

        // === Advanced Reboot ===
        FeatureCard(
            title = "Advanced Reboot",
            icon = Icons.Default.RestartAlt,
        ) {
            Button(
                onClick = { showRebootDialog = true },
                modifier = Modifier.fillMaxWidth(),
            ) {
                Icon(Icons.Default.RestartAlt, contentDescription = null)
                Spacer(Modifier.width(8.dp))
                Text("Reboot options")
            }
        }

        Spacer(Modifier.height(16.dp))
    }

    // Reboot action dialog
    if (showRebootDialog) {
        AlertDialog(
            onDismissRequest = { showRebootDialog = false },
            title = { Text("Advanced Reboot") },
            text = {
                Column {
                    RebootAction.entries.forEach { action ->
                        TextButton(
                            onClick = {
                                onRebootAction(action)
                                showRebootDialog = false
                            },
                            modifier = Modifier.fillMaxWidth(),
                        ) {
                            Text(action.displayName, modifier = Modifier.weight(1f))
                            Icon(Icons.Default.ChevronRight, contentDescription = null)
                        }
                    }
                }
            },
            confirmButton = {},
            dismissButton = {
                TextButton(onClick = { showRebootDialog = false }) {
                    Text("Cancel")
                }
            },
        )
    }
}

// === Reusable composables ===

@Composable
private fun FeatureCard(
    title: String,
    icon: androidx.compose.ui.graphics.vector.ImageVector,
    content: @Composable ColumnScope.() -> Unit,
) {
    Card(modifier = Modifier.fillMaxWidth()) {
        Column(
            modifier = Modifier.padding(16.dp),
            verticalArrangement = Arrangement.spacedBy(8.dp),
        ) {
            Row(
                verticalAlignment = Alignment.CenterVertically,
                horizontalArrangement = Arrangement.spacedBy(8.dp),
            ) {
                Icon(icon, contentDescription = null, tint = MaterialTheme.colorScheme.primary)
                Text(title, style = MaterialTheme.typography.titleMedium)
            }
            content()
        }
    }
}

@Composable
private fun SwitchRow(
    label: String,
    subtitle: String,
    checked: Boolean,
    onChange: (Boolean) -> Unit,
) {
    Row(
        modifier = Modifier.fillMaxWidth(),
        verticalAlignment = Alignment.CenterVertically,
        horizontalArrangement = Arrangement.SpaceBetween,
    ) {
        Column(modifier = Modifier.weight(1f)) {
            Text(label, style = MaterialTheme.typography.bodyMedium)
            Text(
                subtitle,
                style = MaterialTheme.typography.bodySmall,
                color = MaterialTheme.colorScheme.onSurfaceVariant,
            )
        }
        Switch(checked = checked, onCheckedChange = onChange)
    }
}

@Composable
private fun InfoRow(label: String, value: String) {
    Row(
        modifier = Modifier.fillMaxWidth(),
        horizontalArrangement = Arrangement.SpaceBetween,
    ) {
        Text(
            label,
            style = MaterialTheme.typography.bodySmall,
            color = MaterialTheme.colorScheme.onSurfaceVariant,
        )
        Text(
            value,
            style = MaterialTheme.typography.bodySmall,
            fontFamily = FontFamily.Monospace,
        )
    }
}
