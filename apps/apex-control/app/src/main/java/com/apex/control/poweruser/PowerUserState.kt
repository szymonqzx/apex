package com.apex.control.poweruser

/**
 * Data model for power-user features ported from LineageOS-based ROMs.
 *
 * Each feature maps to a system property or sysfs node controlled by
 * the corresponding init.d RC file. The UI layer reads/writes these
 * via the PowerUserRepository.
 */
data class PowerUserState(
    // Game Space
    val gameSpaceEnabled: Boolean = false,
    val fpsUnlockEnabled: Boolean = false,
    val sensorBlockEnabled: Boolean = false,
    val gameDndEnabled: Boolean = false,

    // Pocket detection
    val pocketDetectionEnabled: Boolean = false,
    val pocketDetected: Boolean = false,

    // Smart charging
    val smartChargingEnabled: Boolean = false,
    val chargeLimitPercent: Int = 80,
    val topUpTime: String = "06:30",
    val wakeTime: String = "07:00",
    val smartChargeState: String = "disabled",

    // Gestures
    val doubleTapToWake: Boolean = false,
    val tapToSleep: Boolean = false,
    val screenshotGesture: Boolean = false,

    // Notifications
    val headsUpEnabled: Boolean = true,
    val headsUpTimeoutMs: Int = 3000,
    val flashlightBlinkOnCall: Boolean = false,

    // Power user misc
    val allowAppDowngrade: Boolean = false,
    val disableHaptics: Boolean = false,
    val forceGpsHighAccuracy: Boolean = false,

    // Advanced reboot (transient — not persisted in state)
    val lastRebootAction: String = "",
)

/**
 * Reboot options for the advanced reboot menu.
 */
enum class RebootAction(val propertyValue: String, val displayName: String) {
    RECOVERY("recovery", "Recovery"),
    BOOTLOADER("bootloader", "Bootloader (Fastboot)"),
    SOFT_REBOOT("soft", "Soft Reboot"),
    SYSTEM_UI("systemui", "Restart SystemUI"),
    SAFE_MODE("safe", "Safe Mode"),
}
