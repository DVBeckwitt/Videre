package com.github.dvbeckwitt.videre.recommendations

import io.flutter.embedding.engine.plugins.FlutterPlugin
import io.flutter.plugin.common.MethodChannel
import io.flutter.plugin.common.StandardMethodCodec

/** Owns neither a network transport nor durable recommendation state. */
class VidereRecommendationsPlugin : FlutterPlugin {
    private var channel: MethodChannel? = null

    override fun onAttachedToEngine(binding: FlutterPlugin.FlutterPluginBinding) {
        channel = MethodChannel(
            binding.binaryMessenger,
            "videre/recommendations",
            StandardMethodCodec.INSTANCE,
            binding.binaryMessenger.makeBackgroundTaskQueue(),
        ).also { channel ->
            channel.setMethodCallHandler { call, result ->
                if (call.method != "evaluate") {
                    result.notImplemented()
                } else {
                    try {
                        result.success(RecommendationEvaluator.evaluate(call.arguments))
                    } catch (error: IllegalArgumentException) {
                        result.error("invalid_recommendation_input", error.message, null)
                    } catch (_: Exception) {
                        // Candidate/history contents are private; do not include them in errors.
                        result.error("recommendation_failed", "Local recommendation calculation failed.", null)
                    }
                }
            }
        }
    }

    override fun onDetachedFromEngine(binding: FlutterPlugin.FlutterPluginBinding) {
        channel?.setMethodCallHandler(null)
        channel = null
    }
}
