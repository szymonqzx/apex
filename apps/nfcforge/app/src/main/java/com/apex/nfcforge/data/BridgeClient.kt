package com.apex.nfcforge.data

import android.util.Log
import java.io.BufferedReader
import java.io.InputStreamReader
import java.net.Socket

/**
 * Bridge client for NFCForge — communicates with apex-bridge daemon
 * running in the Arch Linux chroot to access NFC tools (mfoc, mfcuk, crapto1).
 *
 * Protocol: newline-delimited JSON over local socket (localhost:9877).
 * The bridge daemon forwards commands to the chroot's NFC toolchain.
 *
 * Security: all operations require explicit user confirmation in the UI
 * before being sent to the bridge. No automatic operations.
 */
class BridgeClient {

    companion object {
        private const val TAG = "BridgeClient"
        private const val DEFAULT_HOST = "127.0.0.1"
        private const val DEFAULT_PORT = 9877
        private const val TIMEOUT_MS = 10_000
    }

    data class BridgeResponse(
        val success: Boolean,
        val data: String?,
        val error: String?
    )

    data class CardInfo(
        val uid: String,
        val type: String,
        val sak: Int,
        val atqa: String,
        val sectors: Int,
        val isMagic: Boolean,
        val writable: Boolean
    )

    data class SectorData(
        val sector: Int,
        val keyA: String,
        val keyB: String,
        val data: String,
        val readable: Boolean
    )

    private var socket: Socket? = null

    fun connect(host: String = DEFAULT_HOST, port: Int = DEFAULT_PORT): Boolean {
        return try {
            socket = Socket().apply {
                soTimeout = TIMEOUT_MS
                connect(java.net.InetSocketAddress(host, port), TIMEOUT_MS)
            }
            Log.i(TAG, "Connected to apex-bridge at $host:$port")
            true
        } catch (e: Exception) {
            Log.e(TAG, "Connection failed: ${e.message}")
            false
        }
    }

    fun disconnect() {
        socket?.close()
        socket = null
        Log.i(TAG, "Disconnected from apex-bridge")
    }

    fun isConnected(): Boolean = socket?.isConnected == true && socket?.isClosed == false

    /**
     * Send a command to the bridge and receive a response.
     * Commands are JSON: {"cmd":"<command>","args":{...}}
     */
    private fun sendCommand(cmd: String): BridgeResponse {
        val sock = socket ?: return BridgeResponse(false, null, "Not connected")
        return try {
            val output = sock.getOutputStream()
            val input = BufferedReader(InputStreamReader(sock.getInputStream()))

            output.write((cmd + "\n").toByteArray())
            output.flush()

            val response = input.readLine() ?: return BridgeResponse(false, null, "No response")
            parseResponse(response)
        } catch (e: Exception) {
            Log.e(TAG, "Command failed: ${e.message}")
            BridgeResponse(false, null, e.message)
        }
    }

    private fun parseResponse(json: String): BridgeResponse {
        // Simple JSON parsing without external deps (system app)
        val success = json.contains("\"success\":true")
        val data = extractField(json, "data")
        val error = extractField(json, "error")
        return BridgeResponse(success, data, error)
    }

    private fun extractField(json: String, field: String): String? {
        val key = "\"$field\":"
        val start = json.indexOf(key)
        if (start < 0) return null
        val valueStart = start + key.length
        // Handle string values (quoted) and null
        return when {
            json[valueStart] == '"' -> {
                val end = json.indexOf('"', valueStart + 1)
                if (end > 0) json.substring(valueStart + 1, end) else null
            }
            json.substring(valueStart).startsWith("null") -> null
            else -> {
                val end = json.indexOfAny(charArrayOf(',', '}', '\n'), valueStart)
                if (end > 0) json.substring(valueStart, end).trim() else null
            }
        }
    }

    // ── NFC Operations ──────────────────────────────────────────────

    /**
     * Detect card on the reader — returns card info.
     * Bridge command: nfc_detect
     */
    fun detectCard(): BridgeResponse {
        return sendCommand("""{"cmd":"nfc_detect","args":{}}""")
    }

    /**
     * Read all sectors of a MIFARE Classic card.
     * Bridge runs mfoc/mfcuk for key recovery if needed.
     * Args: uid, timeout (seconds)
     */
    fun readCard(uid: String, timeout: Int = 30): BridgeResponse {
        return sendCommand("""{"cmd":"nfc_read","args":{"uid":"$uid","timeout":$timeout}}""")
    }

    /**
     * Write data to a magic card (gen1a/gen2).
     * Args: uid, sector, block, data (hex), key
     */
    fun writeBlock(uid: String, sector: Int, block: Int, data: String, key: String): BridgeResponse {
        return sendCommand("""{"cmd":"nfc_write","args":{"uid":"$uid","sector":$sector,"block":$block,"data":"$data","key":"$key"}}""")
    }

    /**
     * Detect if card is a magic card (writable UID/gen1a/gen2).
     */
    fun detectMagic(uid: String): BridgeResponse {
        return sendCommand("""{"cmd":"nfc_detect_magic","args":{"uid":"$uid"}}""")
    }

    /**
     * Emulate UID — write a new UID to a magic card.
     * Args: uid, newUid
     */
    fun emulateUid(uid: String, newUid: String): BridgeResponse {
        return sendCommand("""{"cmd":"nfc_emulate_uid","args":{"uid":"$uid","new_uid":"$newUid"}}""")
    }

    /**
     * Send raw APDU to the card.
     * Args: uid, apdu (hex string)
     */
    fun sendApdu(uid: String, apdu: String): BridgeResponse {
        return sendCommand("""{"cmd":"nfc_apdu","args":{"uid":"$uid","apdu":"$apdu"}}""")
    }

    /**
     * Clone card — read source card, write to magic card.
     * Args: sourceUid, targetUid, timeout
     */
    fun cloneCard(sourceUid: String, targetUid: String, timeout: Int = 60): BridgeResponse {
        return sendCommand("""{"cmd":"nfc_clone","args":{"source_uid":"$sourceUid","target_uid":"$targetUid","timeout":$timeout}}""")
    }

    /**
     * Check bridge tool availability — which NFC tools are installed in chroot.
     */
    fun checkTools(): BridgeResponse {
        return sendCommand("""{"cmd":"nfc_tools_status","args":{}}""")
    }

    /**
     * Parse card info from bridge response data.
     */
    fun parseCardInfo(data: String?): CardInfo? {
        if (data == null) return null
        return CardInfo(
            uid = extractField(data, "uid") ?: "",
            type = extractField(data, "type") ?: "Unknown",
            sak = extractField(data, "sak")?.toIntOrNull() ?: 0,
            atqa = extractField(data, "atqa") ?: "",
            sectors = extractField(data, "sectors")?.toIntOrNull() ?: 0,
            isMagic = extractField(data, "is_magic") == "true",
            writable = extractField(data, "writable") == "true"
        )
    }
}
