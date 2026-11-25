package com.github.dvbeckwitt.videre

import android.app.Activity
import android.view.View
import io.flutter.embedding.engine.plugins.FlutterPlugin
import io.flutter.embedding.engine.plugins.activity.ActivityAware
import io.flutter.embedding.engine.plugins.activity.ActivityPluginBinding
import io.flutter.plugin.common.MethodChannel

internal class MusicLyricsScreenPlugin : FlutterPlugin, ActivityAware {
    private var activity: Activity? = null
    private var channel: MethodChannel? = null
    private var readerVisible = false

    override fun onAttachedToEngine(binding: FlutterPlugin.FlutterPluginBinding) {
        channel = MethodChannel(binding.binaryMessenger, "videre/music_lyrics_screen").also {
            it.setMethodCallHandler { call, result ->
                val visible = call.arguments as? Boolean
                when {
                    call.method != "setReaderVisible" -> result.notImplemented()
                    visible == null -> result.error("INVALID_ARGUMENT", "Expected reader visibility.", null)
                    else -> {
                        readerVisible = visible
                        setContentKeepScreenOn(visible)
                        result.success(null)
                    }
                }
            }
        }
    }

    override fun onDetachedFromEngine(binding: FlutterPlugin.FlutterPluginBinding) {
        channel?.setMethodCallHandler(null)
        channel = null
        onDetachedFromActivity()
    }

    override fun onAttachedToActivity(binding: ActivityPluginBinding) {
        activity = binding.activity
        if (readerVisible) setContentKeepScreenOn(true)
    }

    override fun onReattachedToActivityForConfigChanges(binding: ActivityPluginBinding) =
        onAttachedToActivity(binding)

    override fun onDetachedFromActivityForConfigChanges() {
        setContentKeepScreenOn(false)
        activity = null
    }

    override fun onDetachedFromActivity() {
        readerVisible = false
        onDetachedFromActivityForConfigChanges()
    }

    private fun setContentKeepScreenOn(enabled: Boolean) {
        // Android combines a view request with the independent window flag used by video.
        activity?.findViewById<View>(android.R.id.content)?.keepScreenOn = enabled
    }
}
