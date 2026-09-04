// Apex Control — Android app for controlling the apex kernel state machine
// Package: com.apex.control
// Jetpack Compose UI, communicates with apex-bridge via Unix filesystem socket
//
// Architecture (refactored from monolith to layered):
//   data/     — BridgeClient: socket I/O and sysfs reads
//   domain/   — ApexState, ApexRepository, TrustState: immutable model + mapper
//   ui/       — TrustBadge, GateResultsList, ApexControlScreen: Composable components
//
// This is the main Activity. It hosts the Compose hierarchy and delegates
// all data access to ApexRepository.

package com.apex.control

import android.os.Bundle
import androidx.activity.ComponentActivity
import androidx.activity.compose.setContent
import androidx.compose.material3.MaterialTheme
import com.apex.control.ui.ApexControlScreen

class MainActivity : ComponentActivity() {
    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        setContent {
            MaterialTheme {
                ApexControlScreen()
            }
        }
    }
}
