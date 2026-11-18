package com.github.dvbeckwitt.videre

import android.content.Intent
import io.flutter.embedding.engine.plugins.FlutterPlugin
import io.flutter.embedding.engine.plugins.activity.ActivityAware
import io.flutter.embedding.engine.plugins.activity.ActivityPluginBinding
import io.flutter.plugin.common.MethodChannel
import io.flutter.plugin.common.PluginRegistry.NewIntentListener

/** Retains web links across the gap before the Dart method handler subscribes. */
internal class IncomingLinksPlugin : FlutterPlugin, ActivityAware, NewIntentListener {
    private val inbox = IncomingLinkInbox()
    private var channel: MethodChannel? = null
    private var activityBinding: ActivityPluginBinding? = null

    override fun onAttachedToEngine(binding: FlutterPlugin.FlutterPluginBinding) {
        channel = MethodChannel(binding.binaryMessenger, "videre/incoming_links").also { channel ->
            channel.setMethodCallHandler { call, result ->
                if (call.method == "takePending") {
                    result.success(inbox.takePending().map {
                        mapOf("text" to it.payload.text, "share" to it.payload.share, "initial" to it.initial)
                    })
                } else result.notImplemented()
            }
        }
    }

    override fun onDetachedFromEngine(binding: FlutterPlugin.FlutterPluginBinding) {
        detachActivity()
        inbox.clear()
        channel?.setMethodCallHandler(null)
        channel = null
    }

    override fun onAttachedToActivity(binding: ActivityPluginBinding) {
        attachActivity(binding)
        receive(binding.activity.intent, initial = true)
    }

    override fun onDetachedFromActivityForConfigChanges() = detachActivity()

    override fun onReattachedToActivityForConfigChanges(binding: ActivityPluginBinding) {
        // Configuration changes keep the delivery already stored/consumed.
        attachActivity(binding)
    }

    override fun onDetachedFromActivity() = detachActivity()

    private fun attachActivity(binding: ActivityPluginBinding) {
        activityBinding = binding
        binding.addOnNewIntentListener(this)
    }

    private fun detachActivity() {
        activityBinding?.removeOnNewIntentListener(this)
        activityBinding = null
    }

    override fun onNewIntent(intent: Intent): Boolean = receive(intent, initial = false)

    private fun receive(intent: Intent, initial: Boolean): Boolean {
        // Exported activities may receive malformed extras. Do not let those
        // crash startup, and never read streams or fetch the supplied address.
        val payload = runCatching {
            incomingLinkPayload(intent.action, intent.dataString, intent.type,
                if (intent.action == Intent.ACTION_SEND) intent.getCharSequenceExtra(Intent.EXTRA_TEXT) else null)
        }.getOrNull() ?: return false
        val previousMarker = runCatching { intent.getStringExtra(ATTACHMENT_MARKER) }.getOrNull()
        if (!inbox.offer(payload, initial, previousMarker)) return false
        intent.putExtra(ATTACHMENT_MARKER, inbox.attachmentMarker)
        channel?.invokeMethod("linksAvailable", null)
        return true
    }

    private companion object {
        const val ATTACHMENT_MARKER = "com.github.dvbeckwitt.videre.INCOMING_LINK_ATTACHMENT"
    }
}
