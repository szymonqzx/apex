package com.apex.control.ui

import androidx.compose.foundation.layout.*
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.items
import androidx.compose.foundation.lazy.rememberLazyListState
import androidx.compose.material3.*
import androidx.compose.runtime.*
import androidx.compose.runtime.mutableIntStateOf
import androidx.compose.runtime.saveable.rememberSaveable
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.text.font.FontFamily
import androidx.compose.ui.unit.dp
import com.apex.control.agent.AgentChatSurface
import com.apex.control.agent.AgentDebugLogViewer
import com.apex.control.agent.AuditLogViewer
import com.apex.control.agent.ModelDownloadManager
import com.apex.control.agent.ModelRouterScreen
import com.apex.control.domain.ApexRepository
import com.apex.control.domain.ApexState
import com.apex.control.poweruser.PowerUserRepository
import com.apex.control.poweruser.PowerUserScreen
import com.apex.control.poweruser.PowerUserState
import com.apex.control.poweruser.RebootAction
import kotlinx.coroutines.launch

/**
 * UI layer: main Composable screen for Apex Control.
 *
 * Observes state from ApexRepository and renders cards for each subsystem.
 * Includes the trust badge and gate results from the certification platform.
 *
 * Tab layout: System (original controls) | Agent | Model | Audit | Debug
 */
@Composable
fun ApexControlScreen(
    repository: ApexRepository = remember { ApexRepository() },
) {
    var state by remember { mutableStateOf(ApexState()) }
    var gamingMode by rememberSaveable { mutableStateOf(false) }
    var kcalR by rememberSaveable { mutableStateOf(255) }
    var kcalG by rememberSaveable { mutableStateOf(255) }
    var kcalB by rememberSaveable { mutableStateOf(255) }
    val scope = rememberCoroutineScope()
    val incidentListState = rememberLazyListState()
    var selectedTab by rememberSaveable { mutableStateOf(0) }
    val tabs = listOf("System", "Agent", "Model", "Audit", "Debug", "Power")

    // Power-user state
    val powerUserRepo = remember { PowerUserRepository() }
    var powerUserState by remember { mutableStateOf(PowerUserState()) }

    // Fetch power-user state
    LaunchedEffect(Unit) {
        powerUserState = powerUserRepo.fetchState()
    }

    // Fetch full state snapshot
    fun refreshAll() {
        scope.launch {
            state = repository.fetchState()
        }
    }

    // Initial load
    LaunchedEffect(Unit) {
        state = repository.fetchState()
    }

    // Auto-refresh status every 3 seconds
    LaunchedEffect(Unit) {
        while (true) {
            kotlinx.coroutines.delay(3000)
            state = repository.fetchState()
        }
    }

    // Auto-scroll incidents to latest
    LaunchedEffect(state.incidents) {
        if (state.incidents.isNotEmpty()) {
            incidentListState.animateScrollToItem(state.incidents.lastIndex)
        }
    }

    Column(
        modifier = Modifier
            .fillMaxSize()
            .padding(16.dp),
        verticalArrangement = Arrangement.spacedBy(12.dp)
    ) {
        // Header with version and trust badge
        Row(
            modifier = Modifier.fillMaxWidth(),
            horizontalArrangement = Arrangement.SpaceBetween,
            verticalAlignment = Alignment.CenterVertically,
        ) {
            Column {
                Text(
                    text = "APEX Control",
                    style = MaterialTheme.typography.headlineMedium
                )
                Text(
                    text = "Redmi Note 12 4G — topaz",
                    style = MaterialTheme.typography.bodySmall,
                    color = MaterialTheme.colorScheme.onSurfaceVariant
                )
            }
            TrustBadge(
                state = state.trustState,
                manifestHash = state.trustManifestHash,
            )
        }

        if (state.version.isNotEmpty()) {
            Text(
                text = state.version.lineSequence().firstOrNull() ?: "",
                style = MaterialTheme.typography.bodySmall,
                fontFamily = FontFamily.Monospace,
                color = MaterialTheme.colorScheme.onSurfaceVariant
            )
        }

        HorizontalDivider()

        // Tab row
        TabRow(selectedTabIndex = selectedTab) {
            tabs.forEachIndexed { index, title ->
                Tab(
                    selected = selectedTab == index,
                    onClick = { selectedTab = index },
                    text = { Text(title) },
                )
            }
        }

        // Tab content
        when (selectedTab) {
            0 -> {
                // System tab (original controls)
                SystemTabContent(
                    state = state,
                    gamingMode = gamingMode,
                    kcalR = kcalR,
                    kcalG = kcalG,
                    kcalB = kcalB,
                    repository = repository,
                    scope = scope,
                    incidentListState = incidentListState,
                    onRefresh = { refreshAll() },
                    onGamingModeChange = { gamingMode = it },
                    onKcalRChange = { kcalR = it },
                    onKcalGChange = { kcalG = it },
                    onKcalBChange = { kcalB = it },
                )
            }
            1 -> AgentChatSurface()
            2 -> ModelRouterScreen()
            3 -> AuditLogViewer()
            4 -> AgentDebugLogViewer()
            5 -> PowerUserScreen(
                state = powerUserState,
                onGameSpaceChange = { enabled ->
                    powerUserState = powerUserState.copy(gameSpaceEnabled = enabled)
                    scope.launch { powerUserRepo.setGameSpace(enabled) }
                },
                onSensorBlockChange = { enabled ->
                    powerUserState = powerUserState.copy(sensorBlockEnabled = enabled)
                    scope.launch { powerUserRepo.setSensorBlock(enabled) }
                },
                onPocketDetectionChange = { enabled ->
                    powerUserState = powerUserState.copy(pocketDetectionEnabled = enabled)
                    scope.launch { powerUserRepo.setPocketDetection(enabled) }
                },
                onSmartChargingChange = { enabled ->
                    powerUserState = powerUserState.copy(smartChargingEnabled = enabled)
                    scope.launch { powerUserRepo.setSmartCharging(enabled) }
                },
                onChargeLimitChange = { percent ->
                    powerUserState = powerUserState.copy(chargeLimitPercent = percent)
                    scope.launch { powerUserRepo.setChargeLimit(percent) }
                },
                onTopUpTimeChange = { time ->
                    powerUserState = powerUserState.copy(topUpTime = time)
                    scope.launch { powerUserRepo.setTopUpTime(time) }
                },
                onWakeTimeChange = { time ->
                    powerUserState = powerUserState.copy(wakeTime = time)
                    scope.launch { powerUserRepo.setWakeTime(time) }
                },
                onDoubleTapToWakeChange = { enabled ->
                    powerUserState = powerUserState.copy(doubleTapToWake = enabled)
                    scope.launch { powerUserRepo.setDoubleTapToWake(enabled) }
                },
                onTapToSleepChange = { enabled ->
                    powerUserState = powerUserState.copy(tapToSleep = enabled)
                    scope.launch { powerUserRepo.setTapToSleep(enabled) }
                },
                onScreenshotGestureChange = { enabled ->
                    powerUserState = powerUserState.copy(screenshotGesture = enabled)
                    scope.launch { powerUserRepo.setScreenshotGesture(enabled) }
                },
                onHeadsUpChange = { enabled ->
                    powerUserState = powerUserState.copy(headsUpEnabled = enabled)
                    scope.launch { powerUserRepo.setHeadsUp(enabled) }
                },
                onHeadsUpTimeoutChange = { ms ->
                    powerUserState = powerUserState.copy(headsUpTimeoutMs = ms)
                    scope.launch { powerUserRepo.setHeadsUpTimeout(ms) }
                },
                onFlashlightBlinkChange = { enabled ->
                    powerUserState = powerUserState.copy(flashlightBlinkOnCall = enabled)
                    scope.launch { powerUserRepo.setFlashlightBlink(enabled) }
                },
                onAllowDowngradeChange = { enabled ->
                    powerUserState = powerUserState.copy(allowAppDowngrade = enabled)
                    scope.launch { powerUserRepo.setAllowAppDowngrade(enabled) }
                },
                onDisableHapticsChange = { enabled ->
                    powerUserState = powerUserState.copy(disableHaptics = enabled)
                    scope.launch { powerUserRepo.setDisableHaptics(enabled) }
                },
                onForceGpsChange = { enabled ->
                    powerUserState = powerUserState.copy(forceGpsHighAccuracy = enabled)
                    scope.launch { powerUserRepo.setForceGpsHighAccuracy(enabled) }
                },
                onRebootAction = { action ->
                    powerUserState = powerUserState.copy(lastRebootAction = action.displayName)
                    scope.launch { powerUserRepo.triggerReboot(action) }
                },
            )
        }
    }
}

@Composable
private fun SystemTabContent(
    state: ApexState,
    gamingMode: Boolean,
    kcalR: Int,
    kcalG: Int,
    kcalB: Int,
    repository: ApexRepository,
    scope: kotlinx.coroutines.CoroutineScope,
    incidentListState: androidx.compose.foundation.lazy.LazyListState,
    onRefresh: () -> Unit,
    onGamingModeChange: (Boolean) -> Unit,
    onKcalRChange: (Int) -> Unit,
    onKcalGChange: (Int) -> Unit,
    onKcalBChange: (Int) -> Unit,
) {
    Column(
        verticalArrangement = Arrangement.spacedBy(12.dp)
    ) {
        // Gaming mode toggle
        Card(modifier = Modifier.fillMaxWidth()) {
            Row(
                modifier = Modifier
                    .fillMaxWidth()
                    .padding(16.dp),
                horizontalArrangement = Arrangement.SpaceBetween,
                verticalAlignment = Alignment.CenterVertically
            ) {
                Column {
                    Text("Gaming Mode", style = MaterialTheme.typography.titleMedium)
                    Text(
                        "Max CPU/GPU, relaxed thermal",
                        style = MaterialTheme.typography.bodySmall,
                        color = MaterialTheme.colorScheme.onSurfaceVariant
                    )
                }
                Switch(
                    checked = gamingMode,
                    onCheckedChange = { enabled ->
                        scope.launch {
                            val ok = repository.setGamingMode(enabled)
                            if (ok) {
                                onGamingModeChange(enabled)
                            }
                        }
                    }
                )
            }
        }

        // Refresh button
        Row(
            modifier = Modifier.fillMaxWidth(),
            horizontalArrangement = Arrangement.End
        ) {
            OutlinedButton(onClick = onRefresh) {
                Text("Refresh")
            }
        }

        // Trust gate results (event-driven from manifest)
        GateResultsList(gates = state.trustGates)

        // Status card
        InfoCard(title = "Status", content = state.status)

        // Health card
        if (state.health.isNotEmpty()) {
            InfoCard(title = "Health", content = state.health)
        }

        // Governor card
        if (state.governor.isNotEmpty()) {
            InfoCard(title = "Governor", content = state.governor)
        }

        // Watchdog card
        if (state.watchdog.isNotEmpty()) {
            InfoCard(title = "Watchdog", content = state.watchdog)
        }

        // Policy active card
        if (state.policyActive.isNotEmpty()) {
            InfoCard(title = "Policy Active", content = state.policyActive)
        }

        // Sensor status card
        if (state.sensorStatus.isNotEmpty()) {
            InfoCard(title = "Sensors", content = state.sensorStatus)
        }

        // BT status card
        if (state.btStatus.isNotEmpty()) {
            InfoCard(title = "Bluetooth", content = state.btStatus)
        }

        // Thermal profile card
        if (state.thermalProfile.isNotEmpty()) {
            InfoCard(title = "Thermal Profile (7-day learner)",
                     content = state.thermalProfile)
        }

        // Stats card
        if (state.stats.isNotEmpty()) {
            InfoCard(title = "Statistics", content = state.stats)
        }

        // KCAL display calibration
        Card(modifier = Modifier.fillMaxWidth()) {
            Column(
                modifier = Modifier.padding(16.dp),
                verticalArrangement = Arrangement.spacedBy(8.dp)
            ) {
                Text("Display Calibration (KCAL)",
                     style = MaterialTheme.typography.titleMedium)
                Text(
                    "RGB gain: $kcalR $kcalG $kcalB",
                    style = MaterialTheme.typography.bodySmall,
                    fontFamily = FontFamily.Monospace
                )
                KcalSlider("R", kcalR, repository) { newR ->
                    onKcalRChange(newR)
                    scope.launch { repository.setKcal(newR, kcalG, kcalB) }
                }
                KcalSlider("G", kcalG, repository) { newG ->
                    onKcalGChange(newG)
                    scope.launch { repository.setKcal(kcalR, newG, kcalB) }
                }
                KcalSlider("B", kcalB, repository) { newB ->
                    onKcalBChange(newB)
                    scope.launch { repository.setKcal(kcalR, kcalG, newB) }
                }
                Row(horizontalArrangement = Arrangement.spacedBy(8.dp)) {
                    OutlinedButton(onClick = {
                        onKcalRChange(255); onKcalGChange(255); onKcalBChange(255)
                        scope.launch { repository.setKcal(255, 255, 255) }
                    }) {
                        Text("Reset")
                    }
                }
            }
        }

        // Pentest modules
        if (state.modules.isNotEmpty()) {
            InfoCard(title = "Pentest Modules", content = state.modules)
        }

        // Incident log
        Card(
            modifier = Modifier
                .fillMaxWidth()
                .weight(1f)
        ) {
            Column(modifier = Modifier.padding(16.dp)) {
                Text("Incidents", style = MaterialTheme.typography.titleMedium)
                Spacer(modifier = Modifier.height(8.dp))
                LazyColumn(
                    state = incidentListState,
                    modifier = Modifier.weight(1f)
                ) {
                    items(state.incidents) { incident ->
                        Text(
                            text = incident,
                            style = MaterialTheme.typography.bodySmall,
                            fontFamily = FontFamily.Monospace,
                            modifier = Modifier.padding(vertical = 2.dp)
                        )
                    }
                }
            }
        }
    }
}

@Composable
private fun InfoCard(title: String, content: String) {
    Card(modifier = Modifier.fillMaxWidth()) {
        Column(
            modifier = Modifier.padding(16.dp),
            verticalArrangement = Arrangement.spacedBy(4.dp)
        ) {
            Text(title, style = MaterialTheme.typography.titleMedium)
            Text(
                text = content,
                style = MaterialTheme.typography.bodySmall,
                fontFamily = FontFamily.Monospace
            )
        }
    }
}

@Composable
private fun KcalSlider(
    label: String,
    value: Int,
    repository: com.apex.control.domain.ApexRepository,
    onFinished: (Int) -> Unit,
) {
    var local by remember { mutableIntStateOf(value) }
    // Sync local state with parent value when reset or external change occurs.
    SideEffect { local = value }
    Text(label, style = MaterialTheme.typography.labelSmall)
    Slider(
        value = local.toFloat(),
        onValueChange = { local = it.toInt() },
        valueRange = 0f..255f,
        onValueChangeFinished = { onFinished(local) },
    )
}
