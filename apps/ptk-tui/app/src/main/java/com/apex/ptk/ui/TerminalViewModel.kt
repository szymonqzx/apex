package com.apex.ptk.ui

import androidx.lifecycle.ViewModel
import androidx.lifecycle.viewModelScope
import com.apex.ptk.data.TerminalSession
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asStateFlow
import kotlinx.coroutines.launch

class TerminalViewModel : ViewModel() {

    private val session = TerminalSession()

    private val _output = MutableStateFlow(StringBuilder())
    val output: StateFlow<StringBuilder> = _output.asStateFlow()

    private val _connected = MutableStateFlow(false)
    val connected: StateFlow<Boolean> = _connected.asStateFlow()

    private val _cols = MutableStateFlow(80)
    private val _rows = MutableStateFlow(24)
    val cols: StateFlow<Int> = _cols.asStateFlow()
    val rows: StateFlow<Int> = _rows.asStateFlow()

    private val MAX_BUFFER = 50_000

    fun connect() {
        viewModelScope.launch(Dispatchers.IO) {
            val ok = session.connect(onOutput = { chunk ->
                val buf = _output.value
                buf.append(chunk)
                // Trim if too large
                if (buf.length > MAX_BUFFER) {
                    buf.delete(0, buf.length - MAX_BUFFER)
                }
                _output.value = StringBuilder(buf)
            })
            _connected.value = ok
        }
    }

    fun sendInput(text: String) {
        session.sendInput(text)
    }

    fun sendCtrlC() {
        session.sendSignal(2)
    }

    fun sendCtrlZ() {
        session.sendSignal(20)
    }

    fun resize(cols: Int, rows: Int) {
        _cols.value = cols
        _rows.value = rows
        session.resize(cols, rows)
    }

    fun disconnect() {
        session.disconnect()
        _connected.value = false
    }

    fun clear() {
        _output.value = StringBuilder()
    }

    override fun onCleared() {
        session.disconnect()
        super.onCleared()
    }
}
