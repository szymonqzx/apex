/*
 * ThermalProfileScreen.kt
 *
 * Shows current thermal thresholds and the learned profile from the
 * 7-day thermal learner. Displays:
 *   - Current CPU temperature
 *   - Active thermal trip points (warn/crit/shutdown)
 *   - Learned profile status (collecting/stable)
 *   - Per-core temperature breakdown
 *   - Thermal zone listing
 *
 * Reads from:
 *   /sys/class/thermal/thermal_zone*/temp
 *   /proc/apex/thermal_profile (if APEX kernel module loaded)
 *   /vendor/etc/thermald.conf
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
import androidx.compose.ui.unit.dp
import androidx.lifecycle.ViewModel
import androidx.lifecycle.viewModelScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.delay
import kotlinx.coroutines.launch

data class ThermalZone(
    val name: String,
    val type: String,
    val tempMilliC: Int,
    val tempC: Float
)

data class ThermalProfile(
    val profileStatus: String,
    val warnThreshold: Float,
    val critThreshold: Float,
    val shutdownThreshold: Float,
    val daysCollected: Int
)

class ThermalViewModel : ViewModel() {
    var zones by mutableStateOf<List<ThermalZone>>(emptyList())
        private set
    var profile by mutableStateOf<ThermalProfile?>(null)
        private set
    var isRefreshing by mutableStateOf(false)
        private set

    fun refresh() {
        viewModelScope.launch(Dispatchers.IO) {
            isRefreshing = true
            try {
                zones = readThermalZones()
                profile = readProfile()
            } catch (e: Exception) {
                // ignore
            }
            isRefreshing = false
        }
    }

    private fun readThermalZones(): List<ThermalZone> {
        val result = mutableListOf<ThermalZone>()
        for (i in 0 until 20) {
            val tempPath = "/sys/class/thermal/thermal_zone${i}/temp"
            val typePath = "/sys/class/thermal/thermal_zone${i}/type"
            try {
                val temp = java.io.File(tempPath).readText().trim().toIntOrNull() ?: continue
                val type = java.io.File(typePath).readText().trim()
                result.add(ThermalZone("thermal_zone$i", type, temp, temp / 1000f))
            } catch (e: Exception) {
                continue
            }
        }
        return result
    }

    private fun readProfile(): ThermalProfile? {
        return try {
            val raw = java.io.File("/proc/apex/thermal_profile").readText().trim()
            // Expected format: "status=stable warn=45 crit=55 shutdown=65 days=7"
            val parts = raw.split(" ").associate {
                val kv = it.split("=")
                if (kv.size == 2) kv[0] to kv[1] else "" to ""
            }
            ThermalProfile(
                profileStatus = parts["status"] ?: "unknown",
                warnThreshold = parts["warn"]?.toFloatOrNull() ?: 45f,
                critThreshold = parts["crit"]?.toFloatOrNull() ?: 55f,
                shutdownThreshold = parts["shutdown"]?.toFloatOrNull() ?: 65f,
                daysCollected = parts["days"]?.toIntOrNull() ?: 0
            )
        } catch (e: Exception) {
            // Fallback to defaults
            ThermalProfile("unavailable", 45f, 55f, 65f, 0)
        }
    }
}

@Composable
fun ThermalProfileScreen(viewModel: ThermalViewModel = androidx.lifecycle.viewmodel.compose.viewModel()) {
    LaunchedEffect(Unit) {
        viewModel.refresh()
        while (true) {
            delay(5000) // refresh every 5 seconds
            viewModel.refresh()
        }
    }

    Column(
        modifier = Modifier
            .fillMaxSize()
            .padding(16.dp)
            .verticalScroll(rememberScrollState())
    ) {
        Text("Thermal Profile", style = MaterialTheme.typography.headlineMedium)
        Spacer(modifier = Modifier.height(8.dp))

        // Profile card
        viewModel.profile?.let { prof ->
            Card(modifier = Modifier.fillMaxWidth()) {
                Column(modifier = Modifier.padding(16.dp)) {
                    Text("Learned Profile", style = MaterialTheme.typography.titleMedium)
                    Spacer(modifier = Modifier.height(8.dp))
                    ProfileRow("Status", prof.profileStatus)
                    ProfileRow("Warn threshold", "${prof.warnThreshold}°C")
                    ProfileRow("Critical threshold", "${prof.critThreshold}°C")
                    ProfileRow("Shutdown threshold", "${prof.shutdownThreshold}°C")
                    ProfileRow("Days collected", prof.daysCollected.toString())
                }
            }
        }

        Spacer(modifier = Modifier.height(16.dp))

        Text("Thermal Zones", style = MaterialTheme.typography.titleMedium)
        Spacer(modifier = Modifier.height(8.dp))

        if (viewModel.isRefreshing && viewModel.zones.isEmpty()) {
            CircularProgressIndicator(modifier = Modifier.align(Alignment.CenterHorizontally))
        }

        viewModel.zones.forEach { zone ->
            ThermalZoneRow(zone)
            Spacer(modifier = Modifier.height(4.dp))
        }
    }
}

@Composable
private fun ProfileRow(label: String, value: String) {
    Row(
        modifier = Modifier.fillMaxWidth().padding(vertical = 2.dp),
        horizontalArrangement = Arrangement.SpaceBetween
    ) {
        Text(label, style = MaterialTheme.typography.bodySmall,
            color = MaterialTheme.colorScheme.onSurfaceVariant)
        Text(value, style = MaterialTheme.typography.bodySmall)
    }
}

@Composable
private fun ThermalZoneRow(zone: ThermalZone) {
    val tempColor = when {
        zone.tempC >= 65 -> Color.Red
        zone.tempC >= 55 -> Color(0xFFFF8800)
        zone.tempC >= 45 -> Color(0xFFDDAA00)
        else -> Color(0xFF00AA00)
    }
    Card(modifier = Modifier.fillMaxWidth()) {
        Row(
            modifier = Modifier.padding(12.dp).fillMaxWidth(),
            horizontalArrangement = Arrangement.SpaceBetween,
            verticalAlignment = Alignment.CenterVertically
        ) {
            Column {
                Text(zone.name, style = MaterialTheme.typography.bodySmall)
                Text(zone.type, style = MaterialTheme.typography.labelSmall,
                    color = MaterialTheme.colorScheme.onSurfaceVariant)
            }
            Text(
                "%.1f°C".format(zone.tempC),
                style = MaterialTheme.typography.titleMedium,
                color = tempColor
            )
        }
    }
}
