package com.github.dvbeckwitt.videre

import android.net.Uri
import android.os.CancellationSignal
import android.os.Handler
import android.os.Looper
import android.os.OperationCanceledException
import io.flutter.embedding.engine.plugins.FlutterPlugin
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import java.util.concurrent.ArrayBlockingQueue
import java.util.concurrent.RejectedExecutionException
import java.util.concurrent.ThreadPoolExecutor
import java.util.concurrent.TimeUnit

/** The foreground scrubber can cancel work without waiting for the decoder thread. */
internal class MusicWaveformPlugin : FlutterPlugin {
    private val main = Handler(Looper.getMainLooper())
    private var channel: MethodChannel? = null
    private var worker: ThreadPoolExecutor? = null
    private var cancellationWorker: ThreadPoolExecutor? = null
    private var latestRequestId: Long? = null
    private var activeRequest: Request? = null

    override fun onAttachedToEngine(binding: FlutterPlugin.FlutterPluginBinding) {
        val audio = LocalMusicWaveform(binding.applicationContext)
        worker = ThreadPoolExecutor(1, 1, 0, TimeUnit.MILLISECONDS, ArrayBlockingQueue(1))
        // Keep a provider's cancellation callback off the UI thread, too.
        cancellationWorker = ThreadPoolExecutor(0, 1, 5, TimeUnit.SECONDS, ArrayBlockingQueue(1),
            ThreadPoolExecutor.DiscardOldestPolicy())
        channel = MethodChannel(binding.binaryMessenger, "com.github.dvbeckwitt.videre/music_waveform")
            .also { it.setMethodCallHandler { call, result -> handle(audio, call, result) } }
    }

    private fun handle(audio: LocalMusicWaveform, call: MethodCall, result: MethodChannel.Result) {
        if (call.method !in setOf("revision", "extract", "cancel")) {
            result.notImplemented()
            return
        }
        val args = call.arguments as? Map<*, *> ?: emptyMap<String, Any>()
        val requestId = (args["requestId"] as? Number)?.toLong()
        if (requestId == null) {
            result.success(null)
            return
        }
        if (call.method == "cancel") {
            if (latestRequestId == requestId) {
                latestRequestId = null
                retireActiveRequest()
            }
            result.success(null)
            return
        }
        val uri = (args["uri"] as? String)?.takeIf { it.length in 1..32_768 }?.let(Uri::parse)
        if (uri == null) {
            result.success(null)
            return
        }
        // Only the first revision call can supersede a request. The revision
        // check after decoding belongs to the same admitted request as extract.
        if (call.method == "revision" && args["begin"] == true) {
            retireActiveRequest()
            latestRequestId = requestId
        }
        if (latestRequestId != requestId) {
            result.success(null)
            return
        }
        if (call.method == "revision") {
            submit(result) { cancellation -> audio.revision(uri, cancellation) }
        } else {
            val binCount = (args["binCount"] as? Int)?.takeIf { it in 1..1024 }
            val startUs = (args["startUs"] as? Number)?.toLong() ?: 0L
            val endUs = (args["endUs"] as? Number)?.toLong()
            if (binCount == null || startUs < 0 || (endUs != null && endUs <= startUs)) {
                result.success(null)
                return
            }
            val expectedRevision = args["expectedRevision"] as? String
            submit(result) { cancellation ->
                audio.extract(uri, binCount, startUs, endUs, expectedRevision, cancellation)
            }
        }
    }

    private fun submit(result: MethodChannel.Result, action: (WaveformCancellation) -> Any?) {
        val executor = worker
        if (executor == null || activeRequest != null) {
            result.success(null)
            return
        }
        val request = Request(result, action)
        activeRequest = request
        try {
            executor.execute(request)
        } catch (_: RejectedExecutionException) {
            activeRequest = null
            result.success(null)
        }
    }

    private fun retireActiveRequest() {
        val request = activeRequest ?: return
        activeRequest = null
        request.cancellation.retire()
        if (worker?.remove(request) == false) {
            cancellationWorker?.execute(request.cancellation.providerSignal::cancel)
        }
        request.result.success(null)
    }

    override fun onDetachedFromEngine(binding: FlutterPlugin.FlutterPluginBinding) {
        channel?.setMethodCallHandler(null)
        channel = null
        latestRequestId = null
        retireActiveRequest()
        worker?.shutdownNow()
        worker = null
        cancellationWorker?.shutdown()
        cancellationWorker = null
    }

    private inner class Request(
        val result: MethodChannel.Result,
        val action: (WaveformCancellation) -> Any?,
    ) : Runnable {
        val cancellation = WaveformCancellation()

        override fun run() {
            val value = try {
                cancellation.check()
                action(cancellation)
            } catch (_: Exception) {
                // Unavailable documents and unsupported codecs use ordinary seeking.
                null
            }
            main.post {
                if (activeRequest === this) {
                    activeRequest = null
                    result.success(value)
                }
            }
        }
    }
}

internal class WaveformCancellation {
    val providerSignal = CancellationSignal()
    @Volatile
    private var retired = false

    fun retire() {
        retired = true
    }

    fun check() {
        if (retired || Thread.currentThread().isInterrupted) throw OperationCanceledException()
    }
}
