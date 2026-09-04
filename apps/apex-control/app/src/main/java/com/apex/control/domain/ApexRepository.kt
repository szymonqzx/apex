package com.apex.control.domain

import com.apex.control.data.BridgeClient
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.withContext

/**
 * Domain layer: repository that fetches state from the bridge client
 * and maps it to the immutable ApexState model.
 */
class ApexRepository(private val client: BridgeClient = BridgeClient()) {

    /** Fetch a complete state snapshot from the device. */
    suspend fun fetchState(): ApexState = withContext(Dispatchers.IO) {
        val status = client.sendCommand("status")
        val version = client.sendCommand("version")
        val governor = client.sendCommand("governor")
        val watchdog = client.sendCommand("watchdog")
        val thermalProfile = client.sendCommand("thermal_profile")
        val policyActive = client.sendCommand("policy_active")
        val modules = client.sendCommand("modules")
        val sensorStatus = client.readProc("/proc/apex/sensor_status")
        val btStatus = client.readProc("/proc/apex/bt_status")
        val health = client.readProc("/proc/apex/health")
        val stats = client.readProc("/proc/apex/stats")
        val incidents = client.readIncidents()

        // Parse trust manifest if available
        val (trustState, trustHash, trustGates) = client.readTrustManifest()
            ?.let { parseTrustManifest(it) }
            ?: Triple(TrustState.UNKNOWN, "", emptyList())

        ApexState(
            status = status,
            version = version,
            governor = governor,
            watchdog = watchdog,
            thermalProfile = thermalProfile,
            policyActive = policyActive,
            modules = modules,
            sensorStatus = sensorStatus,
            btStatus = btStatus,
            health = health,
            stats = stats,
            incidents = incidents,
            trustState = trustState,
            trustManifestHash = trustHash,
            trustArtifactState = trustState.label,
            trustGates = trustGates,
        )
    }

    /** Send a gaming mode toggle command. */
    suspend fun setGamingMode(enabled: Boolean): Boolean = withContext(Dispatchers.IO) {
        val result = client.sendCommand("game ${if (enabled) 1 else 0}")
        !result.startsWith("ERROR")
    }

    /** Write KCAL values. */
    suspend fun setKcal(r: Int, g: Int, b: Int): Boolean = withContext(Dispatchers.IO) {
        client.writeKcal(r, g, b)
    }
}
