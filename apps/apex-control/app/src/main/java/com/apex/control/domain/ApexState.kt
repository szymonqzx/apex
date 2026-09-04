package com.apex.control.domain

import org.json.JSONObject
import org.json.JSONException

/**
 * Domain layer: immutable state model for the Apex Control app.
 *
 * Represents a snapshot of all kernel state at a point in time.
 * The UI layer observes this and re-renders on change.
 */
data class ApexState(
    val status: String = "Loading...",
    val version: String = "",
    val governor: String = "",
    val watchdog: String = "",
    val thermalProfile: String = "",
    val policyActive: String = "",
    val modules: String = "",
    val sensorStatus: String = "",
    val btStatus: String = "",
    val health: String = "",
    val stats: String = "",
    val incidents: List<String> = emptyList(),
    val gamingMode: Boolean = false,
    val kcalR: Int = 255,
    val kcalG: Int = 255,
    val kcalB: Int = 255,
    val trustState: TrustState = TrustState.UNKNOWN,
    val trustManifestHash: String = "",
    val trustArtifactState: String = "",
    val trustGates: List<TrustGateSummary> = emptyList(),
)

/**
 * Trust state derived from the host-issued trust manifest.
 * Drives the trust badge in the UI.
 */
enum class TrustState(val label: String, val isCertified: Boolean) {
    UNKNOWN("Unknown", false),
    UNVERIFIED("Unverified", false),
    OBSERVE_ONLY("Observe Only", false),
    PARTIAL("Partial Evidence", false),
    CANDIDATE("Candidate", false),
    CERTIFIED("Certified", true),
    CERTIFIED_WITH_WAIVERS("Certified (Waivers)", true),
    FAILED("Failed", false),
    STALE("Stale", false),
    ROLLED_BACK("Rolled Back", false);

    companion object {
        fun fromString(s: String): TrustState =
            entries.find { it.name == s } ?: UNKNOWN
    }
}

/**
 * Summary of a single gate for UI display.
 */
data class TrustGateSummary(
    val name: String,
    val state: String,  // "pass", "fail", "missing", "waived"
    val detail: String = "",
)

/**
 * Parse a trust manifest JSON string into trust state components.
 */
fun parseTrustManifest(json: String): Triple<TrustState, String, List<TrustGateSummary>> {
    return try {
        val obj = JSONObject(json)
        val artifactState = obj.optString("artifact_state", "UNVERIFIED")
        val manifestHash = obj.optString("manifest_hash", "")
        val gatesArray = obj.optJSONArray("gates")
        val gates = mutableListOf<TrustGateSummary>()
        if (gatesArray != null) {
            for (i in 0 until gatesArray.length()) {
                val gate = gatesArray.getJSONObject(i)
                gates.add(TrustGateSummary(
                    name = gate.optString("gate_name", ""),
                    state = gate.optString("state", ""),
                    detail = gate.optString("detail", ""),
                ))
            }
        }
        Triple(TrustState.fromString(artifactState), manifestHash, gates)
    } catch (e: JSONException) {
        Triple(TrustState.UNKNOWN, "", emptyList())
    }
}
