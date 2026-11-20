package com.github.dvbeckwitt.videre

import android.Manifest
import android.app.Activity
import android.content.Context
import android.content.Intent
import android.content.pm.PackageManager
import android.net.Uri
import android.os.Build
import android.os.CancellationSignal
import android.os.Handler
import android.os.Looper
import android.os.OperationCanceledException
import android.provider.DocumentsContract
import android.provider.DocumentsContract.Document
import android.provider.MediaStore
import io.flutter.embedding.engine.plugins.FlutterPlugin
import io.flutter.embedding.engine.plugins.activity.ActivityAware
import io.flutter.embedding.engine.plugins.activity.ActivityPluginBinding
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import io.flutter.plugin.common.PluginRegistry
import java.io.File
import java.io.FileNotFoundException
import java.io.IOException
import java.security.MessageDigest
import java.util.UUID
import java.util.concurrent.Executors
import java.util.concurrent.atomic.AtomicLong

class LocalMusicPlugin : FlutterPlugin, ActivityAware, PluginRegistry.ActivityResultListener,
    PluginRegistry.RequestPermissionsResultListener {
    private lateinit var context: Context
    private var channel: MethodChannel? = null
    private var activity: ActivityPluginBinding? = null
    private var picker: MethodChannel.Result? = null
    private var systemPicker: MethodChannel.Result? = null
    private var rename: RenameOperation? = null
    private var scan: CancellationSignal? = null
    private val worker = Executors.newSingleThreadExecutor()
    private val accessWorker = Executors.newSingleThreadExecutor()
    private val sourceRevision = AtomicLong()
    private val main = Handler(Looper.getMainLooper())
    private val preferences get() = context.getSharedPreferences("videre_local_music", Context.MODE_PRIVATE)
    private val systemSource get() = MediaStore.Audio.Media.EXTERNAL_CONTENT_URI
    private val renameArchive get() = LocalMusicRenameArchive(File(context.noBackupFilesDir, "music-rename-events.json"))

    private class RenameOperation(
        val source: Uri,
        val selectionId: String?,
        val uri: Uri,
        val name: String,
        val result: MethodChannel.Result,
    ) {
        var consent: LocalMusicRename.Step.Consent? = null
    }

    override fun onAttachedToEngine(binding: FlutterPlugin.FlutterPluginBinding) {
        context = binding.applicationContext
        channel = MethodChannel(binding.binaryMessenger, "com.github.dvbeckwitt.videre/local_music").also {
            it.setMethodCallHandler(::handle)
        }
    }

    private fun handle(call: MethodCall, result: MethodChannel.Result) {
        when (call.method) {
            "getFolder" -> {
                // Reading just the preference snapshot also lets an opt-out cancel an active scan.
                val saved = preferences.all
                result.success((saved["uri"] as? String)?.let {
                    mapOf("uri" to it, "name" to saved["name"], "selectionId" to saved["selectionId"])
                })
            }
            "pickFolder" -> pickFolder(call.argument("initialUri"), result)
            "pickSystem" -> pickSystem(result)
            "checkFolderAccess" -> revalidateAccess(call.argument("treeUri"), result)
            "listTracks" -> {
                val tree = call.argument<String>("treeUri")
                val scanId = call.argument<Int>("scanId")
                scan?.cancel()
                val signal = CancellationSignal()
                scan = signal
                run(result) {
                    require(tree != null && tree == preferences.getString("uri", null))
                    when (checkFolderAccess(tree, signal)) {
                        null -> throw ProviderTemporarilyUnavailable()
                        false -> throw SecurityException()
                        true -> try {
                            val source = Uri.parse(tree)
                            catalog(source, preferences.getString("selectionId", null)).tracks(source, signal) { batch ->
                                if (scanId != null) {
                                    main.post {
                                        if (scan === signal && !signal.isCanceled) {
                                            channel?.invokeMethod("trackBatch", mapOf("scanId" to scanId, "tracks" to batch))
                                        }
                                    }
                                }
                            }
                        } catch (cancelled: OperationCanceledException) {
                            throw cancelled
                        } catch (_: Exception) {
                            signal.throwIfCanceled()
                            // Losing access to a child or failing to read its cursor does not
                            // revoke the grant. Only a fresh negative root probe establishes that.
                            if (checkFolderAccess(tree, signal) == false) throw SecurityException()
                            throw ProviderTemporarilyUnavailable()
                        }
                    }
                }
            }
            "renameTrack" -> beginRename(call, result)
            "pendingRenames" -> run(result) {
                pendingRenames()
            }
            "acknowledgeRename" -> run(result) {
                val oldUri = call.argument<String>("oldUri")
                val newUri = call.argument<String>("newUri")
                val id = call.argument<String>("id")
                if (oldUri != null && newUri != null) acknowledgeRename(oldUri, newUri, id)
                null
            }
            "forgetFolder" -> {
                val tree = call.argument<String>("treeUri")
                scan?.cancel()
                run(result) {
                    if (tree != null && tree == preferences.getString("uri", null)) {
                        val ownsRead = preferences.getBoolean("ownsRead", false)
                        val selectionId = preferences.getString("selectionId", null)
                        val source = Uri.parse(tree)
                        archiveRenames(source, selectionId)
                        sourceRevision.incrementAndGet()
                        check(preferences.edit().clear().commit())
                        releaseRead(source, ownsRead)
                        clearLibraryCache(source, selectionId)
                    }
                    null
                }
            }
            else -> result.notImplemented()
        }
    }

    private fun pickFolder(initial: String?, result: MethodChannel.Result) {
        val host = activity?.activity
        if (host == null || promptPending()) {
            result.error("PICKER_UNAVAILABLE", "The music folder picker is unavailable.", null)
            return
        }
        val intent = Intent(Intent.ACTION_OPEN_DOCUMENT_TREE).apply {
            addFlags(Intent.FLAG_GRANT_READ_URI_PERMISSION or Intent.FLAG_GRANT_PERSISTABLE_URI_PERMISSION or
                Intent.FLAG_GRANT_PREFIX_URI_PERMISSION)
            putExtra(Intent.EXTRA_LOCAL_ONLY, true)
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O && initial != null &&
                DocumentsContract.isTreeUri(Uri.parse(initial))) {
                putExtra(DocumentsContract.EXTRA_INITIAL_URI, Uri.parse(initial))
            }
        }
        picker = result
        try {
            host.startActivityForResult(intent, FOLDER_REQUEST)
        } catch (_: RuntimeException) {
            picker = null
            result.error("PICKER_UNAVAILABLE", "The music folder picker is unavailable.", null)
        }
    }

    override fun onActivityResult(requestCode: Int, resultCode: Int, data: Intent?): Boolean {
        if (requestCode == RENAME_REQUEST) {
            val operation = rename ?: return true
            val consent = operation.consent ?: return true
            if (resultCode == Activity.RESULT_OK) {
                operation.consent = null
                runRename(operation, consent, data)
            } else {
                completeRename(operation, null)
            }
            return true
        }
        if (requestCode != FOLDER_REQUEST) return false
        val result = picker ?: return true
        picker = null
        if (resultCode != Activity.RESULT_OK) {
            result.success(null)
            return true
        }
        scan?.cancel()
        run(result) {
            val tree = data?.data ?: throw IOException()
            require(tree.scheme == "content" && DocumentsContract.isTreeUri(tree))
            require(data.flags and Intent.FLAG_GRANT_READ_URI_PERMISSION != 0)
            selectFolder(tree)
        }
        return true
    }

    private fun selectFolder(tree: Uri): Map<String, String?> {
        val old = preferences.getString("uri", null)
        val oldSelection = preferences.getString("selectionId", null)
        val oldOwned = preferences.getBoolean("ownsRead", false)
        val alreadyReadable = grant(tree)?.isReadPermission == true
        // An uninterrupted older grant has no selection ID. After a folder is
        // forgotten, replaced, or revoked, even the same URI is a new approval.
        val selectionId = selectionIdForPick(oldSelection,
            sameFolder = old == tree.toString(), hasReadGrant = alreadyReadable,
            needsReapproval = preferences.getBoolean("needsReapproval", false))
        context.contentResolver.takePersistableUriPermission(tree, Intent.FLAG_GRANT_READ_URI_PERMISSION)
        val name = try {
            val display = folderName(tree, null)
            if (old != null && (old != tree.toString() || oldSelection != selectionId)) {
                archiveRenames(Uri.parse(old), oldSelection)
            }
            sourceRevision.incrementAndGet()
            check(preferences.edit().putString("uri", tree.toString()).putString("name", display)
                .putString("selectionId", selectionId).remove("needsReapproval")
                .putBoolean("ownsRead", !alreadyReadable || (old == tree.toString() && oldOwned)).commit())
            display
        } catch (failure: Exception) {
            releaseRead(tree, !alreadyReadable)
            throw failure
        }
        if (old != null && (old != tree.toString() || oldSelection != selectionId)) {
            val previous = Uri.parse(old)
            if (previous != tree) releaseRead(previous, oldOwned)
            clearLibraryCache(previous, oldSelection)
        }
        return mapOf("uri" to tree.toString(), "name" to name, "selectionId" to selectionId)
    }

    private fun promptPending() = picker != null || systemPicker != null || rename != null

    private fun audioPermission() =
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU) Manifest.permission.READ_MEDIA_AUDIO
        else Manifest.permission.READ_EXTERNAL_STORAGE

    private fun mayReadSystemAudio() =
        context.checkSelfPermission(audioPermission()) == PackageManager.PERMISSION_GRANTED

    private fun pickSystem(result: MethodChannel.Result) {
        val host = activity?.activity
        if (host == null || promptPending()) {
            result.error("PICKER_UNAVAILABLE", "The music source chooser is unavailable.", null)
            return
        }
        systemPicker = result
        if (mayReadSystemAudio()) {
            completeSystemPick(result)
            return
        }
        try {
            host.requestPermissions(arrayOf(audioPermission()), AUDIO_PERMISSION_REQUEST)
        } catch (_: RuntimeException) {
            systemPicker = null
            result.error("AUDIO_PERMISSION_DENIED", "Music and audio access is unavailable.", null)
        }
    }

    private fun completeSystemPick(result: MethodChannel.Result) {
        scan?.cancel()
        worker.execute {
            try {
                check(mayReadSystemAudio())
                val source = systemSource.toString()
                val old = preferences.getString("uri", null)
                val oldSelection = preferences.getString("selectionId", null)
                val oldOwned = preferences.getBoolean("ownsRead", false)
                val selectionId = oldSelection?.takeIf {
                    old == source && !preferences.getBoolean("needsReapproval", false)
                } ?: UUID.randomUUID().toString()
                val name = "Android music library"
                if (old != null && (old != source || oldSelection != selectionId)) {
                    archiveRenames(Uri.parse(old), oldSelection)
                }
                sourceRevision.incrementAndGet()
                check(preferences.edit().putString("uri", source).putString("name", name)
                    .putString("selectionId", selectionId).remove("needsReapproval")
                    .remove("ownsRead").commit())
                if (old != null && (old != source || oldSelection != selectionId)) {
                    val previous = Uri.parse(old)
                    releaseRead(previous, oldOwned)
                    clearLibraryCache(previous, oldSelection)
                }
                main.post {
                    if (systemPicker === result) {
                        systemPicker = null
                        result.success(mapOf("uri" to source, "name" to name, "selectionId" to selectionId))
                    }
                }
            } catch (_: Exception) {
                main.post {
                    if (systemPicker === result) {
                        systemPicker = null
                        result.error("AUDIO_PERMISSION_DENIED", "Music and audio access is unavailable.", null)
                    }
                }
            }
        }
    }

    override fun onRequestPermissionsResult(
        requestCode: Int,
        permissions: Array<out String>,
        grantResults: IntArray,
    ): Boolean {
        if (requestCode == RENAME_PERMISSION_REQUEST) {
            val operation = rename ?: return true
            val consent = operation.consent ?: return true
            operation.consent = null
            if (grantResults.firstOrNull() == PackageManager.PERMISSION_GRANTED) {
                runRename(operation, consent)
            } else {
                completeRename(operation, null)
            }
            return true
        }
        if (requestCode != AUDIO_PERMISSION_REQUEST) return false
        val result = systemPicker ?: return true
        if (grantResults.firstOrNull() == PackageManager.PERMISSION_GRANTED) {
            completeSystemPick(result)
        } else {
            systemPicker = null
            if (grantResults.isEmpty()) result.success(null)
            else result.error("AUDIO_PERMISSION_DENIED", "Music and audio access was declined.", null)
        }
        return true
    }

    private fun beginRename(call: MethodCall, result: MethodChannel.Result) {
        if (promptPending()) {
            result.error("RENAME_FAILED", "A music source operation is already in progress.", null)
            return
        }
        val tree = call.argument<String>("treeUri")
        val uri = call.argument<String>("uri")
        val name = call.argument<String>("name")
        val saved = preferences.all
        if (tree == null || tree != saved["uri"] || uri == null || name == null) {
            result.error("RENAME_FAILED", "The selected song could not be renamed.", null)
            return
        }
        val operation = RenameOperation(Uri.parse(tree), saved["selectionId"] as? String,
            Uri.parse(uri), name, result)
        rename = operation
        runRename(operation)
    }

    private fun runRename(
        operation: RenameOperation,
        consent: LocalMusicRename.Step.Consent? = null,
        data: Intent? = null,
    ) {
        worker.execute {
            val source = operation.source
            val uri = operation.uri
            try {
                if (preferences.getString("selectionId", null) != operation.selectionId ||
                    checkFolderAccess(source.toString()) != true) {
                    throw LocalMusicRename.Failure("RENAME_FAILED")
                }
                val catalog = catalog(source, operation.selectionId)
                val track = catalog.indexedTrack(source, uri)
                    ?: throw LocalMusicRename.Failure("RENAME_FAILED")
                if (track["canRename"] != true) throw LocalMusicRename.Failure("RENAME_UNSUPPORTED")
                val renamer = LocalMusicRename(context) { tree, document, fullName ->
                    catalog.prepareRename(tree, document, fullName)
                }
                when (val step = if (consent == null) {
                    renamer.begin(source, uri, operation.name, track["parentDocumentId"] as? String,
                        track["fileName"] as? String)
                } else {
                    renamer.finish(consent, data)
                }) {
                    is LocalMusicRename.Step.Done -> {
                        val updated = catalog.renamedTrack(source, uri, step.uri, step.fileName)
                        main.post { completeRename(operation, updated) }
                    }
                    is LocalMusicRename.Step.Consent -> {
                        // The first attempt was denied before mutation. Only recreate the
                        // durable journal when the user authorizes the retry.
                        catalog.cancelRename(source, uri)
                        main.post { requestRenameConsent(operation, step) }
                    }
                }
            } catch (failure: LocalMusicRename.Failure) {
                main.post { completeRename(operation, null, failure.code) }
            } catch (_: Exception) {
                main.post { completeRename(operation, null, "RENAME_FAILED") }
            }
        }
    }

    private fun requestRenameConsent(operation: RenameOperation, consent: LocalMusicRename.Step.Consent) {
        if (rename !== operation) return
        val host = activity?.activity
        if (host == null) {
            completeRename(operation, null, "RENAME_FAILED")
            return
        }
        operation.consent = consent
        try {
            when (val request = consent.request) {
                is LocalMusicRename.Request.SelectDocument ->
                    host.startActivityForResult(request.intent, RENAME_REQUEST)
                is LocalMusicRename.Request.Write ->
                    host.startIntentSenderForResult(request.sender, RENAME_REQUEST, null, 0, 0, 0)
                is LocalMusicRename.Request.LegacyWrite ->
                    host.requestPermissions(arrayOf(request.permission), RENAME_PERMISSION_REQUEST)
            }
        } catch (_: Exception) {
            completeRename(operation, null, "RENAME_FAILED")
        }
    }

    private fun completeRename(operation: RenameOperation, updated: Map<String, Any?>?, error: String? = null) {
        if (rename !== operation) return
        rename = null
        if (error == null) operation.result.success(updated)
        else operation.result.error(error, "The selected song could not be renamed.", null)
    }

    private fun folderName(tree: Uri, signal: CancellationSignal?): String {
        val root = DocumentsContract.buildDocumentUriUsingTree(tree, DocumentsContract.getTreeDocumentId(tree))
        return context.contentResolver.query(root, arrayOf(Document.COLUMN_DISPLAY_NAME, Document.COLUMN_MIME_TYPE),
            null, null, null, signal)?.use {
            if (it.moveToFirst() && it.getString(1) == Document.MIME_TYPE_DIR) it.getString(0) else null
        } ?: throw IOException()
    }

    private fun grant(tree: Uri) = context.contentResolver.persistedUriPermissions.firstOrNull { it.uri == tree }

    private fun revalidateAccess(selected: String?, result: MethodChannel.Result) {
        val revision = sourceRevision.get()
        val snapshot = preferences.all
        if (selected == null || selected != snapshot["uri"] || snapshot["needsReapproval"] == true) {
            result.success(false)
            return
        }
        val source = Uri.parse(selected)
        val selectionId = snapshot["selectionId"] as? String
        // Keep grant checks responsive while the catalog worker reads slow tags.
        accessWorker.execute {
            val accessible = probeAccess(source)
            main.post {
                if (channel == null) return@post
                val current = preferences.all
                when {
                    sourceRevision.get() != revision ||
                        current["uri"] != selected || current["selectionId"] != selectionId ->
                        result.success(null)
                    current["needsReapproval"] == true ->
                        result.success(false)
                    else -> {
                        if (accessible == false) {
                            scan?.cancel()
                            worker.execute {
                                val active = preferences.all
                                if (sourceRevision.get() == revision &&
                                    active["uri"] == selected && active["selectionId"] == selectionId) {
                                    invalidateAccess(source, selectionId)
                                }
                            }
                        }
                        result.success(accessible)
                    }
                }
            }
        }
    }

    private fun checkFolderAccess(selected: String?, signal: CancellationSignal? = null): Boolean? {
        if (selected == null || selected != preferences.getString("uri", null)) return false
        if (preferences.getBoolean("needsReapproval", false)) return false
        val source = Uri.parse(selected)
        return probeAccess(source, signal).also {
            if (it == false) invalidateAccess(source, preferences.getString("selectionId", null))
        }
    }

    // A grant can outlive the selected directory. Only inspect its root, without
    // enumerating children, opening media or displaying another permission prompt.
    private fun probeAccess(tree: Uri, signal: CancellationSignal? = null): Boolean? =
        try {
            if (tree == systemSource) mayReadSystemAudio()
            else if (grant(tree)?.isReadPermission != true) false
            else {
                val root = DocumentsContract.buildDocumentUriUsingTree(tree, DocumentsContract.getTreeDocumentId(tree))
                val cursor = context.contentResolver.query(root, arrayOf(Document.COLUMN_MIME_TYPE), null, null, null, signal)
                if (cursor == null) {
                    // DocumentsProvider can translate a missing document to a null cursor.
                    // A supported path lookup can in turn report FileNotFoundException.
                    if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
                        DocumentsContract.findDocumentPath(context.contentResolver, root)
                    }
                    null
                } else cursor.use {
                    if (it.extras.getBoolean(DocumentsContract.EXTRA_LOADING, false) ||
                        it.extras.containsKey(DocumentsContract.EXTRA_ERROR)) null
                    else it.moveToFirst() && it.getString(0) == Document.MIME_TYPE_DIR
                }
            }
        } catch (_: FileNotFoundException) {
            false
        } catch (_: IOException) {
            null
        } catch (_: SecurityException) {
            false
        } catch (cancelled: OperationCanceledException) {
            throw cancelled
        } catch (_: RuntimeException) {
            // An interrupted provider or a temporarily unavailable cursor proves no loss.
            null
        }
    private fun invalidateAccess(source: Uri, selectionId: String?) {
        sourceRevision.incrementAndGet()
        preferences.edit().putBoolean("needsReapproval", true).apply()
        // If durable storage is unavailable, retain the index until rename
        // events can be archived. The revoked source still fails access checks.
        try {
            archiveRenames(source, selectionId)
            clearLibraryCache(source, selectionId)
        } catch (_: Exception) { }
    }

    private fun releaseRead(tree: Uri, owned: Boolean) {
        // Android shares a grant across the app. Downloads may use this same tree for writing.
        if (!owned) return
        val saved = grant(tree) ?: return
        if (saved.isReadPermission && !saved.isWritePermission) {
            try {
                context.contentResolver.releasePersistableUriPermission(tree, Intent.FLAG_GRANT_READ_URI_PERMISSION)
            } catch (_: SecurityException) { /* The grant was already revoked. */ }
        }
    }

    private fun cacheKey(source: Uri, selectionId: String?): String =
        MessageDigest.getInstance("SHA-256")
            .digest("${source}\n${selectionId.orEmpty()}".toByteArray(Charsets.UTF_8))
            .joinToString("") { "%02x".format(it.toInt() and 0xff) }

    private fun indexFile(key: String) = File(context.noBackupFilesDir, "music-index-$key.json")
    private fun coverDirectory(key: String) = File(context.cacheDir, "music-covers-$key")

    private fun catalog(source: Uri, selectionId: String?): LocalMusicCatalog {
        val key = cacheKey(source, selectionId)
        return LocalMusicCatalog(context, coverDirectory(key), indexFile(key))
    }

    private fun activeRenameEvents(): List<Map<String, String>> {
        val source = preferences.getString("uri", null)?.let(Uri::parse) ?: return emptyList()
        return catalog(source, preferences.getString("selectionId", null)).pendingRenames(source)
    }

    private fun pendingRenames(): List<Map<String, String>> =
        (renameArchive.read() + activeRenameEvents()).distinctBy { it.getValue("id") }

    private fun archiveRenames(source: Uri, selectionId: String?) {
        renameArchive.retain(catalog(source, selectionId).pendingRenames(source))
    }

    private fun acknowledgeRename(oldUri: String, newUri: String, id: String?) {
        val event = pendingRenames().firstOrNull {
            it["oldUri"] == oldUri && it["newUri"] == newUri && (id == null || it["id"] == id)
        } ?: return
        val eventId = event.getValue("id")
        preferences.getString("uri", null)?.let(Uri::parse)?.let { source ->
            catalog(source, preferences.getString("selectionId", null)).acknowledgeRename(
                source, Uri.parse(oldUri), Uri.parse(newUri), eventId)
        }
        renameArchive.remove(eventId)
    }

    private fun clearLibraryCache(source: Uri, selectionId: String?) {
        val key = cacheKey(source, selectionId)
        android.util.AtomicFile(indexFile(key)).delete()
        for (directory in listOf(coverDirectory(key), File(context.cacheDir, "local_music_covers"))) {
            directory.listFiles()?.forEach { it.delete() }
            directory.delete()
        }
    }

    private fun run(result: MethodChannel.Result, action: () -> Any?) {
        worker.execute {
            try {
                val value = action()
                main.post { if (channel != null) result.success(value) }
            } catch (_: OperationCanceledException) {
                main.post { if (channel != null) result.error("SCAN_CANCELLED", "The music scan was cancelled.", null) }
            } catch (_: ProviderTemporarilyUnavailable) {
                main.post { if (channel != null) result.error("SCAN_UNAVAILABLE", "The music scan is temporarily unavailable.", null) }
            } catch (_: Exception) {
                // A provider error may contain a device path or account name.
                main.post { if (channel != null) result.error("FOLDER_UNAVAILABLE", "Choose the music folder again.", null) }
            }
        }
    }

    private class ProviderTemporarilyUnavailable : Exception()

    override fun onAttachedToActivity(binding: ActivityPluginBinding) {
        activity = binding
        binding.addActivityResultListener(this)
        binding.addRequestPermissionsResultListener(this)
    }
    override fun onReattachedToActivityForConfigChanges(binding: ActivityPluginBinding) = onAttachedToActivity(binding)
    override fun onDetachedFromActivityForConfigChanges() {
        activity?.removeActivityResultListener(this)
        activity?.removeRequestPermissionsResultListener(this)
        activity = null
    }
    override fun onDetachedFromActivity() {
        onDetachedFromActivityForConfigChanges()
        picker?.error("PICKER_UNAVAILABLE", "The music folder picker was interrupted.", null)
        picker = null
        systemPicker?.error("PICKER_UNAVAILABLE", "The music source chooser was interrupted.", null)
        systemPicker = null
        rename?.let { completeRename(it, null) }
    }
    override fun onDetachedFromEngine(binding: FlutterPlugin.FlutterPluginBinding) {
        onDetachedFromActivity()
        scan?.cancel()
        accessWorker.shutdownNow()
        worker.shutdownNow()
        channel?.setMethodCallHandler(null)
        channel = null
    }

    companion object {
        private const val FOLDER_REQUEST = 4403
        private const val AUDIO_PERMISSION_REQUEST = 4404
        private const val RENAME_REQUEST = 4405
        private const val RENAME_PERMISSION_REQUEST = 4406

        internal fun selectionIdForPick(previous: String?, sameFolder: Boolean,
            hasReadGrant: Boolean, needsReapproval: Boolean): String? =
            if (sameFolder && hasReadGrant && !needsReapproval) previous else UUID.randomUUID().toString()
    }
}
