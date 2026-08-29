// Apex Control — Android app for controlling the apex kernel state machine
// Package: com.apex.control
// Jetpack Compose UI, communicates with apex-bridge via Unix filesystem socket
//
// This is the main Activity. It provides:
// - Gaming mode toggle
// - Screen state display
// - Charging/audio status
// - Battery level and temperature display
// - Thermal temperature display
// - Governor tunables display
// - Watchdog status card
// - Sensor status display (IIO rate, BT scan, WiFi multicast)
// - KCAL display calibration control (RGB gain sliders)
// - Incident log viewer
// - Kernel version display
// - Manual refresh button
// - Auto-refresh every 3 seconds

package com.apex.control

import android.os.Bundle
import android.net.LocalSocket
import android.net.LocalSocketAddress
import androidx.activity.ComponentActivity
import androidx.activity.compose.setContent
import androidx.compose.foundation.layout.*
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.items
import androidx.compose.foundation.lazy.rememberLazyListState
import androidx.compose.material3.*
import androidx.compose.runtime.*
import androidx.compose.runtime.saveable.rememberSaveable
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.text.font.FontFamily
import androidx.compose.ui.unit.dp
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.launch
import kotlinx.coroutines.withContext
import java.io.*

class MainActivity : ComponentActivity() {
    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        setContent {
            MaterialTheme {
                ApexControlApp()
            }
        }
    }
}

@Composable
fun ApexControlApp() {
    var gamingMode by rememberSaveable { mutableStateOf(false) }
    var statusText by remember { mutableStateOf("Loading...") }
    var versionText by remember { mutableStateOf("") }
    var governorText by remember { mutableStateOf("") }
    var watchdogText by remember { mutableStateOf("") }
    var thermalProfileText by remember { mutableStateOf("") }
    var policyActiveText by remember { mutableStateOf("") }
    var modulesText by remember { mutableStateOf("") }
    var sensorText by remember { mutableStateOf("") }
    var btText by remember { mutableStateOf("") }
    var healthText by remember { mutableStateOf("") }
    var statsText by remember { mutableStateOf("") }
    var incidents by remember { mutableStateOf(listOf<String>()) }
    var kcalR by rememberSaveable { mutableStateOf(255) }
    var kcalG by rememberSaveable { mutableStateOf(255) }
    var kcalB by rememberSaveable { mutableStateOf(255) }
    val scope = rememberCoroutineScope()
    val incidentListState = rememberLazyListState()

    // Refresh all data
    fun refreshAll() {
        scope.launch(Dispatchers.IO) {
            statusText = getStatus()
            versionText = sendCommand("version")
            governorText = sendCommand("governor")
            watchdogText = sendCommand("watchdog")
            thermalProfileText = sendCommand("thermal_profile")
            policyActiveText = sendCommand("policy_active")
            modulesText = sendCommand("modules")
            sensorText = readProc("/proc/apex/sensor_status")
            btText = readProc("/proc/apex/bt_status")
            healthText = readProc("/proc/apex/health")
            statsText = readProc("/proc/apex/stats")
            incidents = readIncidents()
        }
    }

    // Initial load and auto-refresh
    LaunchedEffect(Unit) {
        refreshAll()
        while (true) {
            statusText = withContext(Dispatchers.IO) { getStatus() }
            kotlinx.coroutines.delay(3000)
        }
    }

    // Auto-scroll incidents to latest
    LaunchedEffect(incidents) {
        if (incidents.isNotEmpty()) {
            incidentListState.animateScrollToItem(incidents.lastIndex)
        }
    }

    Column(
        modifier = Modifier
            .fillMaxSize()
            .padding(16.dp),
        verticalArrangement = Arrangement.spacedBy(12.dp)
    ) {
        // Header with version
        Text(
            text = "APEX Control",
            style = MaterialTheme.typography.headlineMedium
        )
        Text(
            text = "Redmi Note 12 4G — topaz",
            style = MaterialTheme.typography.bodySmall,
            color = MaterialTheme.colorScheme.onSurfaceVariant
        )
        if (versionText.isNotEmpty()) {
            Text(
                text = versionText.lineSequence().firstOrNull() ?: "",
                style = MaterialTheme.typography.bodySmall,
                fontFamily = FontFamily.Monospace,
                color = MaterialTheme.colorScheme.onSurfaceVariant
            )
        }

        HorizontalDivider()

        // Gaming mode toggle
        Card(
            modifier = Modifier.fillMaxWidth()
        ) {
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
                        gamingMode = enabled
                        scope.launch(Dispatchers.IO) {
                            sendCommand("game ${if (enabled) 1 else 0}")
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

        // Status display
        Card(
            modifier = Modifier.fillMaxWidth()
        ) {
            Column(
                modifier = Modifier.padding(16.dp),
                verticalArrangement = Arrangement.spacedBy(4.dp)
            ) {
                Text("Status", style = MaterialTheme.typography.titleMedium)
                Text(
                    text = statusText,
                    style = MaterialTheme.typography.bodySmall,
                    fontFamily = FontFamily.Monospace
                )
            }
        }

        // Health (battery + thermal details)
        if (healthText.isNotEmpty()) {
            Card(
                modifier = Modifier.fillMaxWidth()
            ) {
                Column(
                    modifier = Modifier.padding(16.dp),
                    verticalArrangement = Arrangement.spacedBy(4.dp)
                ) {
                    Text("Health", style = MaterialTheme.typography.titleMedium)
                    Text(
                        text = healthText,
                        style = MaterialTheme.typography.bodySmall,
                        fontFamily = FontFamily.Monospace
                    )
                }
            }
        }

        // Governor tunables
        if (governorText.isNotEmpty()) {
            Card(
                modifier = Modifier.fillMaxWidth()
            ) {
                Column(
                    modifier = Modifier.padding(16.dp),
                    verticalArrangement = Arrangement.spacedBy(4.dp)
                ) {
                    Text("Governor", style = MaterialTheme.typography.titleMedium)
                    Text(
                        text = governorText,
                        style = MaterialTheme.typography.bodySmall,
                        fontFamily = FontFamily.Monospace
                    )
                }
            }
        }

        // Watchdog status
        if (watchdogText.isNotEmpty()) {
            Card(
                modifier = Modifier.fillMaxWidth()
            ) {
                Column(
                    modifier = Modifier.padding(16.dp),
                    verticalArrangement = Arrangement.spacedBy(4.dp)
                ) {
                    Text("Watchdog", style = MaterialTheme.typography.titleMedium)
                    Text(
                        text = watchdogText,
                        style = MaterialTheme.typography.bodySmall,
                        fontFamily = FontFamily.Monospace
                    )
                }
            }
        }

        // Policy active (decision table)
        if (policyActiveText.isNotEmpty()) {
            Card(
                modifier = Modifier.fillMaxWidth()
            ) {
                Column(
                    modifier = Modifier.padding(16.dp),
                    verticalArrangement = Arrangement.spacedBy(4.dp)
                ) {
                    Text("Policy Active", style = MaterialTheme.typography.titleMedium)
                    Text(
                        text = policyActiveText,
                        style = MaterialTheme.typography.bodySmall,
                        fontFamily = FontFamily.Monospace
                    )
                }
            }
        }

        // Sensor status (IIO rate, BT scan, WiFi multicast)
        if (sensorText.isNotEmpty()) {
            Card(
                modifier = Modifier.fillMaxWidth()
            ) {
                Column(
                    modifier = Modifier.padding(16.dp),
                    verticalArrangement = Arrangement.spacedBy(4.dp)
                ) {
                    Text("Sensors", style = MaterialTheme.typography.titleMedium)
                    Text(
                        text = sensorText,
                        style = MaterialTheme.typography.bodySmall,
                        fontFamily = FontFamily.Monospace
                    )
                }
            }
        }

        // BT status (rfkill)
        if (btText.isNotEmpty()) {
            Card(
                modifier = Modifier.fillMaxWidth()
            ) {
                Column(
                    modifier = Modifier.padding(16.dp),
                    verticalArrangement = Arrangement.spacedBy(4.dp)
                ) {
                    Text("Bluetooth", style = MaterialTheme.typography.titleMedium)
                    Text(
                        text = btText,
                        style = MaterialTheme.typography.bodySmall,
                        fontFamily = FontFamily.Monospace
                    )
                }
            }
        }

        // Thermal profile (7-day learner)
        if (thermalProfileText.isNotEmpty()) {
            Card(
                modifier = Modifier.fillMaxWidth()
            ) {
                Column(
                    modifier = Modifier.padding(16.dp),
                    verticalArrangement = Arrangement.spacedBy(4.dp)
                ) {
                    Text("Thermal Profile (7-day learner)", style = MaterialTheme.typography.titleMedium)
                    Text(
                        text = thermalProfileText,
                        style = MaterialTheme.typography.bodySmall,
                        fontFamily = FontFamily.Monospace
                    )
                }
            }
        }

        // Stats
        if (statsText.isNotEmpty()) {
            Card(
                modifier = Modifier.fillMaxWidth()
            ) {
                Column(
                    modifier = Modifier.padding(16.dp),
                    verticalArrangement = Arrangement.spacedBy(4.dp)
                ) {
                    Text("Statistics", style = MaterialTheme.typography.titleMedium)
                    Text(
                        text = statsText,
                        style = MaterialTheme.typography.bodySmall,
                        fontFamily = FontFamily.Monospace
                    )
                }
            }
        }

        // KCAL display calibration
        Card(
            modifier = Modifier.fillMaxWidth()
        ) {
            Column(
                modifier = Modifier.padding(16.dp),
                verticalArrangement = Arrangement.spacedBy(8.dp)
            ) {
                Text("Display Calibration (KCAL)", style = MaterialTheme.typography.titleMedium)
                Text(
                    "RGB gain: $kcalR $kcalG $kcalB",
                    style = MaterialTheme.typography.bodySmall,
                    fontFamily = FontFamily.Monospace
                )
                Text("R", style = MaterialTheme.typography.labelSmall)
                Slider(
                    value = kcalR.toFloat(),
                    onValueChange = { kcalR = it.toInt() },
                    valueRange = 0f..255f,
                    onValueChangeFinished = {
                        scope.launch(Dispatchers.IO) {
                            writeKcal(kcalR, kcalG, kcalB)
                        }
                    }
                )
                Text("G", style = MaterialTheme.typography.labelSmall)
                Slider(
                    value = kcalG.toFloat(),
                    onValueChange = { kcalG = it.toInt() },
                    valueRange = 0f..255f,
                    onValueChangeFinished = {
                        scope.launch(Dispatchers.IO) {
                            writeKcal(kcalR, kcalG, kcalB)
                        }
                    }
                )
                Text("B", style = MaterialTheme.typography.labelSmall)
                Slider(
                    value = kcalB.toFloat(),
                    onValueChange = { kcalB = it.toInt() },
                    valueRange = 0f..255f,
                    onValueChangeFinished = {
                        scope.launch(Dispatchers.IO) {
                            writeKcal(kcalR, kcalG, kcalB)
                        }
                    }
                )
                Row(
                    horizontalArrangement = Arrangement.spacedBy(8.dp)
                ) {
                    OutlinedButton(onClick = {
                        kcalR = 255; kcalG = 255; kcalB = 255
                        scope.launch(Dispatchers.IO) { writeKcal(255, 255, 255) }
                    }) {
                        Text("Reset")
                    }
                }
            }
        }

        // Loaded modules (pentest)
        if (modulesText.isNotEmpty()) {
            Card(
                modifier = Modifier.fillMaxWidth()
            ) {
                Column(
                    modifier = Modifier.padding(16.dp),
                    verticalArrangement = Arrangement.spacedBy(4.dp)
                ) {
                    Text("Pentest Modules", style = MaterialTheme.typography.titleMedium)
                    Text(
                        text = modulesText,
                        style = MaterialTheme.typography.bodySmall,
                        fontFamily = FontFamily.Monospace
                    )
                }
            }
        }

        // Incident log
        Card(
            modifier = Modifier
                .fillMaxWidth()
                .weight(1f)
        ) {
            Column(
                modifier = Modifier.padding(16.dp)
            ) {
                Text("Incidents", style = MaterialTheme.typography.titleMedium)
                Spacer(modifier = Modifier.height(8.dp))
                LazyColumn(
                    state = incidentListState,
                    modifier = Modifier.weight(1f)
                ) {
                    items(incidents) { incident ->
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

// ---- Socket communication ----

private const val SOCKET_PATH = "/dev/socket/apex-bridge"

fun sendCommand(cmd: String): String {
    return try {
        val socket = LocalSocket()
        socket.connect(LocalSocketAddress(SOCKET_PATH, LocalSocketAddress.Namespace.FILESYSTEM))
        val output = socket.outputStream
        val input = socket.inputStream
        output.write(cmd.toByteArray())
        output.flush()
        val buf = ByteArray(4096)
        val n = input.read(buf)
        socket.close()
        if (n > 0) String(buf, 0, n) else ""
    } catch (e: Exception) {
        "Error: ${e.message}"
    }
}

fun getStatus(): String {
    return try {
        sendCommand("status")
    } catch (e: Exception) {
        "Error: ${e.message}"
    }
}

fun readIncidents(): List<String> {
    return try {
        val content = File("/proc/apex/incidents").readText()
        content.lines().filter { it.isNotBlank() }
    } catch (e: Exception) {
        listOf("Error reading incidents: ${e.message}")
    }
}

fun readProc(path: String): String {
    return try {
        File(path).readText().trim()
    } catch (e: Exception) {
        ""
    }
}

fun writeKcal(r: Int, g: Int, b: Int) {
    try {
        File("/sys/class/apex_kcal/rgb_gains").writeText("$r $g $b")
    } catch (e: Exception) {
        // KCAL not available — ignore
    }
}
