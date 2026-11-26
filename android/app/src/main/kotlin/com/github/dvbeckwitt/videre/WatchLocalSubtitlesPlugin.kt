package com.github.dvbeckwitt.videre

import android.app.Activity
import android.content.ActivityNotFoundException
import android.content.ContentResolver
import android.content.Context
import android.content.Intent
import android.net.Uri
import android.os.Handler
import android.os.Looper
import android.provider.OpenableColumns
import android.util.AtomicFile
import io.flutter.embedding.engine.plugins.FlutterPlugin
import io.flutter.embedding.engine.plugins.activity.ActivityAware
import io.flutter.embedding.engine.plugins.activity.ActivityPluginBinding
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import io.flutter.plugin.common.PluginRegistry
import org.json.JSONArray
import org.json.JSONObject
import java.io.ByteArrayOutputStream
import java.io.File
import java.io.FileNotFoundException
import java.io.IOException
import java.util.UUID
import java.util.concurrent.ExecutorService
import java.util.concurrent.Executors

internal class WatchLocalSubtitlesPlugin : FlutterPlugin, ActivityAware, PluginRegistry.ActivityResultListener {
    private data class Pick(
        val scope: SubtitleScope,
        val result: MethodChannel.Result,
        var pickerOpen: Boolean = true,
        var cancelled: Boolean = false,
    )

    private data class Candidate(
        val scope: SubtitleScope,
        val token: String,
        val document: SubtitleDocument,
    )

    private val main = Handler(Looper.getMainLooper())
    private lateinit var ledgerWorker: ExecutorService
    private lateinit var providerWorker: ExecutorService
    private lateinit var documents: WatchSubtitleDocuments
    private var channel: MethodChannel? = null
    private var activity: ActivityPluginBinding? = null
    private var pending: Pick? = null
    private var candidate: Candidate? = null

    override fun onAttachedToEngine(binding: FlutterPlugin.FlutterPluginBinding) {
        ledgerWorker = Executors.newSingleThreadExecutor()
        providerWorker = Executors.newFixedThreadPool(2)
        documents = WatchSubtitleDocuments(binding.applicationContext)
        channel = MethodChannel(binding.binaryMessenger, "videre/watch_local_subtitles").also {
            it.setMethodCallHandler(::handle)
        }
    }

    private fun handle(call: MethodCall, result: MethodChannel.Result) {
        try {
            when (call.method) {
                "attachment" -> {
                    val scope = scope(call)
                    run(result) { documents.attachment(scope)?.name }
                }
                "pick" -> launchPicker(scope(call), result)
                "save" -> {
                    val token = argument(call, "token")
                    val selected = candidate?.takeIf { it.token == token }
                        ?: throw SubtitleError("SUBTITLE_PICK_EXPIRED", "Choose the subtitle file again.")
                    candidate = null
                    run(result) {
                        documents.save(selected.scope, selected.document)
                        null
                    }
                }
                "discardPick" -> {
                    if (candidate?.token == argument(call, "token")) candidate = null
                    result.success(null)
                }
                "read" -> read(scope(call), result)
                "remove" -> {
                    val scope = scope(call)
                    cancelSelection { it == scope }
                    run(result) {
                        documents.remove { it == scope }
                        null
                    }
                }
                "removeProfile" -> {
                    val profileId = argument(call, "profileId")
                    cancelSelection { it.profileId == profileId }
                    run(result) {
                        documents.remove { it.profileId == profileId }
                        null
                    }
                }
                else -> result.notImplemented()
            }
        } catch (failure: SubtitleError) {
            report(result, failure)
        }
    }

    private fun argument(call: MethodCall, name: String): String {
        val value = (call.arguments as? Map<*, *>)?.get(name) as? String
        return value?.takeIf { it.isNotBlank() && it.length <= 256 }
            ?: throw SubtitleError("INVALID_ARGUMENT", "Invalid subtitle request.")
    }

    private fun scope(call: MethodCall) = SubtitleScope(argument(call, "profileId"), argument(call, "videoId"))

    @Suppress("DEPRECATION")
    private fun launchPicker(scope: SubtitleScope, result: MethodChannel.Result) {
        val host = activity?.activity
            ?: throw SubtitleError("PICKER_UNAVAILABLE", "The file picker is not available on this device.")
        if (pending != null || candidate != null) {
            throw SubtitleError("PICKER_BUSY", "Finish the current subtitle selection first.")
        }
        val request = Pick(scope, result)
        pending = request
        setPickerActive(true)
        val intent = Intent(Intent.ACTION_OPEN_DOCUMENT).apply {
            addCategory(Intent.CATEGORY_OPENABLE)
            // Many document providers report both subtitle formats as generic files.
            type = "*/*"
            putExtra(Intent.EXTRA_LOCAL_ONLY, true)
            addFlags(Intent.FLAG_GRANT_READ_URI_PERMISSION or Intent.FLAG_GRANT_PERSISTABLE_URI_PERMISSION)
        }
        try {
            host.startActivityForResult(intent, REQUEST_CODE)
        } catch (_: ActivityNotFoundException) {
            finishPick(request, failure = SubtitleError("PICKER_UNAVAILABLE", "The file picker is not available on this device."))
        } catch (_: SecurityException) {
            finishPick(request, failure = SubtitleError("PICKER_UNAVAILABLE", "This device could not open the file picker."))
        }
    }

    override fun onActivityResult(requestCode: Int, resultCode: Int, data: Intent?): Boolean {
        if (requestCode != REQUEST_CODE) return false
        val request = pending ?: return true
        if (!request.pickerOpen) return true
        request.pickerOpen = false
        setPickerActive(false)
        if (resultCode != Activity.RESULT_OK || request.cancelled) {
            finishPick(request)
            return true
        }
        val uri = runCatching { data?.data }.getOrNull()
        if (uri?.scheme != ContentResolver.SCHEME_CONTENT || uri.authority.isNullOrBlank() ||
            ((data?.flags ?: 0) and Intent.FLAG_GRANT_READ_URI_PERMISSION) == 0) {
            finishPick(request, failure = inaccessibleSubtitle())
            return true
        }
        providerWorker.execute {
            try {
                val name = documents.displayName(uri)
                val bytes = documents.readBytes(uri)
                val selection = Candidate(request.scope, UUID.randomUUID().toString(), SubtitleDocument(uri, name))
                main.post { finishPick(request, selection, bytes) }
            } catch (failure: Exception) {
                main.post { finishPick(request, failure = failure) }
            }
        }
        return true
    }

    private fun finishPick(
        request: Pick,
        selection: Candidate? = null,
        bytes: ByteArray? = null,
        failure: Exception? = null,
    ) {
        if (pending !== request) return
        if (request.pickerOpen) setPickerActive(false)
        pending = null
        when {
            request.cancelled -> request.result.success(null)
            failure != null -> report(request.result, failure)
            selection == null -> request.result.success(null)
            else -> {
                candidate = selection
                request.result.success(mapOf(
                    "token" to selection.token,
                    "name" to selection.document.name,
                    "bytes" to checkNotNull(bytes),
                ))
            }
        }
    }

    private fun cancelSelection(matches: (SubtitleScope) -> Boolean) {
        pending?.takeIf { matches(it.scope) }?.cancelled = true
        if (candidate?.let { matches(it.scope) } == true) candidate = null
    }

    private fun read(scope: SubtitleScope, result: MethodChannel.Result) {
        val provider = providerWorker
        ledgerWorker.execute {
            try {
                val uri = documents.readableUri(scope)
                run(result, provider) { documents.readBytes(uri) }
            } catch (failure: Exception) {
                report(result, failure)
            }
        }
    }

    private fun run(
        result: MethodChannel.Result,
        executor: ExecutorService = ledgerWorker,
        action: () -> Any?,
    ) {
        executor.execute {
            try {
                result.success(action())
            } catch (failure: Exception) {
                report(result, failure)
            }
        }
    }

    private fun report(result: MethodChannel.Result, cause: Exception) {
        val error = cause as? SubtitleError ?: inaccessibleSubtitle()
        result.error(error.code, error.message, null)
    }

    private fun setPickerActive(active: Boolean) {
        (activity?.activity as? MainActivity)?.setWatchSubtitlePickerActive(active)
    }

    override fun onAttachedToActivity(binding: ActivityPluginBinding) {
        activity = binding
        binding.addActivityResultListener(this)
        if (pending?.pickerOpen == true) setPickerActive(true)
    }

    override fun onReattachedToActivityForConfigChanges(binding: ActivityPluginBinding) =
        onAttachedToActivity(binding)

    override fun onDetachedFromActivityForConfigChanges() {
        activity?.removeActivityResultListener(this)
        activity = null
    }

    override fun onDetachedFromActivity() {
        pending?.let { finishPick(it, failure = SubtitleError("PICKER_UNAVAILABLE", "Subtitle selection was interrupted.")) }
        candidate = null
        onDetachedFromActivityForConfigChanges()
    }

    override fun onDetachedFromEngine(binding: FlutterPlugin.FlutterPluginBinding) {
        onDetachedFromActivity()
        channel?.setMethodCallHandler(null)
        channel = null
        // Let queued authorization lookups submit their reads before closing the pool.
        ledgerWorker.execute(providerWorker::shutdown)
        ledgerWorker.shutdown()
    }

    companion object {
        private const val REQUEST_CODE = 4408
    }
}

private data class SubtitleScope(val profileId: String, val videoId: String)
private data class SubtitleDocument(val uri: Uri, val name: String)
private data class SubtitleLedger(
    val attachments: Map<SubtitleScope, SubtitleDocument> = emptyMap(),
    val ownedGrants: Set<Uri> = emptySet(),
)

private class SubtitleError(val code: String, message: String) : IOException(message)
private fun inaccessibleSubtitle() = SubtitleError("SUBTITLE_ACCESS", "The subtitle file could not be opened.")

private class WatchSubtitleDocuments(context: Context) {
    private val resolver = context.contentResolver
    private val file = AtomicFile(File(context.noBackupFilesDir, "watch-local-subtitles.json"))

    fun attachment(scope: SubtitleScope): SubtitleDocument? {
        val ledger = load()
        releaseUnusedGrants(ledger)
        return ledger.attachments[scope]
    }

    fun displayName(uri: Uri): String {
        val name = resolver.query(uri, arrayOf(OpenableColumns.DISPLAY_NAME), null, null, null)?.use {
            if (it.moveToFirst()) it.getString(0) else null
        }?.trim()
        if (!name.orEmpty().endsWith(".srt", ignoreCase = true) &&
            !name.orEmpty().endsWith(".vtt", ignoreCase = true)) {
            throw SubtitleError("UNSUPPORTED_SUBTITLE", "Choose an SRT or WebVTT subtitle file.")
        }
        return checkNotNull(name)
    }

    fun readableUri(scope: SubtitleScope): Uri {
        val document = load().attachments[scope] ?: throw inaccessibleSubtitle()
        if (!hasReadGrant(document.uri)) throw inaccessibleSubtitle()
        return document.uri
    }

    fun readBytes(uri: Uri): ByteArray {
        val input = resolver.openInputStream(uri) ?: throw inaccessibleSubtitle()
        return input.use {
            val output = ByteArrayOutputStream()
            val buffer = ByteArray(8192)
            while (true) {
                val count = it.read(buffer)
                if (count == -1) break
                if (output.size() + count > MAX_SUBTITLE_BYTES) {
                    throw SubtitleError("SUBTITLE_TOO_LARGE", "Choose a subtitle file no larger than 8 MiB.")
                }
                output.write(buffer, 0, count)
            }
            output.toByteArray()
        }
    }

    fun save(scope: SubtitleScope, document: SubtitleDocument) {
        var ledger = load()
        val uri = document.uri
        try {
            if (!hasReadGrant(uri)) {
                // Record our acquisition first so the next operation can reclaim
                // the grant if Android stops us before the attachment is saved.
                val pendingGrant = ledger.copy(ownedGrants = ledger.ownedGrants + uri)
                write(pendingGrant)
                ledger = pendingGrant
                resolver.takePersistableUriPermission(uri, Intent.FLAG_GRANT_READ_URI_PERMISSION)
            }
            val replacement = ledger.copy(attachments = ledger.attachments + (scope to document))
            write(replacement)
            ledger = replacement
        } finally {
            releaseUnusedGrants(ledger)
        }
    }

    fun remove(matches: (SubtitleScope) -> Boolean) {
        val ledger = load()
        val updated = ledger.copy(attachments = ledger.attachments.filterKeys { !matches(it) })
        if (updated != ledger) write(updated)
        releaseUnusedGrants(updated)
    }

    private fun hasReadGrant(uri: Uri) =
        resolver.persistedUriPermissions.any { it.uri == uri && it.isReadPermission }

    private fun releaseUnusedGrants(ledger: SubtitleLedger) {
        val referenced = ledger.attachments.values.mapTo(mutableSetOf()) { it.uri }
        val unused = ledger.ownedGrants - referenced
        if (unused.isEmpty()) return
        val grants = runCatching { resolver.persistedUriPermissions.associateBy { it.uri } }.getOrNull() ?: return
        val released = unused.filter { uri ->
            val grant = grants[uri]
            when {
                grant?.isReadPermission != true -> true
                grant.isWritePermission -> false
                else -> runCatching {
                    resolver.releasePersistableUriPermission(uri, Intent.FLAG_GRANT_READ_URI_PERMISSION)
                }.isSuccess
            }
        }
        if (released.isNotEmpty()) {
            // Keep cleanup retryable across a crash or a temporary storage failure.
            runCatching { write(ledger.copy(ownedGrants = ledger.ownedGrants - released.toSet())) }
        }
    }

    private fun load(): SubtitleLedger {
        try {
            val json = file.openRead().bufferedReader(Charsets.UTF_8).use { JSONObject(it.readText()) }
            val rows = json.getJSONArray("attachments")
            val attachments = buildMap {
                for (index in 0 until rows.length()) {
                    val row = rows.getJSONObject(index)
                    put(
                        SubtitleScope(row.getString("profileId"), row.getString("videoId")),
                        SubtitleDocument(contentUri(row.getString("uri")), row.getString("name")),
                    )
                }
            }
            val grants = json.getJSONArray("ownedGrants")
            return SubtitleLedger(attachments, buildSet {
                for (index in 0 until grants.length()) add(contentUri(grants.getString(index)))
            })
        } catch (_: FileNotFoundException) {
            if (!file.baseFile.exists()) return SubtitleLedger()
            throw storageError()
        } catch (_: Exception) {
            throw storageError()
        }
    }

    private fun contentUri(value: String): Uri = Uri.parse(value).also {
        require(it.scheme == ContentResolver.SCHEME_CONTENT && !it.authority.isNullOrBlank())
    }

    private fun write(ledger: SubtitleLedger) {
        val rows = JSONArray()
        for ((scope, document) in ledger.attachments) {
            rows.put(JSONObject()
                .put("profileId", scope.profileId)
                .put("videoId", scope.videoId)
                .put("uri", document.uri.toString())
                .put("name", document.name))
        }
        val json = JSONObject().put("attachments", rows)
            .put("ownedGrants", JSONArray(ledger.ownedGrants.map(Uri::toString)))
        val output = try {
            file.startWrite()
        } catch (_: IOException) {
            throw storageError()
        }
        try {
            output.write(json.toString().toByteArray(Charsets.UTF_8))
            file.finishWrite(output)
        } catch (_: IOException) {
            file.failWrite(output)
            throw storageError()
        }
    }

    private fun storageError() = SubtitleError("SUBTITLE_STORAGE", "Videre could not update the saved subtitle.")

    companion object {
        private const val MAX_SUBTITLE_BYTES = 8 * 1024 * 1024
    }
}
