package com.github.dvbeckwitt.videre

import android.app.Activity
import android.content.Intent
import android.os.Bundle

internal class MusicShortcutActivity : Activity() {
    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        musicShortcutAction(intent.action)?.takeIf { savedInstanceState == null }?.let { action ->
            // Build a fresh intent so the launcher's CLEAR_TASK flag is discarded.
            startActivity(Intent(this, MainActivity::class.java).apply {
                this.action = action
                addFlags(Intent.FLAG_ACTIVITY_NEW_TASK or Intent.FLAG_ACTIVITY_CLEAR_TOP or
                    Intent.FLAG_ACTIVITY_SINGLE_TOP)
                if (action == MUSIC_SHUFFLE_LOCAL) {
                    putExtra(SHUFFLE_SHORTCUT_TOKEN, ShuffleShortcutAdmission.issue())
                }
            })
        }
        finish()
    }
}
