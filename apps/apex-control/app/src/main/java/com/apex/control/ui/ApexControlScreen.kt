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
import com.apex.control.domain.ApexRepository
import com.apex.control.domain.ApexState
import kotlinx.coroutines.launch

/**
 * UI layer: main Composable screen for Apex Control.
 *
 * Observes state from ApexRepository and renders cards for each subsystem.
 * Includes the trust badge and gate results from the certification platform.
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
                                gamingMode = enabled
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
            OutlinedButton(onClick = { refreshAll() }) {
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
                    kcalR = newR
                    scope.launch { repository.setKcal(kcalR, kcalG, kcalB) }
                }
                KcalSlider("G", kcalG, repository) { newG ->
                    kcalG = newG
                    scope.launch { repository.setKcal(kcalR, kcalG, kcalB) }
                }
                KcalSlider("B", kcalB, repository) { newB ->
                    kcalB = newB
                    scope.launch { repository.setKcal(kcalR, kcalG, kcalB) }
                }
                Row(horizontalArrangement = Arrangement.spacedBy(8.dp)) {
                    OutlinedButton(onClick = {
                        kcalR = 255; kcalG = 255; kcalB = 255
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
