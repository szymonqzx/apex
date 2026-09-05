package com.apex.control.poweruser

import androidx.compose.foundation.background
import androidx.compose.foundation.layout.*
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
import androidx.lifecycle.viewmodel.compose.viewModel
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asStateFlow
import kotlinx.coroutines.launch
import kotlinx.coroutines.withContext
import java.io.File

/**
 * Bridge Status Screen — shows the status of the chroot/bridge subsystem:
 * - apex-bridge daemon (running/stopped)
 * - Arch Linux chroot (mounted/unmounted)
 * - Lindroid container (running/stopped, if migrated)
 * - Bridge socket connectivity
 * - Chroot disk usage
 * - Installed packages count
 *
 * Part of Phase 10 Apex Control completion (audit #15).
 */
@OptIn(ExperimentalMaterial3Api::class)
@Composable
fun BridgeStatusScreen(viewModel: BridgeStatusViewModel = viewModel()) {
    val status by viewModel.status.collectAsState()
    val isLoading by viewModel.isLoading.collectAsState()

    Scaffold(
        topBar = {
            TopAppBar(
                title = { Text("Bridge & Chroot", fontWeight = FontWeight.Bold) },
                actions = {
                    IconButton(onClick = { viewModel.refresh() }) {
                        Icon(Icons.Default.Refresh, contentDescription = "Refresh")
                    }
                }
            )
        }
    ) { padding ->
        if (isLoading) {
            Box(
                modifier = Modifier.fillMaxSize().padding(padding),
                contentAlignment = Alignment.Center
            ) {
                CircularProgressIndicator()
            }
            return@Scaffold
        }

        Column(
            modifier = Modifier
                .fillMaxSize()
                .padding(padding)
                .padding(16.dp),
            verticalArrangement = Arrangement.spacedBy(12.dp)
        ) {
            // Bridge daemon status
            StatusCard(
                title = "apex-bridge Daemon",
                icon = Icons.Default.Router,
                running = status.bridgeRunning,
                details = listOf(
                    "PID" to status.bridgePid,
                    "Socket" to "localhost:${status.bridgePort}",
                    "Uptime" to status.bridgeUptime
                )
            )

            // Chroot status
            StatusCard(
                title = "Arch Linux Chroot",
                icon = Icons.Default.Terminal,
                running = status.chrootMounted,
                details = listOf(
                    "Path" to status.chrootPath,
                    "Disk Usage" to status.chrootDiskUsage,
                    "Packages" to status.chrootPackages
                )
            )

            // Lindroid container status
            StatusCard(
                title = "Lindroid Container",
                icon = Icons.Default.DesktopWindows,
                running = status.lindroidRunning,
                details = listOf(
                    "Container IP" to status.lindroidIp,
                    "Display" to status.lindroidDisplay,
                    "Status" to (if (status.lindroidRunning) "Running" else "Stopped")
                )
            )

            // Bridge socket test
            Card(
                modifier = Modifier.fillMaxWidth(),
                elevation = CardDefaults.cardElevation(defaultElevation = 1.dp)
            ) {
                Column(modifier = Modifier.padding(16.dp)) {
                    Text("Bridge Connectivity", style = MaterialTheme.typography.titleSmall)
                    Spacer(Modifier.height(8.dp))
                    val socketColor = if (status.bridgeSocketOk) Color(0xFF4CAF50) else Color(0xFFF44336)
                    Row(verticalAlignment = Alignment.CenterVertically) {
                        Box(modifier = Modifier
                            .size(8.dp)
                            .background(socketColor, RoundedCornerShape(50)))
                        Spacer(Modifier.width(8.dp))
                        Text(
                            if (status.bridgeSocketOk) "Socket reachable" else "Socket unreachable",
                            fontFamily = FontFamily.Monospace
                        )
                    }
                    Spacer(Modifier.height(4.dp))
                    Text(
                        "NFC tools: ${status.nfcToolsAvailable.joinToString(", ")}",
                        fontSize = 11.sp,
                        color = MaterialTheme.colorScheme.onSurfaceVariant
                    )
                }
            }

            // Actions
            Row(
                modifier = Modifier.fillMaxWidth(),
                horizontalArrangement = Arrangement.spacedBy(8.dp)
            ) {
                Button(
                    onClick = { viewModel.startBridge() },
                    enabled = !status.bridgeRunning,
                    modifier = Modifier.weight(1f)
                ) { Text("Start Bridge") }
                Button(
                    onClick = { viewModel.stopBridge() },
                    enabled = status.bridgeRunning,
                    modifier = Modifier.weight(1f),
                    colors = ButtonDefaults.buttonColors(containerColor = MaterialTheme.colorScheme.error)
                ) { Text("Stop Bridge") }
            }
            Row(
                modifier = Modifier.fillMaxWidth(),
                horizontalArrangement = Arrangement.spacedBy(8.dp)
            ) {
                Button(
                    onClick = { viewModel.mountChroot() },
                    enabled = !status.chrootMounted,
                    modifier = Modifier.weight(1f)
                ) { Text("Mount Chroot") }
                Button(
                    onClick = { viewModel.unmountChroot() },
                    enabled = status.chrootMounted,
                    modifier = Modifier.weight(1f),
                    colors = ButtonDefaults.buttonColors(containerColor = MaterialTheme.colorScheme.error)
                ) { Text("Unmount") }
            }
        }
    }
}

@Composable
private fun StatusCard(
    title: String,
    icon: androidx.compose.ui.graphics.vector.ImageVector,
    running: Boolean,
    details: List<Pair<String, String>>
) {
    val statusColor = if (running) Color(0xFF4CAF50) else Color(0xFF9E9E9E)
    Card(
        modifier = Modifier.fillMaxWidth(),
        elevation = CardDefaults.cardElevation(defaultElevation = 1.dp)
    ) {
        Column(modifier = Modifier.padding(16.dp)) {
            Row(verticalAlignment = Alignment.CenterVertically) {
                Icon(icon, contentDescription = null, tint = statusColor)
                Spacer(Modifier.width(8.dp))
                Text(title, style = MaterialTheme.typography.titleSmall, fontWeight = FontWeight.Bold)
                Spacer(Modifier.weight(1f))
                Box(modifier = Modifier
                    .size(8.dp)
                    .background(statusColor, RoundedCornerShape(50)))
                Spacer(Modifier.width(4.dp))
                Text(if (running) "Running" else "Stopped", fontSize = 12.sp, color = statusColor)
            }
            Spacer(Modifier.height(8.dp))
            details.forEach { (label, value) ->
                Row(
                    modifier = Modifier.fillMaxWidth(),
                    horizontalArrangement = Arrangement.SpaceBetween
                ) {
                    Text(label, fontSize = 12.sp, color = MaterialTheme.colorScheme.onSurfaceVariant)
                    Text(value, fontSize = 12.sp, fontFamily = FontFamily.Monospace)
                }
            }
        }
    }
}

// ── ViewModel ───────────────────────────────────────────────────────

data class BridgeStatus(
    val bridgeRunning: Boolean = false,
    val bridgePid: String = "—",
    val bridgePort: String = "9877",
    val bridgeUptime: String = "—",
    val bridgeSocketOk: Boolean = false,
    val chrootMounted: Boolean = false,
    val chrootPath: String = "/data/adb/apex/arch",
    val chrootDiskUsage: String = "—",
    val chrootPackages: String = "—",
    val lindroidRunning: Boolean = false,
    val lindroidIp: String = "—",
    val lindroidDisplay: String = "—",
    val nfcToolsAvailable: List<String> = emptyList()
)

class BridgeStatusViewModel : ViewModel() {

    private val _status = MutableStateFlow(BridgeStatus())
    val status: StateFlow<BridgeStatus> = _status.asStateFlow()

    private val _isLoading = MutableStateFlow(false)
    val isLoading: StateFlow<Boolean> = _isLoading.asStateFlow()

    init { refresh() }

    fun refresh() {
        _isLoading.value = true
        viewModelScope.launch(Dispatchers.IO) {
            _status.value = probeStatus()
            _isLoading.value = false
        }
    }

    fun startBridge() {
        viewModelScope.launch(Dispatchers.IO) {
            runShell("setprop persist.sys.apex.bridge_enabled 1")
            // Wait briefly then refresh
            Thread.sleep(1000)
            refresh()
        }
    }

    fun stopBridge() {
        viewModelScope.launch(Dispatchers.IO) {
            runShell("setprop persist.sys.apex.bridge_enabled 0")
            Thread.sleep(500)
            refresh()
        }
    }

    fun mountChroot() {
        viewModelScope.launch(Dispatchers.IO) {
            runShell("/system/bin/apex-term.sh --mount-only 2>/dev/null || true")
            Thread.sleep(1000)
            refresh()
        }
    }

    fun unmountChroot() {
        viewModelScope.launch(Dispatchers.IO) {
            runShell("umount /data/adb/apex/arch/proc 2>/dev/null; umount /data/adb/apex/arch/sys 2>/dev/null; umount /data/adb/apex/arch/dev 2>/dev/null || true")
            Thread.sleep(500)
            refresh()
        }
    }

    private suspend fun probeStatus(): BridgeStatus = withContext(Dispatchers.IO) {
        // Check bridge daemon
        val bridgePid = runShell("pidof apex-bridge 2>/dev/null || echo ''").trim()
        val bridgeRunning = bridgePid.isNotEmpty()
        val bridgeUptime = if (bridgeRunning) {
            runShell("ps -o etime= -p $bridgePid 2>/dev/null || echo '—'").trim()
        } else "—"

        // Check socket
        val socketOk = runShell("echo test | nc -w 1 127.0.0.1 9877 2>/dev/null && echo ok || echo fail").trim() == "ok"

        // Check chroot
        val chrootPath = "/data/adb/apex/arch"
        val chrootMounted = File("$chrootPath/proc").exists() && File("$chrootPath/dev").exists()
        val chrootDiskUsage = runShell("du -sh $chrootPath 2>/dev/null | cut -f1 || echo '—'").trim()
        val chrootPackages = runShell("ls $chrootPath/var/lib/pacman/local/ 2>/dev/null | wc -l || echo '—'").trim()

        // Check Lindroid
        val lindroidPid = runShell("pidof lindroid-init 2>/dev/null || echo ''").trim()
        val lindroidRunning = lindroidPid.isNotEmpty()
        val lindroidIp = if (lindroidRunning) runShell("getprop persist.sys.apex.lindroid_ip 2>/dev/null || echo '—'").trim() else "—"
        val lindroidDisplay = if (lindroidRunning) ":0" else "—"

        // Check NFC tools
        val nfcTools = mutableListOf<String>()
        if (File("$chrootPath/usr/bin/mfoc").exists()) nfcTools.add("mfoc")
        if (File("$chrootPath/usr/bin/mfcuk").exists()) nfcTools.add("mfcuk")
        if (File("$chrootPath/usr/bin/crapto1").exists()) nfcTools.add("crapto1")
        if (nfcTools.isEmpty()) nfcTools.add("(none)")

        BridgeStatus(
            bridgeRunning = bridgeRunning,
            bridgePid = if (bridgeRunning) bridgePid else "—",
            bridgeUptime = bridgeUptime,
            bridgeSocketOk = socketOk,
            chrootMounted = chrootMounted,
            chrootPath = chrootPath,
            chrootDiskUsage = chrootDiskUsage,
            chrootPackages = chrootPackages,
            lindroidRunning = lindroidRunning,
            lindroidIp = lindroidIp,
            lindroidDisplay = lindroidDisplay,
            nfcToolsAvailable = nfcTools
        )
    }

    private fun runShell(cmd: String): String = try {
        val proc = ProcessBuilder("sh", "-c", cmd)
            .redirectErrorStream(true)
            .start()
        val output = proc.inputStream.bufferedReader().readText()
        proc.waitFor()
        output.trim()
    } catch (e: Exception) {
        ""
    }
}
