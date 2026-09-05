package com.apex.control.poweruser

import com.apex.control.data.BridgeClient
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.withContext

/**
 * Repository for power-user features.
 *
 * Reads and writes system properties and sysfs nodes that control
 * the power-user init.d RC files. Uses the existing BridgeClient
 * for socket communication and file I/O.
 */
class PowerUserRepository(
    private val client: BridgeClient = BridgeClient(),
) {

    /**
     * Read the current power-user state from the device.
     * Uses getprop via the bridge socket and sysfs reads.
     */
    suspend fun fetchState(): PowerUserState = withContext(Dispatchers.IO) {
        PowerUserState(
            // Game Space
            gameSpaceEnabled = getPropBool("apex.game_space"),
            fpsUnlockEnabled = getPropBool("apex.game_space") && getProp("persist.sys.sf.max_refresh_rate") == "120",
            sensorBlockEnabled = getPropBool("persist.apex.sensor_block"),
            gameDndEnabled = getPropBool("apex.game.dnd"),

            // Pocket detection
            pocketDetectionEnabled = getPropBool("persist.apex.pocket_detect"),
            pocketDetected = getPropBool("apex.pocket"),

            // Smart charging
            smartChargingEnabled = getPropBool("persist.apex.smart_charge"),
            chargeLimitPercent = getPropInt("persist.apex.charge_limit", 80),
            topUpTime = formatTime(getProp("persist.apex.top_up_time", "0630")),
            wakeTime = formatTime(getProp("persist.apex.wake_time", "0700")),
            smartChargeState = getProp("apex.smart_charge.state", "disabled"),

            // Gestures
            doubleTapToWake = getPropBool("persist.apex.dt2w"),
            tapToSleep = getPropBool("persist.apex.tts"),
            screenshotGesture = getPropBool("persist.apex.screenshot_gesture"),

            // Notifications
            headsUpEnabled = getPropBool("persist.apex.heads_up", default = true),
            headsUpTimeoutMs = getPropInt("persist.apex.heads_up_timeout", 3000),
            flashlightBlinkOnCall = getPropBool("persist.apex.blink_notif"),

            // Power user misc
            allowAppDowngrade = getPropBool("persist.apex.allow_downgrade"),
            disableHaptics = getPropBool("persist.apex.disable_haptics"),
            forceGpsHighAccuracy = getPropBool("persist.apex.gps_force_mode"),
        )
    }

    // === Game Space ===
    suspend fun setGameSpace(enabled: Boolean): Boolean = withContext(Dispatchers.IO) {
        setProp("apex.game_space", if (enabled) "1" else "0")
    }

    suspend fun setSensorBlock(enabled: Boolean): Boolean = withContext(Dispatchers.IO) {
        setProp("persist.apex.sensor_block", if (enabled) "1" else "0")
    }

    // === Pocket detection ===
    suspend fun setPocketDetection(enabled: Boolean): Boolean = withContext(Dispatchers.IO) {
        setProp("persist.apex.pocket_detect", if (enabled) "1" else "0")
    }

    // === Smart charging ===
    suspend fun setSmartCharging(enabled: Boolean): Boolean = withContext(Dispatchers.IO) {
        setProp("persist.apex.smart_charge", if (enabled) "1" else "0")
    }

    suspend fun setChargeLimit(percent: Int): Boolean = withContext(Dispatchers.IO) {
        setProp("persist.apex.charge_limit", percent.toString())
    }

    suspend fun setTopUpTime(hhmm: String): Boolean = withContext(Dispatchers.IO) {
        setProp("persist.apex.top_up_time", hhmm.replace(":", ""))
    }

    suspend fun setWakeTime(hhmm: String): Boolean = withContext(Dispatchers.IO) {
        setProp("persist.apex.wake_time", hhmm.replace(":", ""))
    }

    // === Gestures ===
    suspend fun setDoubleTapToWake(enabled: Boolean): Boolean = withContext(Dispatchers.IO) {
        setProp("persist.apex.dt2w", if (enabled) "1" else "0")
    }

    suspend fun setTapToSleep(enabled: Boolean): Boolean = withContext(Dispatchers.IO) {
        setProp("persist.apex.tts", if (enabled) "1" else "0")
    }

    suspend fun setScreenshotGesture(enabled: Boolean): Boolean = withContext(Dispatchers.IO) {
        setProp("persist.apex.screenshot_gesture", if (enabled) "1" else "0")
    }

    // === Notifications ===
    suspend fun setHeadsUp(enabled: Boolean): Boolean = withContext(Dispatchers.IO) {
        setProp("persist.apex.heads_up", if (enabled) "1" else "0")
    }

    suspend fun setHeadsUpTimeout(ms: Int): Boolean = withContext(Dispatchers.IO) {
        setProp("persist.apex.heads_up_timeout", ms.toString())
    }

    suspend fun setFlashlightBlink(enabled: Boolean): Boolean = withContext(Dispatchers.IO) {
        setProp("persist.apex.blink_notif", if (enabled) "1" else "0")
    }

    // === Power user misc ===
    suspend fun setAllowAppDowngrade(enabled: Boolean): Boolean = withContext(Dispatchers.IO) {
        setProp("persist.apex.allow_downgrade", if (enabled) "1" else "0")
    }

    suspend fun setDisableHaptics(enabled: Boolean): Boolean = withContext(Dispatchers.IO) {
        setProp("persist.apex.disable_haptics", if (enabled) "1" else "0")
    }

    suspend fun setForceGpsHighAccuracy(enabled: Boolean): Boolean = withContext(Dispatchers.IO) {
        setProp("persist.apex.gps_force_mode", if (enabled) "1" else "0")
    }

    // === Advanced reboot ===
    suspend fun triggerReboot(action: RebootAction): Boolean = withContext(Dispatchers.IO) {
        setProp("apex.reboot", action.propertyValue)
    }

    // === Helpers ===
    private fun getProp(name: String, default: String = ""): String {
        val result = client.sendCommand("getprop $name")
        return result.trim().ifEmpty { default }
    }

    private fun getPropBool(name: String, default: Boolean = false): Boolean {
        val value = getProp(name)
        return when {
            value.isEmpty() -> default
            value == "1" -> true
            value == "0" -> false
            else -> default
        }
    }

    private fun getPropInt(name: String, default: Int): Int {
        val value = getProp(name)
        return value.toIntOrNull() ?: default
    }

    private fun setProp(name: String, value: String): Boolean {
        val result = client.sendCommand("setprop $name $value")
        return !result.startsWith("ERROR")
    }

    private fun formatTime(hhmm: String): String {
        if (hhmm.length == 4) {
            return "${hhmm.substring(0, 2)}:${hhmm.substring(2, 4)}"
        }
        return hhmm
    }
}
