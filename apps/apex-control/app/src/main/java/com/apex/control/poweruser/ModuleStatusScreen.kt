package com.apex.control.poweruser

import androidx.compose.foundation.background
import androidx.compose.foundation.layout.*
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.items
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.filled.*
import androidx.compose.material3.*
import androidx.compose.runtime.*
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.text.font.FontFamily
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import androidx.lifecycle.ViewModel
import androidx.lifecycle.viewModelScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asStateFlow
import kotlinx.coroutines.launch
import kotlinx.coroutines.withContext
import java.io.File

/**
 * Module Status Screen — shows loaded kernel modules (.ko files),
 * their sizes, and whether they're currently loaded (lsmod).
 *
 * Part of Phase 10 Apex Control completion (audit #15).
 */
@OptIn(ExperimentalMaterial3Api::class)
@Composable
fun ModuleStatusScreen(viewModel: ModuleStatusViewModel = androidx.lifecycle.viewmodel.compose.viewModel()) {
    val modules by viewModel.modules.collectAsState()
    val isLoading by viewModel.isLoading.collectAsState()
    val filter by viewModel.filter.collectAsState()

    Scaffold(
        topBar = {
            TopAppBar(
                title = { Text("Kernel Modules", fontWeight = FontWeight.Bold) },
                actions = {
                    IconButton(onClick = { viewModel.refresh() }) {
                        Icon(Icons.Default.Refresh, contentDescription = "Refresh")
                    }
                }
            )
        }
    ) { padding ->
        Column(
            modifier = Modifier
                .fillMaxSize()
                .padding(padding)
        ) {
            // Filter chips
            Row(
                modifier = Modifier
                    .fillMaxWidth()
                    .padding(horizontal = 12.dp, vertical = 8.dp),
                horizontalArrangement = Arrangement.spacedBy(8.dp)
            ) {
                FilterChip(
                    selected = filter == ModuleFilter.ALL,
                    onClick = { viewModel.setFilter(ModuleFilter.ALL) },
                    label = { Text("All") }
                )
                FilterChip(
                    selected = filter == ModuleFilter.LOADED,
                    onClick = { viewModel.setFilter(ModuleFilter.LOADED) },
                    label = { Text("Loaded") }
                )
                FilterChip(
                    selected = filter == ModuleFilter.PENTEST,
                    onClick = { viewModel.setFilter(ModuleFilter.PENTEST) },
                    label = { Text("Pentest") }
                )
                FilterChip(
                    selected = filter == ModuleFilter.APEX,
                    onClick = { viewModel.setFilter(ModuleFilter.APEX) },
                    label = { Text("APEX") }
                )
            }

            if (isLoading) {
                Box(
                    modifier = Modifier.fillMaxSize(),
                    contentAlignment = Alignment.Center
                ) {
                    CircularProgressIndicator()
                }
            } else if (modules.isEmpty()) {
                Box(
                    modifier = Modifier.fillMaxSize(),
                    contentAlignment = Alignment.Center
                ) {
                    Text("No modules found", color = MaterialTheme.colorScheme.onSurfaceVariant)
                }
            } else {
                LazyColumn(
                    modifier = Modifier.fillMaxSize(),
                    contentPadding = PaddingValues(12.dp),
                    verticalArrangement = Arrangement.spacedBy(4.dp)
                ) {
                    items(modules) { module ->
                        ModuleRow(module)
                    }
                }
            }
        }
    }
}

@Composable
private fun ModuleRow(module: ModuleInfo) {
    val statusColor = when (module.status) {
        ModuleStatus.LOADED -> Color(0xFF4CAF50)
        ModuleStatus.AVAILABLE -> Color(0xFFFFA000)
        ModuleStatus.NOT_FOUND -> Color(0xFF9E9E9E)
        ModuleStatus.ERROR -> Color(0xFFF44336)
    }

    Card(
        modifier = Modifier.fillMaxWidth(),
        elevation = CardDefaults.cardElevation(defaultElevation = 1.dp)
    ) {
        Row(
            modifier = Modifier
                .fillMaxWidth()
                .padding(12.dp),
            verticalAlignment = Alignment.CenterVertically
        ) {
            // Status indicator
            Box(
                modifier = Modifier
                    .size(8.dp)
                    .background(statusColor, RoundedCornerShape(50))
            )
            Spacer(Modifier.width(12.dp))
            // Module info
            Column(modifier = Modifier.weight(1f)) {
                Text(
                    module.name,
                    fontFamily = FontFamily.Monospace,
                    fontWeight = FontWeight.Medium,
                    fontSize = 14.sp
                )
                Text(
                    module.description,
                    fontSize = 11.sp,
                    color = MaterialTheme.colorScheme.onSurfaceVariant
                )
            }
            // Size
            module.size?.let {
                Text(
                    it,
                    fontSize = 11.sp,
                    fontFamily = FontFamily.Monospace,
                    color = MaterialTheme.colorScheme.onSurfaceVariant
                )
            }
        }
    }
}

// ── ViewModel ───────────────────────────────────────────────────────

enum class ModuleFilter { ALL, LOADED, PENTEST, APEX }
enum class ModuleStatus { LOADED, AVAILABLE, NOT_FOUND, ERROR }

data class ModuleInfo(
    val name: String,
    val path: String,
    val status: ModuleStatus,
    val size: String?,
    val description: String,
    val category: String // "pentest", "apex", "standard"
)

class ModuleStatusViewModel : ViewModel() {

    private val _modules = MutableStateFlow<List<ModuleInfo>>(emptyList())
    val modules: StateFlow<List<ModuleInfo>> = _modules.asStateFlow()

    private val _isLoading = MutableStateFlow(false)
    val isLoading: StateFlow<Boolean> = _isLoading.asStateFlow()

    private val _filter = MutableStateFlow(ModuleFilter.ALL)
    val filter: StateFlow<ModuleFilter> = _filter.asStateFlow()

    private var allModules: List<ModuleInfo> = emptyList()

    init {
        refresh()
    }

    fun setFilter(f: ModuleFilter) {
        _filter.value = f
        applyFilter()
    }

    fun refresh() {
        _isLoading.value = true
        viewModelScope.launch(Dispatchers.IO) {
            allModules = loadModules()
            applyFilter()
            _isLoading.value = false
        }
    }

    private fun applyFilter() {
        val f = _filter.value
        _modules.value = when (f) {
            ModuleFilter.ALL -> allModules
            ModuleFilter.LOADED -> allModules.filter { it.status == ModuleStatus.LOADED }
            ModuleFilter.PENTEST -> allModules.filter { it.category == "pentest" }
            ModuleFilter.APEX -> allModules.filter { it.category == "apex" }
        }
    }

    private suspend fun loadModules(): List<ModuleInfo> = withContext(Dispatchers.IO) {
        val result = mutableListOf<ModuleInfo>()

        // Read loaded modules from /proc/modules
        val loadedModules = try {
            File("/proc/modules").readLines().associate { line ->
                val parts = line.split(Regex("\\s+"))
                parts[0] to parts[1] // name → size (in modules)
            }
        } catch (e: Exception) {
            emptyMap()
        }

        // Check pentest driver modules
        val pentestDrivers = listOf(
            "8812au" to "RTL8812AU Wi-Fi adapter (monitor mode + injection)",
            "8814au" to "RTL8814AU Wi-Fi adapter (monitor mode + injection)",
            "88x2bu" to "RTL88x2BU Wi-Fi adapter (monitor mode)",
            "8188eu" to "RTL8188EUS Wi-Fi adapter (monitor mode)",
            "mt7610u" to "MediaTek MT7610U Wi-Fi adapter",
            "mt7612u" to "MediaTek MT7612U Wi-Fi adapter",
            "ath9k_htc" to "Atheros 9k HTC Wi-Fi (monitor + injection)",
            "carl9170" to "Carl9170 Wi-Fi (monitor + injection)",
            "rtl8187" to "RTL8187 Wi-Fi (monitor + injection)",
            "rtl28xxu" to "RTL-SDR (software defined radio)",
            "hackrf" to "HackRF SDR",
            "airspy" to "AirSpy SDR",
            "gs_usb" to "SocketCAN GS USB (CAN bus)",
            "peak_usb" to "SocketCAN PEAK USB (CAN bus)",
            "ch341" to "CH341 USB serial",
            "ftdi_sio" to "FTDI USB serial",
            "cp210x" to "CP210x USB serial",
            "pl2303" to "Prolific PL2303 USB serial",
            "lirc_dev" to "LIRC (infrared)",
            "ir_toy" to "Infrared Toy"
        )

        for ((name, desc) in pentestDrivers) {
            val loaded = loadedModules.containsKey(name)
            val modulePath = "/system/lib/modules/${name}.ko"
            val available = File(modulePath).exists() || loaded
            val status = when {
                loaded -> ModuleStatus.LOADED
                available -> ModuleStatus.AVAILABLE
                else -> ModuleStatus.NOT_FOUND
            }
            val size = loadedModules[name]?.let { "${it} modules" }
            result.add(ModuleInfo(name, modulePath, status, size, desc, "pentest"))
        }

        // Check APEX kernel modules
        val apexModules = listOf(
            "apex_sysfs" to "APEX sysfs control plane (/sys/class/apex/)",
            "bq2589x_charger" to "APEX charge manager (JEITA + ICC mitigation)",
            "baseband_guard" to "Baseband Guard (anti-brick LSM)",
            "susfs" to "SuSFS (root hiding filesystem)",
            "kernelsu" to "KernelSU-Next (root + module support)"
        )

        for ((name, desc) in apexModules) {
            val loaded = loadedModules.containsKey(name)
            val status = if (loaded) ModuleStatus.LOADED else ModuleStatus.NOT_FOUND
            val size = loadedModules[name]?.let { "${it} modules" }
            result.add(ModuleInfo(name, "/proc/modules", status, size, desc, "apex"))
        }

        result.sortedWith(compareBy({ it.category }, { it.name }))
    }
}
