package com.github.dvbeckwitt.videre

import android.content.ComponentName
import android.content.Context
import android.content.Intent
import android.os.Handler
import android.os.Looper
import android.support.v4.media.MediaBrowserCompat
import android.support.v4.media.session.MediaControllerCompat
import android.support.v4.media.session.PlaybackStateCompat
import android.view.KeyEvent
import com.ryanheise.audioservice.AudioServiceAccess
import com.ryanheise.audioservice.MediaButtonReceiver

class VidereMediaButtonReceiver : MediaButtonReceiver() {
    @Suppress("DEPRECATION")
    override fun onReceive(context: Context, intent: Intent) {
        if (intent.action != Intent.ACTION_MEDIA_BUTTON) return
        val key = intent.getParcelableExtra<KeyEvent>(Intent.EXTRA_KEY_EVENT) ?: return
        val state = AudioServiceAccess.current()?.sessionToken?.let {
            MediaControllerCompat(context, it).playbackState?.state
        }
        when {
            state != null && state != PlaybackStateCompat.STATE_NONE &&
                state != PlaybackStateCompat.STATE_STOPPED && state != PlaybackStateCompat.STATE_ERROR ->
                super.onReceive(context, intent)
            isColdPlayPress(key.keyCode, key.action, key.repeatCount) -> dispatchColdPlay(context.applicationContext)
            key.keyCode == KeyEvent.KEYCODE_MEDIA_STOP &&
                key.action == KeyEvent.ACTION_DOWN && key.repeatCount == 0 ->
                super.onReceive(context, intent)
        }
    }

    private fun dispatchColdPlay(context: Context) {
        // Pinned audio_service treats MEDIA_PLAY and MEDIA_PAUSE as the same
        // generic click. Send an unambiguous Play to the existing session.
        val pending = goAsync()
        val main = Handler(Looper.getMainLooper())
        var finished = false
        lateinit var browser: MediaBrowserCompat
        lateinit var timeout: Runnable
        fun finish() {
            if (finished) return
            finished = true
            main.removeCallbacks(timeout)
            browser.disconnect()
            pending.finish()
        }
        browser = MediaBrowserCompat(
            context,
            ComponentName(context, AndroidAutoMediaService::class.java),
            object : MediaBrowserCompat.ConnectionCallback() {
                override fun onConnected() {
                    try {
                        MediaControllerCompat(context, browser.sessionToken).transportControls.play()
                    } finally {
                        finish()
                    }
                }

                override fun onConnectionFailed() = finish()
                override fun onConnectionSuspended() = finish()
            },
            null,
        )
        timeout = Runnable { finish() }
        main.postDelayed(timeout, 4_000)
        browser.connect()
    }
}

internal fun isColdPlayPress(keyCode: Int, action: Int, repeatCount: Int): Boolean =
    action == KeyEvent.ACTION_DOWN && repeatCount == 0 && when (keyCode) {
        KeyEvent.KEYCODE_MEDIA_PLAY,
        KeyEvent.KEYCODE_MEDIA_PLAY_PAUSE,
        KeyEvent.KEYCODE_HEADSETHOOK -> true
        else -> false
    }
