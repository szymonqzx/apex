package com.apex.control.data

import android.net.LocalSocket
import android.net.LocalSocketAddress
import java.io.File

/**
 * Data layer: low-level communication with the apex-bridge daemon.
 *
 * Connects to the Unix domain socket at /dev/socket/apex-bridge and
 * exchanges newline-terminated text commands.  All methods are
 * synchronous and should be called from a background thread.
 */
class BridgeClient(
    private val socketPath: String = SOCKET_PATH
) {
    companion object {
        private const val SOCKET_PATH = "/dev/socket/apex-bridge"
    }

    /** Send a text command and return the response string. */
    fun sendCommand(command: String): String {
        return try {
            val socket = LocalSocket()
            socket.connect(
                LocalSocketAddress(socketPath, LocalSocketAddress.Namespace.FILESYSTEM)
            )
            val output = socket.outputStream
            val input = socket.inputStream
            output.write(command.toByteArray())
            output.flush()
            val buf = ByteArray(8192)
            val n = input.read(buf)
            socket.close()
            if (n > 0) String(buf, 0, n) else ""
        } catch (e: Exception) {
            "Error: ${e.message}"
        }
    }

    /** Read a procfs file and return its trimmed content. */
    fun readProc(path: String): String {
        return try {
            File(path).readText().trim()
        } catch (e: Exception) {
            ""
        }
    }

    /** Read incidents from /proc/apex/incidents. */
    fun readIncidents(): List<String> {
        return try {
            File("/proc/apex/incidents").readText()
                .lines()
                .filter { it.isNotBlank() }
        } catch (e: Exception) {
            listOf("Error reading incidents: ${e.message}")
        }
    }

    /** Write KCAL RGB gains to sysfs. */
    fun writeKcal(r: Int, g: Int, b: Int): Boolean {
        return try {
            File("/sys/class/apex_kcal/rgb_gains").writeText("$r $g $b")
            true
        } catch (e: Exception) {
            false
        }
    }

    /** Read the trust manifest from /data/adb/apex/trust-manifest.json. */
    fun readTrustManifest(): String? {
        return try {
            val content = File("/data/adb/apex/trust-manifest.json").readText()
            if (content.isNotBlank()) content else null
        } catch (e: Exception) {
            null
        }
    }
}
