package com.apex.nfcforge.domain

/**
 * NFC operation types — each requires explicit user confirmation.
 * Used by the UI to show preview-confirm dialogs before executing.
 */
enum class NfcOperation(val displayName: String, val requiresDualConfirm: Boolean) {
    DETECT("Detect Card", false),
    READ("Read Card Sectors", false),
    WRITE_BLOCK("Write Block", true),
    DETECT_MAGIC("Detect Magic Card", false),
    EMULATE_UID("Emulate UID (Write to Magic Card)", true),
    SEND_APDU("Send Raw APDU", true),
    CLONE("Clone Card", true),
    TOOLS_STATUS("Check Tool Availability", false);

    companion object {
        fun fromName(name: String): NfcOperation? =
            entries.find { it.name == name }
    }
}

/**
 * Result of an NFC operation, with audit trail.
 */
data class NfcResult(
    val operation: NfcOperation,
    val success: Boolean,
    val timestamp: Long,
    val data: String?,
    val error: String?,
    val duration: Long
) {
    fun toAuditLine(): String {
        val status = if (success) "OK" else "FAIL"
        val detail = error ?: data?.take(100) ?: ""
        return "[$timestamp] $operation $status ${duration}ms $detail"
    }
}

/**
 * Preview of a write operation — shown to user before confirmation.
 */
data class WritePreview(
    val uid: String,
    val sector: Int,
    val block: Int,
    val currentData: String,
    val newData: String,
    val key: String
) {
    val changesDetected: Boolean
        get() = currentData != newData

    val summary: String
        get() = "UID: $uid | Sector $sector Block $block | ${currentData.take(16)} → ${newData.take(16)}"
}
