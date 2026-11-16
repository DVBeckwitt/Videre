package com.github.dvbeckwitt.videre

import android.app.Activity
import android.content.Intent
import android.os.Bundle

/** Callback-only trampoline. Authentication still requires MainActivity's live attempt. */
class NerdVpnAuthCallbackActivity : Activity() {
    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        val callback = intent?.data
        if (NerdVpnBrowserAttempt.ownsCallback(callback?.toString())) {
            try {
                startActivity(Intent(this, MainActivity::class.java).apply {
                    action = Intent.ACTION_VIEW
                    data = callback
                    addFlags(Intent.FLAG_ACTIVITY_NEW_TASK or Intent.FLAG_ACTIVITY_CLEAR_TOP or
                        Intent.FLAG_ACTIVITY_SINGLE_TOP)
                })
            } catch (_: Exception) { /* Never expose the callback through another application. */ }
        }
        finish()
    }
}
