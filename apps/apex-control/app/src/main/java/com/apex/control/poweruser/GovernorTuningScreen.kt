/*
 * GovernorTuningScreen.kt
 *
 * Apex Control screen for CPU governor tuning.
 * Allows user to:
 *   - Select governor per cluster (big/LITTLE)
 *   - Set min/max frequency per cluster
 *   - View current governor and frequencies
 *   - Apply changes (writes to sysfs)
 *
 * Clusters on SM6225-AD (topaz):
 *   - Big: Cortex-A73 (4 cores) — /sys/devices/system/cpu/cpu4-7/cpufreq/
 *   - LITTLE: Cortex-A53 (4 cores) — /sys/devices/system/cpu/cpu0-3/cpufreq/
 *
 * Governors available: schedhorizon, schedutil, performance, powersave, ondemand
 */

package com.apex.control.poweruser

import androidx.compose.foundation.layout.*
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.verticalScroll
import androidx.compose.material3.*
import androidx.compose.runtime.*
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.unit.dp
import androidx.lifecycle.ViewModel
import androidx.lifecycle.viewModelScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.launch
import kotlinx.coroutines.withContext

data class ClusterInfo(
    val name: String,
    val cores: String,
    val governor: String,
    val minFreq: Int,
    val maxFreq: Int,
    val availableFreqs: List<Int>,
    val availableGovernors: List<String>,
    val sysfsPath: String
)

class GovernorViewModel : ViewModel() {
    var bigCluster by mutableStateOf<ClusterInfo?>(null)
        private set
    var littleCluster by mutableStateOf<ClusterInfo?>(null)
        private set
    var isLoading by mutableStateOf(false)
        private set
    var message by mutableStateOf("")
        private set

    fun loadClusters() {
        viewModelScope.launch(Dispatchers.IO) {
            isLoading = true
            try {
                bigCluster = readCluster("Big (A73)", "cpu4", "/sys/devices/system/cpu/cpu4/cpufreq")
                littleCluster = readCluster("LITTLE (A53)", "cpu0", "/sys/devices/system/cpu/cpu0/cpufreq")
            } catch (e: Exception) {
                message = "Error: ${e.message}"
            }
            isLoading = false
        }
    }

    fun applyGovernor(cluster: ClusterInfo, governor: String) {
        viewModelScope.launch(Dispatchers.IO) {
            try {
                val path = "${cluster.sysfsPath}/scaling_governor"
                withContext(Dispatchers.IO) {
                    java.io.File(path).writeText(governor)
                }
                message = "Governor set to $governor on ${cluster.name}"
                loadClusters()
            } catch (e: Exception) {
                message = "Failed: ${e.message}"
            }
        }
    }

    fun applyFreqRange(cluster: ClusterInfo, min: Int, max: Int) {
        viewModelScope.launch(Dispatchers.IO) {
            try {
                withContext(Dispatchers.IO) {
                    java.io.File("${cluster.sysfsPath}/scaling_min_freq").writeText(min.toString())
                    java.io.File("${cluster.sysfsPath}/scaling_max_freq").writeText(max.toString())
                }
                message = "Frequency range set: $min-$max kHz on ${cluster.name}"
                loadClusters()
            } catch (e: Exception) {
                message = "Failed: ${e.message}"
            }
        }
    }

    private fun readCluster(name: String, cores: String, path: String): ClusterInfo {
        val governor = readFile("$path/scaling_governor") ?: "unknown"
        val minFreq = readFile("$path/scaling_min_freq")?.toIntOrNull() ?: 0
        val maxFreq = readFile("$path/scaling_max_freq")?.toIntOrNull() ?: 0
        val availFreqs = readFile("$path/scaling_available_frequencies")
            ?.split(" ")
            ?.mapNotNull { it.trim().toIntOrNull() }
            ?: emptyList()
        val availGovs = readFile("$path/scaling_available_governors")
            ?.split(" ")
            ?.map { it.trim() }
            ?.filter { it.isNotEmpty() }
            ?: listOf("schedutil", "performance", "powersave")
        return ClusterInfo(name, cores, governor, minFreq, maxFreq, availFreqs, availGovs, path)
    }

    private fun readFile(path: String): String? {
        return try {
            java.io.File(path).readText().trim()
        } catch (e: Exception) {
            null
        }
    }
}

@Composable
fun GovernorTuningScreen(viewModel: GovernorViewModel = androidx.lifecycle.viewmodel.compose.viewModel()) {
    LaunchedEffect(Unit) { viewModel.loadClusters() }

    Column(
        modifier = Modifier
            .fillMaxSize()
            .padding(16.dp)
            .verticalScroll(rememberScrollState())
    ) {
        Text("Governor Tuning", style = MaterialTheme.typography.headlineMedium)
        Spacer(modifier = Modifier.height(8.dp))
        Text(
            "CPU governor and frequency control per cluster.",
            style = MaterialTheme.typography.bodyMedium,
            color = MaterialTheme.colorScheme.onSurfaceVariant
        )
        Spacer(modifier = Modifier.height(16.dp))

        if (viewModel.isLoading) {
            CircularProgressIndicator(modifier = Modifier.align(Alignment.CenterHorizontally))
        }

        viewModel.bigCluster?.let { cluster ->
            ClusterCard(cluster, viewModel)
            Spacer(modifier = Modifier.height(12.dp))
        }
        viewModel.littleCluster?.let { cluster ->
            ClusterCard(cluster, viewModel)
        }

        if (viewModel.message.isNotEmpty()) {
            Spacer(modifier = Modifier.height(16.dp))
            Card {
                Text(
                    viewModel.message,
                    modifier = Modifier.padding(12.dp),
                    style = MaterialTheme.typography.bodySmall
                )
            }
        }
    }
}

@Composable
private fun ClusterCard(cluster: ClusterInfo, viewModel: GovernorViewModel) {
    var selectedGovernor by remember(cluster) { mutableStateOf(cluster.governor) }
    var minFreq by remember(cluster) { mutableStateOf(cluster.minFreq) }
    var maxFreq by remember(cluster) { mutableStateOf(cluster.maxFreq) }

    Card(modifier = Modifier.fillMaxWidth()) {
        Column(modifier = Modifier.padding(16.dp)) {
            Text("${cluster.name} — ${cluster.cores}", style = MaterialTheme.typography.titleMedium)
            Spacer(modifier = Modifier.height(4.dp))
            Text("Current: ${cluster.governor} | ${cluster.minFreq / 1000}-${cluster.maxFreq / 1000} MHz",
                style = MaterialTheme.typography.bodySmall,
                color = MaterialTheme.colorScheme.onSurfaceVariant)

            Spacer(modifier = Modifier.height(12.dp))

            // Governor selector
            Text("Governor", style = MaterialTheme.typography.labelMedium)
            Row(
                modifier = Modifier.fillMaxWidth(),
                horizontalArrangement = Arrangement.spacedBy(8.dp)
            ) {
                cluster.availableGovernors.take(6).forEach { gov ->
                    FilterChip(
                        selected = selectedGovernor == gov,
                        onClick = {
                            selectedGovernor = gov
                            viewModel.applyGovernor(cluster, gov)
                        },
                        label = { Text(gov) }
                    )
                }
            }

            Spacer(modifier = Modifier.height(12.dp))

            // Frequency range
            if (cluster.availableFreqs.isNotEmpty()) {
                Text("Min: ${(minFreq / 1000)} MHz | Max: ${(maxFreq / 1000)} MHz",
                    style = MaterialTheme.typography.bodySmall)

                val freqRange = cluster.availableFreqs.min()..cluster.availableFreqs.max()
                Row(
                    modifier = Modifier.fillMaxWidth(),
                    horizontalArrangement = Arrangement.spacedBy(8.dp)
                ) {
                    OutlinedButton(
                        onClick = {
                            minFreq = freqRange.first
                            viewModel.applyFreqRange(cluster, minFreq, maxFreq)
                        }
                    ) { Text("Min") }
                    OutlinedButton(
                        onClick = {
                            maxFreq = freqRange.last
                            viewModel.applyFreqRange(cluster, minFreq, maxFreq)
                        }
                    ) { Text("Max") }
                    OutlinedButton(
                        onClick = {
                            minFreq = freqRange.first
                            maxFreq = freqRange.last
                            viewModel.applyFreqRange(cluster, minFreq, maxFreq)
                        }
                    ) { Text("Full Range") }
                }
            }
        }
    }
}
