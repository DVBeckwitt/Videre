package com.github.dvbeckwitt.videre

import android.app.Activity
import android.content.ActivityNotFoundException
import android.content.Intent
import android.os.BadParcelableException
import android.speech.RecognizerIntent
import io.flutter.embedding.engine.plugins.FlutterPlugin
import io.flutter.embedding.engine.plugins.activity.ActivityAware
import io.flutter.embedding.engine.plugins.activity.ActivityPluginBinding
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import io.flutter.plugin.common.PluginRegistry

class MusicVoiceSearchPlugin : FlutterPlugin, ActivityAware, PluginRegistry.ActivityResultListener {
    private var channel: MethodChannel? = null
    private var activity: ActivityPluginBinding? = null
    private var pending: MethodChannel.Result? = null

    override fun onAttachedToEngine(binding: FlutterPlugin.FlutterPluginBinding) {
        channel = MethodChannel(binding.binaryMessenger, "videre/music_voice_search").also {
            it.setMethodCallHandler(::handle)
        }
    }

    private fun handle(call: MethodCall, result: MethodChannel.Result) {
        val host = activity?.activity
        val intent = Intent(RecognizerIntent.ACTION_RECOGNIZE_SPEECH).apply {
            putExtra(RecognizerIntent.EXTRA_LANGUAGE_MODEL, RecognizerIntent.LANGUAGE_MODEL_FREE_FORM)
        }
        when (call.method) {
            "isAvailable" -> result.success(host != null && intent.resolveActivity(host.packageManager) != null)
            "recognize" -> {
                if (host == null || pending != null) {
                    result.error("VOICE_SEARCH_UNAVAILABLE", null, null)
                    return
                }
                call.argument<String>("languageTag")?.let {
                    intent.putExtra(RecognizerIntent.EXTRA_LANGUAGE, it)
                }
                launchRecognizer(host, intent, result)
            }
            else -> result.notImplemented()
        }
    }

    @Suppress("DEPRECATION")
    private fun launchRecognizer(host: Activity, intent: Intent, result: MethodChannel.Result) {
        pending = result
        // The external speech activity owns microphone capture and permission.
        try {
            host.startActivityForResult(intent, REQUEST_CODE)
        } catch (_: ActivityNotFoundException) {
            unavailable()
        } catch (_: SecurityException) {
            unavailable()
        }
    }

    override fun onActivityResult(requestCode: Int, resultCode: Int, data: Intent?): Boolean {
        if (requestCode != REQUEST_CODE) return false
        val result = pending ?: return true
        pending = null
        when (resultCode) {
            Activity.RESULT_OK -> {
                try {
                    val alternatives: List<*>? = data?.getStringArrayListExtra(RecognizerIntent.EXTRA_RESULTS)
                    val transcript = alternatives?.firstOrNull { it is String && it.isNotBlank() } as? String
                    result.success(transcript?.trim())
                } catch (_: BadParcelableException) {
                    result.error("VOICE_SEARCH_FAILED", null, null)
                }
            }
            Activity.RESULT_CANCELED -> result.success(null)
            else -> result.error("VOICE_SEARCH_FAILED", null, null)
        }
        return true
    }

    override fun onAttachedToActivity(binding: ActivityPluginBinding) {
        activity = binding
        binding.addActivityResultListener(this)
    }

    override fun onReattachedToActivityForConfigChanges(binding: ActivityPluginBinding) =
        onAttachedToActivity(binding)

    override fun onDetachedFromActivityForConfigChanges() {
        activity?.removeActivityResultListener(this)
        activity = null
    }

    override fun onDetachedFromActivity() {
        onDetachedFromActivityForConfigChanges()
        unavailable()
    }

    override fun onDetachedFromEngine(binding: FlutterPlugin.FlutterPluginBinding) {
        onDetachedFromActivity()
        channel?.setMethodCallHandler(null)
        channel = null
    }

    private fun unavailable() {
        val result = pending
        pending = null
        result?.error("VOICE_SEARCH_UNAVAILABLE", null, null)
    }

    companion object {
        private const val REQUEST_CODE = 4407
    }
}
