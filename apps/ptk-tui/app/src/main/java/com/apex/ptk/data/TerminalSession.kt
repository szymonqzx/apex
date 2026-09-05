package com.apex.ptk.data

import android.util.Log
import java.io.BufferedReader
import java.io.InputStreamReader
import java.io.PrintWriter
import java.net.Socket

/**
 * Terminal session client — connects to apex-bridge PTY bridge
 * on localhost:9876 for interactive shell access to the Arch chroot.
 *
 * Protocol: raw PTY stream over TCP. The bridge handles:
 * - chroot entry/exit
 * - PTY allocation (via openpty)
 * - Signal forwarding (Ctrl+C, Ctrl+Z)
 * - Resize events (window size → TIOCSWINSZ)
 *
 * The PTK TUI renders the terminal output and sends keyboard input.
 */
class TerminalSession {

    companion object {
        private const val TAG = "TerminalSession"
        private const val DEFAULT_HOST = "127.0.0.1"
        private const val DEFAULT_PORT = 9876
        private const val TIMEOUT_MS = 5_000
    }

    private var socket: Socket? = null
    private var reader: BufferedReader? = null
    private var writer: PrintWriter? = null
    private var listener: ((String) -> Unit)? = null
    @Volatile private var running = false

    fun connect(host: String = DEFAULT_HOST, port: Int = DEFAULT_PORT, onOutput: (String) -> Unit): Boolean {
        return try {
            socket = Socket().apply {
                soTimeout = 0 // No read timeout — streaming
                connect(java.net.InetSocketAddress(host, port), TIMEOUT_MS)
            }
            reader = BufferedReader(InputStreamReader(socket!!.getInputStream(), Charsets.UTF_8))
            writer = PrintWriter(socket!!.getOutputStream(), true)
            listener = onOutput
            running = true

            // Start output reader thread
            Thread {
                val buf = CharArray(4096)
                try {
                    while (running && reader != null) {
                        val n = reader!!.read(buf)
                        if (n < 0) break
                        if (n > 0) {
                            val output = String(buf, 0, n)
                            listener?.invoke(output)
                        }
                    }
                } catch (e: Exception) {
                    if (running) Log.e(TAG, "Read error: ${e.message}")
                } finally {
                    running = false
                    listener?.invoke("\r\n[Connection closed]\r\n")
                }
            }.start()

            Log.i(TAG, "Connected to apex-bridge PTY at $host:$port")
            true
        } catch (e: Exception) {
            Log.e(TAG, "Connection failed: ${e.message}")
            false
        }
    }

    fun sendInput(text: String) {
        writer?.print(text)
        writer?.flush()
    }

    fun resize(cols: Int, rows: Int) {
        // Send resize escape sequence: \x1b[8;<rows>;<cols>t
        // The bridge interprets this as TIOCSWINSZ
        writer?.print("\u001b[8;${rows};${cols}t")
        writer?.flush()
    }

    fun sendSignal(sig: Int) {
        // Ctrl+C = SIGINT (2), Ctrl+Z = SIGTSTP (20)
        // Sent as control character
        when (sig) {
            2 -> sendInput("\u0003")  // ETX (Ctrl+C)
            20 -> sendInput("\u001a") // SUB (Ctrl+Z)
        }
    }

    fun disconnect() {
        running = false
        reader?.close()
        writer?.close()
        socket?.close()
        socket = null
        reader = null
        writer = null
        Log.i(TAG, "Disconnected from apex-bridge PTY")
    }

    fun isConnected(): Boolean = running && socket?.isClosed == false
}
