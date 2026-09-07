package com.apex.nfcforge.ui

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
import androidx.lifecycle.viewmodel.compose.viewModel

/**
 * NFCForge Main Screen — guided NFC operations with preview-confirm.
 *
 * Flow: Connect → Detect Card → Read/Write/Clone/Emulate
 * All write operations show a preview dialog before execution.
 */
@OptIn(ExperimentalMaterial3Api::class)
@Composable
fun MainScreen(viewModel: NfcViewModel = viewModel()) {
    val connectionState by viewModel.connectionState.collectAsState()
    val cardInfo by viewModel.cardInfo.collectAsState()
    val result by viewModel.operationResult.collectAsState()
    val auditLog by viewModel.auditLog.collectAsState()
    val isExecuting by viewModel.isExecuting.collectAsState()
    val toolsAvailable by viewModel.toolsAvailable.collectAsState()

    var showWriteDialog by remember { mutableStateOf(false) }
    var showCloneDialog by remember { mutableStateOf(false) }
    var showApduDialog by remember { mutableStateOf(false) }
    var showEmulateDialog by remember { mutableStateOf(false) }

    Scaffold(
        topBar = {
            TopAppBar(
                title = { Text("NFCForge", fontWeight = FontWeight.Bold) },
                actions = {
                    ConnectionIndicator(connectionState)
                }
            )
        }
    ) { padding ->
        Column(
            modifier = Modifier
                .fillMaxSize()
                .padding(padding)
                .padding(16.dp)
        ) {
            // Connection controls
            Card(
                modifier = Modifier.fillMaxWidth(),
                elevation = CardDefaults.cardElevation(defaultElevation = 2.dp)
            ) {
                Column(modifier = Modifier.padding(16.dp)) {
                    Text("Bridge Connection", style = MaterialTheme.typography.titleMedium)
                    Spacer(modifier = Modifier.height(8.dp))
                    Row(
                        modifier = Modifier.fillMaxWidth(),
                        horizontalArrangement = Arrangement.SpaceBetween
                    ) {
                        when (connectionState) {
                            NfcViewModel.ConnectionState.DISCONNECTED,
                            NfcViewModel.ConnectionState.ERROR -> {
                                Button(onClick = { viewModel.connect() }) {
                                    Icon(Icons.Default.Create, contentDescription = null)
                                    Spacer(Modifier.width(4.dp))
                                    Text("Connect")
                                }
                            }
                            NfcViewModel.ConnectionState.CONNECTING -> {
                                CircularProgressIndicator(modifier = Modifier.size(24.dp))
                                Text("Connecting...")
                            }
                            NfcViewModel.ConnectionState.CONNECTED -> {
                                Button(
                                    onClick = { viewModel.disconnect() },
                                    colors = ButtonDefaults.buttonColors(containerColor = MaterialTheme.colorScheme.error)
                                ) {
                                    Icon(Icons.Default.Close, contentDescription = null)
                                    Spacer(Modifier.width(4.dp))
                                    Text("Disconnect")
                                }
                            }
                        }
                    }
                }
            }

            Spacer(modifier = Modifier.height(12.dp))

            // Tool availability
            if (connectionState == NfcViewModel.ConnectionState.CONNECTED && toolsAvailable.isNotEmpty()) {
                Card(modifier = Modifier.fillMaxWidth()) {
                    Column(modifier = Modifier.padding(12.dp)) {
                        Text("Chroot Tools", style = MaterialTheme.typography.titleSmall)
                        toolsAvailable.forEach { (name, available) ->
                            Row(
                                modifier = Modifier.fillMaxWidth(),
                                horizontalArrangement = Arrangement.SpaceBetween
                            ) {
                                Text(name, fontFamily = FontFamily.Monospace)
                                Text(
                                    if (available) "✓" else "✗",
                                    color = if (available) Color(0xFF4CAF50) else Color(0xFFF44336)
                                )
                            }
                        }
                    }
                }
                Spacer(modifier = Modifier.height(12.dp))
            }

            // Card info
            cardInfo?.let { info ->
                Card(
                    modifier = Modifier.fillMaxWidth(),
                    colors = CardDefaults.cardColors(
                        containerColor = if (info.isMagic) Color(0xFF1B5E20) else MaterialTheme.colorScheme.surfaceVariant
                    )
                ) {
                    Column(modifier = Modifier.padding(16.dp)) {
                        Text("Card Detected", style = MaterialTheme.typography.titleMedium)
                        Spacer(modifier = Modifier.height(8.dp))
                        InfoRow("UID", info.uid)
                        InfoRow("Type", info.type)
                        InfoRow("ATQA", info.atqa)
                        InfoRow("SAK", info.sak.toString())
                        InfoRow("Sectors", info.sectors.toString())
                        InfoRow("Magic Card", if (info.isMagic) "YES" else "NO")
                        InfoRow("Writable", if (info.writable) "YES" else "NO")
                    }
                }
                Spacer(modifier = Modifier.height(12.dp))
            }

            // Action buttons
            if (connectionState == NfcViewModel.ConnectionState.CONNECTED) {
                Row(
                    modifier = Modifier.fillMaxWidth(),
                    horizontalArrangement = Arrangement.spacedBy(8.dp)
                ) {
                    Button(
                        onClick = { viewModel.detectCard() },
                        enabled = !isExecuting,
                        modifier = Modifier.weight(1f)
                    ) { Text("Detect") }
                    Button(
                        onClick = { viewModel.readCard() },
                        enabled = !isExecuting && cardInfo != null,
                        modifier = Modifier.weight(1f)
                    ) { Text("Read") }
                }
                Spacer(modifier = Modifier.height(8.dp))
                Row(
                    modifier = Modifier.fillMaxWidth(),
                    horizontalArrangement = Arrangement.spacedBy(8.dp)
                ) {
                    Button(
                        onClick = { viewModel.detectMagic() },
                        enabled = !isExecuting && cardInfo != null,
                        modifier = Modifier.weight(1f)
                    ) { Text("Magic?") }
                    Button(
                        onClick = { showWriteDialog = true },
                        enabled = !isExecuting && cardInfo != null,
                        modifier = Modifier.weight(1f)
                    ) { Text("Write") }
                }
                Spacer(modifier = Modifier.height(8.dp))
                Row(
                    modifier = Modifier.fillMaxWidth(),
                    horizontalArrangement = Arrangement.spacedBy(8.dp)
                ) {
                    Button(
                        onClick = { showEmulateDialog = true },
                        enabled = !isExecuting && cardInfo?.isMagic == true,
                        modifier = Modifier.weight(1f)
                    ) { Text("Emulate") }
                    Button(
                        onClick = { showCloneDialog = true },
                        enabled = !isExecuting && cardInfo != null,
                        modifier = Modifier.weight(1f)
                    ) { Text("Clone") }
                }
                Spacer(modifier = Modifier.height(8.dp))
                Button(
                    onClick = { showApduDialog = true },
                    enabled = !isExecuting && cardInfo != null,
                    modifier = Modifier.fillMaxWidth()
                ) { Text("Raw APDU") }
            }

            // Last result
            result?.let { r ->
                Spacer(modifier = Modifier.height(12.dp))
                Card(
                    modifier = Modifier.fillMaxWidth(),
                    colors = CardDefaults.cardColors(
                        containerColor = if (r.success) Color(0xFF1B5E20) else Color(0xFFB71C1C)
                    )
                ) {
                    Column(modifier = Modifier.padding(12.dp)) {
                        Text(
                            "${r.operation.displayName}: ${if (r.success) "SUCCESS" else "FAILED"}",
                            color = Color.White,
                            fontWeight = FontWeight.Bold
                        )
                        r.error?.let { Text("Error: $it", color = Color.White, fontSize = 12.sp) }
                        r.data?.let {
                            Text(
                                "Data: ${it.take(200)}",
                                color = Color.White,
                                fontSize = 12.sp,
                                fontFamily = FontFamily.Monospace
                            )
                        }
                    }
                }
            }

            // Audit log
            if (auditLog.isNotEmpty()) {
                Spacer(modifier = Modifier.height(12.dp))
                Text("Audit Log", style = MaterialTheme.typography.titleSmall)
                LazyColumn(
                    modifier = Modifier.fillMaxWidth().heightIn(max = 200.dp),
                    verticalArrangement = Arrangement.spacedBy(2.dp)
                ) {
                    items(auditLog.reversed()) { entry ->
                        Text(
                            entry,
                            fontSize = 11.sp,
                            fontFamily = FontFamily.Monospace,
                            modifier = Modifier
                                .fillMaxWidth()
                                .background(MaterialTheme.colorScheme.surfaceVariant, RoundedCornerShape(4.dp))
                                .padding(4.dp)
                        )
                    }
                }
            }
        }
    }

    // Dialogs
    if (showWriteDialog) {
        WriteDialog(
            onDismiss = { showWriteDialog = false },
            onConfirm = { sector, block, data, key ->
                viewModel.writeBlock(sector, block, data, key)
                showWriteDialog = false
            }
        )
    }
    if (showCloneDialog) {
        CloneDialog(
            onDismiss = { showCloneDialog = false },
            onConfirm = { targetUid ->
                viewModel.cloneCard(targetUid)
                showCloneDialog = false
            }
        )
    }
    if (showApduDialog) {
        ApduDialog(
            onDismiss = { showApduDialog = false },
            onConfirm = { apdu ->
                viewModel.sendApdu(apdu)
                showApduDialog = false
            }
        )
    }
    if (showEmulateDialog) {
        EmulateDialog(
            onDismiss = { showEmulateDialog = false },
            onConfirm = { newUid ->
                viewModel.emulateUid(newUid)
                showEmulateDialog = false
            }
        )
    }
}

@Composable
private fun ConnectionIndicator(state: NfcViewModel.ConnectionState) {
    val (color, label) = when (state) {
        NfcViewModel.ConnectionState.DISCONNECTED -> Color.Gray to "Offline"
        NfcViewModel.ConnectionState.CONNECTING -> Color(0xFFFFA000) to "Connecting"
        NfcViewModel.ConnectionState.CONNECTED -> Color(0xFF4CAF50) to "Online"
        NfcViewModel.ConnectionState.ERROR -> Color(0xFFF44336) to "Error"
    }
    Row(verticalAlignment = Alignment.CenterVertically) {
        Box(modifier = Modifier
            .size(10.dp)
            .background(color, RoundedCornerShape(50)))
        Spacer(Modifier.width(4.dp))
        Text(label, fontSize = 12.sp)
    }
}

@Composable
private fun InfoRow(label: String, value: String) {
    Row(
        modifier = Modifier.fillMaxWidth(),
        horizontalArrangement = Arrangement.SpaceBetween
    ) {
        Text(label, color = MaterialTheme.colorScheme.onSurfaceVariant)
        Text(value, fontFamily = FontFamily.Monospace, fontWeight = FontWeight.Medium)
    }
}

@Composable
private fun WriteDialog(
    onDismiss: () -> Unit,
    onConfirm: (Int, Int, String, String) -> Unit
) {
    var sector by remember { mutableStateOf("0") }
    var block by remember { mutableStateOf("0") }
    var data by remember { mutableStateOf("") }
    var key by remember { mutableStateOf("FFFFFFFFFFFF") }

    AlertDialog(
        onDismissRequest = onDismiss,
        title = { Text("Write Block") },
        text = {
            Column {
                Text("⚠ This will modify the card. Review carefully.", color = Color(0xFFFFA000))
                Spacer(Modifier.height(8.dp))
                OutlinedTextField(value = sector, onValueChange = { sector = it }, label = { Text("Sector") })
                Spacer(Modifier.height(4.dp))
                OutlinedTextField(value = block, onValueChange = { block = it }, label = { Text("Block") })
                Spacer(Modifier.height(4.dp))
                OutlinedTextField(value = data, onValueChange = { data = it }, label = { Text("Data (hex)") })
                Spacer(Modifier.height(4.dp))
                OutlinedTextField(value = key, onValueChange = { key = it }, label = { Text("Key (hex)") })
            }
        },
        confirmButton = { Button(onClick = { onConfirm(sector.toIntOrNull() ?: 0, block.toIntOrNull() ?: 0, data, key) }) { Text("Write") } },
        dismissButton = { TextButton(onClick = onDismiss) { Text("Cancel") } }
    )
}

@Composable
private fun CloneDialog(
    onDismiss: () -> Unit,
    onConfirm: (String) -> Unit
) {
    var targetUid by remember { mutableStateOf("") }
    AlertDialog(
        onDismissRequest = onDismiss,
        title = { Text("Clone Card") },
        text = {
            Column {
                Text("⚠ This will copy all data from detected card to the target magic card.", color = Color(0xFFFFA000))
                Spacer(Modifier.height(8.dp))
                OutlinedTextField(value = targetUid, onValueChange = { targetUid = it }, label = { Text("Target Card UID") })
            }
        },
        confirmButton = { Button(onClick = { onConfirm(targetUid) }) { Text("Clone") } },
        dismissButton = { TextButton(onClick = onDismiss) { Text("Cancel") } }
    )
}

@Composable
private fun ApduDialog(
    onDismiss: () -> Unit,
    onConfirm: (String) -> Unit
) {
    var apdu by remember { mutableStateOf("") }
    AlertDialog(
        onDismissRequest = onDismiss,
        title = { Text("Send Raw APDU") },
        text = {
            Column {
                Text("⚠ Raw APDU can damage the card. Know what you're sending.", color = Color(0xFFFFA000))
                Spacer(Modifier.height(8.dp))
                OutlinedTextField(value = apdu, onValueChange = { apdu = it }, label = { Text("APDU (hex)") })
            }
        },
        confirmButton = { Button(onClick = { onConfirm(apdu) }) { Text("Send") } },
        dismissButton = { TextButton(onClick = onDismiss) { Text("Cancel") } }
    )
}

@Composable
private fun EmulateDialog(
    onDismiss: () -> Unit,
    onConfirm: (String) -> Unit
) {
    var newUid by remember { mutableStateOf("") }
    AlertDialog(
        onDismissRequest = onDismiss,
        title = { Text("Emulate UID") },
        text = {
            Column {
                Text("Write a new UID to the magic card.", color = Color(0xFFFFA000))
                Spacer(Modifier.height(8.dp))
                OutlinedTextField(value = newUid, onValueChange = { newUid = it }, label = { Text("New UID (hex)") })
            }
        },
        confirmButton = { Button(onClick = { onConfirm(newUid) }) { Text("Write UID") } },
        dismissButton = { TextButton(onClick = onDismiss) { Text("Cancel") } }
    )
}
