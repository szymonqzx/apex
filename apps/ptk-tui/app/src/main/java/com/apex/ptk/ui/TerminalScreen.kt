package com.apex.ptk.ui

import androidx.compose.foundation.background
import androidx.compose.foundation.layout.*
import androidx.compose.foundation.text.BasicTextField
import androidx.compose.foundation.text.KeyboardOptions
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.filled.*
import androidx.compose.material3.*
import androidx.compose.runtime.*
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.text.TextStyle
import androidx.compose.ui.text.font.FontFamily
import androidx.compose.ui.text.input.ImeAction
import androidx.compose.ui.text.input.KeyboardType
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import androidx.lifecycle.viewmodel.compose.viewModel

/**
 * PTK TUI — Pentest Terminal UI
 *
 * Minimal terminal emulator that connects to the Arch Linux chroot
 * via apex-bridge PTY. Renders raw ANSI output, sends keyboard input.
 *
 * Features:
 * - Connect/disconnect to bridge PTY
 * - Raw text input (enter to send)
 * - Ctrl+C / Ctrl+Z signal buttons
 * - Terminal resize (cols × rows)
 * - Clear screen
 *
 * Shares the same SQLite audit store as Apex Control for session logging.
 */
@OptIn(ExperimentalMaterial3Api::class)
@Composable
fun TerminalScreen(viewModel: TerminalViewModel = viewModel()) {
    val output by viewModel.output.collectAsState()
    val connected by viewModel.connected.collectAsState()
    val cols by viewModel.cols.collectAsState()
    val rows by viewModel.rows.collectAsState()

    var input by remember { mutableStateOf("") }
    var showResizeDialog by remember { mutableStateOf(false) }

    Scaffold(
        topBar = {
            TopAppBar(
                title = { Text("PTK TUI", fontFamily = FontFamily.Monospace) },
                actions = {
                    if (connected) {
                        IconButton(onClick = { viewModel.sendCtrlC() }) {
                            Icon(Icons.Default.Close, contentDescription = "Ctrl+C")
                        }
                        IconButton(onClick = { viewModel.sendCtrlZ() }) {
                            Icon(Icons.Default.PlayArrow, contentDescription = "Ctrl+Z")
                        }
                        IconButton(onClick = { viewModel.clear() }) {
                            Icon(Icons.Default.Clear, contentDescription = "Clear")
                        }
                        IconButton(onClick = { showResizeDialog = true }) {
                            Icon(Icons.Default.Settings, contentDescription = "Resize")
                        }
                        IconButton(onClick = { viewModel.disconnect() }) {
                            Icon(Icons.Default.ExitToApp, contentDescription = "Disconnect")
                        }
                    } else {
                        IconButton(onClick = { viewModel.connect() }) {
                            Icon(Icons.Default.PlayArrow, contentDescription = "Connect")
                        }
                    }
                }
            )
        }
    ) { padding ->
        Column(
            modifier = Modifier
                .fillMaxSize()
                .padding(padding)
                .background(Color(0xFF1E1E1E))
        ) {
            // Terminal output area
            Surface(
                modifier = Modifier
                    .weight(1f)
                    .fillMaxWidth(),
                color = Color(0xFF1E1E1E)
            ) {
                if (!connected && output.isEmpty()) {
                    Box(
                        modifier = Modifier.fillMaxSize(),
                        contentAlignment = Alignment.Center
                    ) {
                        Column(horizontalAlignment = Alignment.CenterHorizontally) {
                            Text(
                                "PTK TUI",
                                color = Color(0xFF00FF00),
                                fontFamily = FontFamily.Monospace,
                                fontSize = 24.sp
                            )
                            Spacer(Modifier.height(8.dp))
                            Text(
                                "Tap connect to start a pentest session",
                                color = Color.Gray,
                                fontSize = 14.sp
                            )
                            Spacer(Modifier.height(16.dp))
                            Button(onClick = { viewModel.connect() }) {
                                Icon(Icons.Default.PlayArrow, contentDescription = null)
                                Spacer(Modifier.width(4.dp))
                                Text("Connect to chroot")
                            }
                        }
                    }
                } else {
                    // Terminal output — raw text rendering
                    // In a full implementation, this would use an ANSI parser
                    // to handle escape sequences (colors, cursor movement, etc.)
                    Text(
                        text = output.toString(),
                        color = Color(0xFF00FF00),
                        fontFamily = FontFamily.Monospace,
                        fontSize = 13.sp,
                        modifier = Modifier
                            .fillMaxSize()
                            .padding(8.dp)
                    )
                }
            }

            // Input bar
            if (connected) {
                Surface(
                    modifier = Modifier.fillMaxWidth(),
                    color = Color(0xFF2D2D2D),
                    tonalElevation = 4.dp
                ) {
                    Row(
                        modifier = Modifier
                            .fillMaxWidth()
                            .padding(8.dp),
                        verticalAlignment = Alignment.CenterVertically
                    ) {
                        Text(
                            "$cols×$rows",
                            color = Color.Gray,
                            fontSize = 11.sp,
                            fontFamily = FontFamily.Monospace,
                            modifier = Modifier.padding(end = 8.dp)
                        )
                        OutlinedTextField(
                            value = input,
                            onValueChange = { input = it },
                            modifier = Modifier.weight(1f),
                            textStyle = TextStyle(
                                color = Color(0xFF00FF00),
                                fontFamily = FontFamily.Monospace,
                                fontSize = 13.sp
                            ),
                            placeholder = { Text("Type command...", color = Color.DarkGray, fontSize = 13.sp) },
                            singleLine = true,
                            keyboardOptions = KeyboardOptions(
                                keyboardType = KeyboardType.Text,
                                imeAction = ImeAction.Send
                            ),
                            trailingIcon = {
                                IconButton(onClick = {
                                    if (input.isNotEmpty()) {
                                        viewModel.sendInput(input + "\n")
                                        input = ""
                                    }
                                }) {
                                    Icon(Icons.Default.Send, contentDescription = "Send", tint = Color(0xFF00FF00))
                                }
                            }
                        )
                    }
                }
            }
        }
    }

    if (showResizeDialog) {
        var newCols by remember { mutableStateOf(cols.toString()) }
        var newRows by remember { mutableStateOf(rows.toString()) }
        AlertDialog(
            onDismissRequest = { showResizeDialog = false },
            title = { Text("Terminal Size") },
            text = {
                Row(
                    horizontalArrangement = Arrangement.spacedBy(8.dp)
                ) {
                    OutlinedTextField(
                        value = newCols,
                        onValueChange = { newCols = it },
                        label = { Text("Cols") },
                        modifier = Modifier.weight(1f)
                    )
                    OutlinedTextField(
                        value = newRows,
                        onValueChange = { newRows = it },
                        label = { Text("Rows") },
                        modifier = Modifier.weight(1f)
                    )
                }
            },
            confirmButton = {
                Button(onClick = {
                    viewModel.resize(newCols.toIntOrNull() ?: 80, newRows.toIntOrNull() ?: 24)
                    showResizeDialog = false
                }) { Text("Apply") }
            },
            dismissButton = { TextButton(onClick = { showResizeDialog = false }) { Text("Cancel") } }
        )
    }
}
