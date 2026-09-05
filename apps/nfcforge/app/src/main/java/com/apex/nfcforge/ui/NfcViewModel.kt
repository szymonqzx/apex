package com.apex.nfcforge.ui

import androidx.lifecycle.ViewModel
import androidx.lifecycle.viewModelScope
import com.apex.nfcforge.data.BridgeClient
import com.apex.nfcforge.domain.NfcOperation
import com.apex.nfcforge.domain.NfcResult
import com.apex.nfcforge.domain.WritePreview
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asStateFlow
import kotlinx.coroutines.launch
import kotlinx.coroutines.withContext

/**
 * ViewModel for NFCForge — manages bridge connection, NFC operations,
 * and audit log. All operations run on IO dispatcher.
 */
class NfcViewModel : ViewModel() {

    private val bridge = BridgeClient()

    private val _connectionState = MutableStateFlow(ConnectionState.DISCONNECTED)
    val connectionState: StateFlow<ConnectionState> = _connectionState.asStateFlow()

    private val _cardInfo = MutableStateFlow<BridgeClient.CardInfo?>(null)
    val cardInfo: StateFlow<BridgeClient.CardInfo?> = _cardInfo.asStateFlow()

    private val _operationResult = MutableStateFlow<NfcResult?>(null)
    val operationResult: StateFlow<NfcResult?> = _operationResult.asStateFlow()

    private val _auditLog = MutableStateFlow<List<String>>(emptyList())
    val auditLog: StateFlow<List<String>> = _auditLog.asStateFlow()

    private val _isExecuting = MutableStateFlow(false)
    val isExecuting: StateFlow<Boolean> = _isExecuting.asStateFlow()

    private val _toolsAvailable = MutableStateFlow<Map<String, Boolean>>(emptyMap())
    val toolsAvailable: StateFlow<Map<String, Boolean>> = _toolsAvailable.asStateFlow()

    enum class ConnectionState { DISCONNECTED, CONNECTING, CONNECTED, ERROR }

    fun connect() {
        _connectionState.value = ConnectionState.CONNECTING
        viewModelScope.launch(Dispatchers.IO) {
            val ok = bridge.connect()
            _connectionState.value = if (ok) ConnectionState.CONNECTED else ConnectionState.ERROR
            if (ok) checkTools()
        }
    }

    fun disconnect() {
        bridge.disconnect()
        _connectionState.value = ConnectionState.DISCONNECTED
        _cardInfo.value = null
    }

    override fun onCleared() {
        bridge.disconnect()
        super.onCleared()
    }

    fun detectCard() = execute(NfcOperation.DETECT) {
        val resp = bridge.detectCard()
        if (resp.success) {
            _cardInfo.value = bridge.parseCardInfo(resp.data)
        }
        resp
    }

    fun readCard(timeout: Int = 30) = execute(NfcOperation.READ) {
        val uid = _cardInfo.value?.uid ?: return@execute BridgeClient.BridgeResponse(false, null, "No card detected")
        bridge.readCard(uid, timeout)
    }

    fun writeBlock(sector: Int, block: Int, data: String, key: String) = execute(NfcOperation.WRITE_BLOCK) {
        val uid = _cardInfo.value?.uid ?: return@execute BridgeClient.BridgeResponse(false, null, "No card detected")
        bridge.writeBlock(uid, sector, block, data, key)
    }

    fun detectMagic() = execute(NfcOperation.DETECT_MAGIC) {
        val uid = _cardInfo.value?.uid ?: return@execute BridgeClient.BridgeResponse(false, null, "No card detected")
        val resp = bridge.detectMagic(uid)
        if (resp.success && _cardInfo.value != null) {
            _cardInfo.value = _cardInfo.value!!.copy(isMagic = resp.data == "true")
        }
        resp
    }

    fun emulateUid(newUid: String) = execute(NfcOperation.EMULATE_UID) {
        val uid = _cardInfo.value?.uid ?: return@execute BridgeClient.BridgeResponse(false, null, "No card detected")
        bridge.emulateUid(uid, newUid)
    }

    fun sendApdu(apdu: String) = execute(NfcOperation.SEND_APDU) {
        val uid = _cardInfo.value?.uid ?: return@execute BridgeClient.BridgeResponse(false, null, "No card detected")
        bridge.sendApdu(uid, apdu)
    }

    fun cloneCard(targetUid: String, timeout: Int = 60) = execute(NfcOperation.CLONE) {
        val sourceUid = _cardInfo.value?.uid ?: return@execute BridgeClient.BridgeResponse(false, null, "No card detected")
        bridge.cloneCard(sourceUid, targetUid, timeout)
    }

    fun checkTools() = execute(NfcOperation.TOOLS_STATUS) {
        val resp = bridge.checkTools()
        if (resp.success && resp.data != null) {
            // Parse tool availability: "mfoc:true,mfcuk:false,crapto1:true"
            val tools = resp.data.split(",").associate { pair ->
                val (name, available) = pair.split(":")
                name to (available == "true")
            }
            _toolsAvailable.value = tools
        }
        resp
    }

    fun clearAuditLog() {
        _auditLog.value = emptyList()
    }

    private fun execute(operation: NfcOperation, block: () -> BridgeClient.BridgeResponse) {
        if (_isExecuting.value) return
        _isExecuting.value = true
        viewModelScope.launch(Dispatchers.IO) {
            val start = System.currentTimeMillis()
            val resp = try {
                withContext(Dispatchers.IO) { block() }
            } catch (e: Exception) {
                BridgeClient.BridgeResponse(false, null, e.message)
            }
            val duration = System.currentTimeMillis() - start
            val result = NfcResult(operation, resp.success, start, resp.data, resp.error, duration)
            _operationResult.value = result
            _auditLog.value = _auditLog.value + result.toAuditLine()
            _isExecuting.value = false
        }
    }
}
