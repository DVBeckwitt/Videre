package com.github.dvbeckwitt.videre

import android.app.Activity
import android.os.Build
import android.view.WindowManager
import io.flutter.embedding.engine.plugins.FlutterPlugin
import io.flutter.embedding.engine.plugins.activity.ActivityAware
import io.flutter.embedding.engine.plugins.activity.ActivityPluginBinding
import io.flutter.plugin.common.MethodChannel

// The AudioService engine can outlive MainActivity. Keep the requested state
// here so a replacement Activity gets the flag before it displays Flutter.
class MusicScreenPrivacyPlugin : FlutterPlugin, ActivityAware {
    private var channel: MethodChannel? = null
    private var activity: Activity? = null
    private var protectionEnabled = false

    override fun onAttachedToEngine(binding: FlutterPlugin.FlutterPluginBinding) {
        channel = MethodChannel(binding.binaryMessenger, "videre/music_screen_privacy").also {
            it.setMethodCallHandler { call, result ->
                val enabled = call.arguments as? Boolean
                when {
                    call.method != "setProtected" -> result.notImplemented()
                    enabled == null -> result.error("INVALID_ARGUMENT", "Expected a boolean.", null)
                    else -> {
                        protectionEnabled = enabled
                        activity?.let(::applyProtection)
                        result.success(null)
                    }
                }
            }
        }
    }

    override fun onDetachedFromEngine(binding: FlutterPlugin.FlutterPluginBinding) {
        channel?.setMethodCallHandler(null)
        channel = null
        activity = null
    }

    override fun onAttachedToActivity(binding: ActivityPluginBinding) {
        activity = binding.activity
        if (protectionEnabled) applyProtection(binding.activity)
    }

    override fun onReattachedToActivityForConfigChanges(binding: ActivityPluginBinding) =
        onAttachedToActivity(binding)

    override fun onDetachedFromActivityForConfigChanges() = onDetachedFromActivity()

    override fun onDetachedFromActivity() {
        // Leave the departing window secure through Android's task snapshot.
        activity = null
    }

    private fun applyProtection(activity: Activity) {
        val flag = WindowManager.LayoutParams.FLAG_SECURE
        activity.window.setFlags(if (protectionEnabled) flag else 0, flag)
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU) {
            activity.setRecentsScreenshotEnabled(!protectionEnabled)
        }
    }
}
