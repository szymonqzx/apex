package com.apex.control.ui

import androidx.compose.foundation.layout.*
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material3.*
import androidx.compose.runtime.Composable
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.dp
import com.apex.control.domain.TrustGateSummary
import com.apex.control.domain.TrustState

/**
 * UI layer: trust badge component.
 *
 * Displays the current certification state as a color-coded badge.
 * Green for CERTIFIED/CERTIFIED_WITH_WAIVERS, amber for PARTIAL/CANDIDATE,
 * red for FAILED, gray for UNKNOWN/UNVERIFIED.
 */
@Composable
fun TrustBadge(
    state: TrustState,
    manifestHash: String,
    modifier: Modifier = Modifier,
) {
    val (bgColor, fgColor) = when {
        state.isCertified -> Color(0xFF1B5E20) to Color.White
        state == TrustState.FAILED -> Color(0xFFB71C1C) to Color.White
        state == TrustState.PARTIAL || state == TrustState.CANDIDATE ->
            Color(0xFFE65100) to Color.White
        else -> Color(0xFF424242) to Color.White
    }

    Surface(
        color = bgColor,
        contentColor = fgColor,
        shape = RoundedCornerShape(8.dp),
        modifier = modifier,
    ) {
        Row(
            modifier = Modifier.padding(horizontal = 12.dp, vertical = 6.dp),
            verticalAlignment = Alignment.CenterVertically,
            horizontalArrangement = Arrangement.spacedBy(8.dp),
        ) {
            Text(
                text = state.label,
                style = MaterialTheme.typography.labelMedium,
                fontWeight = FontWeight.Bold,
            )
            if (manifestHash.isNotEmpty()) {
                Text(
                    text = "(${manifestHash.take(8)})",
                    style = MaterialTheme.typography.labelSmall,
                )
            }
        }
    }
}

/**
 * UI layer: gate results list.
 *
 * Shows each gate with a pass/fail/missing/waived marker.
 */
@Composable
fun GateResultsList(
    gates: List<TrustGateSummary>,
    modifier: Modifier = Modifier,
) {
    if (gates.isEmpty()) return
    Card(modifier = modifier.fillMaxWidth()) {
        Column(
            modifier = Modifier.padding(16.dp),
            verticalArrangement = Arrangement.spacedBy(4.dp),
        ) {
            Text("Certification Gates", style = MaterialTheme.typography.titleMedium)
            Spacer(modifier = Modifier.height(4.dp))
            gates.forEach { gate ->
                val marker = when (gate.state) {
                    "pass" -> "[PASS]"
                    "fail" -> "[FAIL]"
                    "missing" -> "[MISSING]"
                    "waived" -> "[WAIVED]"
                    else -> "[????]"
                }
                val color = when (gate.state) {
                    "pass" -> MaterialTheme.colorScheme.primary
                    "fail" -> MaterialTheme.colorScheme.error
                    "missing" -> MaterialTheme.colorScheme.tertiary
                    "waived" -> MaterialTheme.colorScheme.secondary
                    else -> MaterialTheme.colorScheme.onSurfaceVariant
                }
                Text(
                    text = "$marker ${gate.name}: ${gate.detail}",
                    style = MaterialTheme.typography.bodySmall,
                    color = color,
                )
            }
        }
    }
}
