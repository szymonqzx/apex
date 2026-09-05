package com.apex.nfcforge.ui

import android.content.Intent
import android.nfc.NfcAdapter
import android.nfc.Tag
import android.os.Bundle
import androidx.activity.ComponentActivity
import androidx.activity.compose.setContent
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.darkColorScheme
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember

class MainActivity : ComponentActivity() {

    private var nfcAdapter: NfcAdapter? = null

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        nfcAdapter = NfcAdapter.getDefaultAdapter(this)

        setContent {
            MaterialTheme(colorScheme = darkColorScheme()) {
                MainScreen()
            }
        }
    }

    override fun onResume() {
        super.onResume()
        // Enable foreground dispatch for NFC tag detection
        nfcAdapter?.let { adapter ->
            val intent = Intent(this, javaClass).addFlags(Intent.FLAG_ACTIVITY_SINGLE_TOP)
            // Foreground dispatch setup would go here
        }
    }

    override fun onPause() {
        super.onPause()
        // Disable foreground dispatch
    }

    override fun onNewIntent(intent: Intent) {
        super.onNewIntent(intent)
        // Handle NFC tag discovery
        if (intent.action == NfcAdapter.ACTION_TECH_DISCOVERED) {
            val tag = intent.getParcelableExtra<Tag>(NfcAdapter.EXTRA_TAG)
            // Tag detected — update UI via ViewModel
        }
    }
}

/**
 * Tag dispatch activity — receives NFC tech-discovered intents,
 * extracts tag info, and forwards to MainActivity.
 */
class TagDispatchActivity : ComponentActivity() {
    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        val tag = intent.getParcelableExtra<Tag>(NfcAdapter.EXTRA_TAG)
        if (tag != null) {
            val mainIntent = Intent(this, MainActivity::class.java).apply {
                flags = Intent.FLAG_ACTIVITY_CLEAR_TOP or Intent.FLAG_ACTIVITY_SINGLE_TOP
                putExtra(NfcAdapter.EXTRA_TAG, tag)
            }
            startActivity(mainIntent)
        }
        finish()
    }
}
