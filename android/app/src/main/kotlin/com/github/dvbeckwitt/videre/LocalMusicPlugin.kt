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

class LocalMusicPlugin : FlutterPlugin, ActivityAware, PluginRegistry.ActivityResultListener,
    PluginRegistry.RequestPermissionsResultListener {
    private lateinit var context: Context
    private var channel: MethodChannel? = null
    private var activity: ActivityPluginBinding? = null
    private var picker: SourcePicker? = null
    private var systemPicker: SourcePicker? = null
    private var rename: RenameOperation? = null
    // A scan supersedes only earlier work for the same root. Completed signals
    // also guard download matching until that root is rescanned or removed.
    private val scans = mutableMapOf<String, CancellationSignal>()
    private val completedCatalogs = mutableMapOf<String, CompletedCatalog>()
    private val worker = Executors.newSingleThreadExecutor()
    private val accessWorker = Executors.newSingleThreadExecutor()
    private val main = Handler(Looper.getMainLooper())
    private val preferences get() = context.getSharedPreferences("videre_local_music", Context.MODE_PRIVATE)
    private val systemSource get() = MediaStore.Audio.Media.EXTERNAL_CONTENT_URI
    private val renameArchive get() = LocalMusicRenameArchive(File(context.noBackupFilesDir, "music-rename-events.json"))

    private data class CompletedCatalog(
        val selectionId: String?, val signal: CancellationSignal,
    )

    private class SourcePicker(val result: MethodChannel.Result) {
        val cancellation = CancellationSignal()
        var waitingForActivity = true
    }

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
            "getFolder" -> result.success(roots().channelValue())
            "pickFolder" -> pickFolder(call.argument("initialUri"), result)
            "pickSystem" -> pickSystem(result)
            "checkFolderAccess" -> revalidateAccess(call.argument("treeUri"), result)
            "listTracks" -> listTracks(call.argument("treeUri"), call.argument("scanId"), result)
            "matchDownloadTracks" -> run(result) {
                val tree = call.argument<String>("treeUri") ?: return@run null
                val completed = completedCatalogs[tree] ?: return@run null
                if (completed.selectionId != call.argument<String>("selectionId") ||
                    !catalogCurrent(tree, completed)) return@run null
                val slots = call.argument<List<*>>("files") ?: return@run null
                if (slots.size > 64) return@run null
                try {
                    if (checkFolderAccess(tree, completed.signal) != true) return@run null
                    val source = Uri.parse(tree)
                    val candidates = slots.mapNotNull(LocalMusicDownloadCandidate::parse)
                    val matches = catalog(source, completed.selectionId).matchDownloads(source, candidates, completed.signal)
                    matches.takeIf { catalogCurrent(tree, completed) && checkFolderAccess(tree, completed.signal) == true }
                } catch (_: OperationCanceledException) {
                    null
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
                if (tree != null) scans.remove(tree)?.cancel()
                run(result) { forgetRoots { it.uri == tree } }
            }
            "forgetFolders" -> {
                cancelPickers()
                scans.values.forEach(CancellationSignal::cancel)
                scans.clear()
                run(result) { forgetRoots { true } }
            }
            else -> result.notImplemented()
        }
    }

    private fun listTracks(tree: String?, scanId: Int?, result: MethodChannel.Result) {
        if (tree == null || roots().find(tree) == null) {
            result.error("FOLDER_UNAVAILABLE", "Choose the music folder again.", null)
            return
        }
        val signal = CancellationSignal()
        scans.put(tree, signal)?.cancel()
        run(result) {
            signal.throwIfCanceled()
            val root = roots().find(tree) ?: throw SecurityException()
            when (checkFolderAccess(tree, signal)) {
                null -> throw ProviderTemporarilyUnavailable()
                false -> throw SecurityException()
                true -> try {
                    val source = Uri.parse(tree)
                    val tracks = catalog(source, root.selectionId).tracks(source, signal) { batch ->
                        if (scanId != null) {
                            main.post {
                                if (scans[tree] === signal && !signal.isCanceled) {
                                    channel?.invokeMethod("trackBatch", mapOf("scanId" to scanId, "tracks" to batch))
                                }
                            }
                        }
                    }
                    signal.throwIfCanceled()
                    val completed = CompletedCatalog(root.selectionId, signal)
                    if (catalogCurrent(tree, completed)) completedCatalogs[tree] = completed
                    tracks
                } catch (cancelled: OperationCanceledException) {
                    throw cancelled
                } catch (_: Exception) {
                    signal.throwIfCanceled()
                    // Only a fresh negative root probe establishes a lost grant.
                    if (checkFolderAccess(tree, signal) == false) throw SecurityException()
                    throw ProviderTemporarilyUnavailable()
                }
            }
        }
    }

    private fun catalogCurrent(tree: String, catalog: CompletedCatalog): Boolean =
        !catalog.signal.isCanceled && roots().find(tree)?.let {
            it.selectionId == catalog.selectionId && !it.needsReapproval
        } == true

    private fun roots(): LocalMusicRoots = LocalMusicRoots.read(preferences.all)

    private fun saveRoots(configuration: LocalMusicRoots) {
        val edit = preferences.edit().putString(LocalMusicRoots.KEY, configuration.toJson())
        listOf("uri", "name", "selectionId", "ownsRead", "needsReapproval").forEach { edit.remove(it) }
        check(edit.commit())
    }

    private fun forgetRoots(remove: (LocalMusicRoot) -> Boolean): Map<String, Any?> {
        val current = roots()
        val removed = current.entries.filter(remove)
        if (removed.isEmpty()) return current.channelValue()
        for (root in removed) archiveRenames(Uri.parse(root.uri), root.selectionId)
        val updated = current.without(removed)
        saveRoots(updated)
        for (root in removed) {
            val source = Uri.parse(root.uri)
            completedCatalogs.remove(root.uri)
            releaseRead(source, root.ownsRead)
            clearLibraryCache(source, root.selectionId)
        }
        return updated.channelValue()
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
        picker = SourcePicker(result)
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
        val operation = picker ?: return true
        if (!operation.waitingForActivity) return true
        operation.waitingForActivity = false
        if (operation.cancellation.isCanceled || resultCode != Activity.RESULT_OK) {
            finishPicker(operation, null)
            return true
        }
        runPicker(operation, "FOLDER_UNAVAILABLE", "The music folder could not be opened.") {
            val tree = data?.data ?: throw IOException()
            require(tree.scheme == "content" && DocumentsContract.isTreeUri(tree))
            require(data.flags and Intent.FLAG_GRANT_READ_URI_PERMISSION != 0)
            selectFolder(tree, operation.cancellation)
        }
        return true
    }

    private fun selectFolder(tree: Uri, signal: CancellationSignal): LocalMusicRoots {
        val current = roots()
        val previous = current.find(tree.toString())
        val alreadyReadable = grant(tree)?.isReadPermission == true
        val selectionId = selectionIdForPick(previous?.selectionId, sameFolder = previous != null,
            hasReadGrant = alreadyReadable, needsReapproval = previous?.needsReapproval == true)
        context.contentResolver.takePersistableUriPermission(tree, Intent.FLAG_GRANT_READ_URI_PERMISSION)
        try {
            val root = LocalMusicRoot(tree.toString(), folderName(tree, signal), selectionId,
                ownsRead = !alreadyReadable || previous?.ownsRead == true)
            return approveRoot(current, previous, root, signal)
        } catch (failure: Exception) {
            releaseRead(tree, !alreadyReadable)
            throw failure
        }
    }

    private fun approveRoot(
        current: LocalMusicRoots, previous: LocalMusicRoot?, root: LocalMusicRoot, signal: CancellationSignal,
    ): LocalMusicRoots {
        val old = previous?.takeIf { it.selectionId != root.selectionId }
        val source = Uri.parse(root.uri)
        if (old != null) archiveRenames(source, old.selectionId)
        signal.throwIfCanceled()
        val updated = current.withRoot(root)
        saveRoots(updated)
        if (old != null) {
            completedCatalogs.remove(root.uri)
            clearLibraryCache(source, old.selectionId)
        }
        return updated
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
        val operation = SourcePicker(result)
        systemPicker = operation
        if (mayReadSystemAudio()) {
            completeSystemPick(operation)
            return
        }
        try {
            host.requestPermissions(arrayOf(audioPermission()), AUDIO_PERMISSION_REQUEST)
        } catch (_: RuntimeException) {
            systemPicker = null
            result.error("AUDIO_PERMISSION_DENIED", "Music and audio access is unavailable.", null)
        }
    }

    private fun completeSystemPick(operation: SourcePicker) {
        operation.waitingForActivity = false
        runPicker(operation, "AUDIO_PERMISSION_DENIED", "Music and audio access is unavailable.") {
            check(mayReadSystemAudio())
            val source = systemSource.toString()
            val current = roots()
            val previous = current.find(source)
            val selectionId = selectionIdForPick(previous?.selectionId, sameFolder = previous != null,
                hasReadGrant = true, needsReapproval = previous?.needsReapproval == true)
            approveRoot(current, previous, LocalMusicRoot(source, "Android music library", selectionId),
                operation.cancellation)
        }
    }

    private fun runPicker(operation: SourcePicker, code: String, message: String, action: () -> LocalMusicRoots) {
        worker.execute {
            try {
                operation.cancellation.throwIfCanceled()
                val updated = action()
                main.post { finishPicker(operation, updated.channelValue()) }
            } catch (_: Exception) {
                main.post { finishPicker(operation, null, code, message) }
            }
        }
    }

    private fun finishPicker(operation: SourcePicker, value: Any?, code: String? = null, message: String? = null) {
        if (picker !== operation && systemPicker !== operation) return
        if (picker === operation) picker = null
        if (systemPicker === operation) systemPicker = null
        if (operation.cancellation.isCanceled) return
        if (code == null) operation.result.success(value)
        else operation.result.error(code, message, null)
    }

    private fun cancelPickers() {
        for (operation in listOfNotNull(picker, systemPicker)) {
            if (operation.cancellation.isCanceled) continue
            operation.cancellation.cancel()
            operation.result.success(null)
            // Keep an outstanding platform request reserved until its callback arrives.
            if (!operation.waitingForActivity) finishPicker(operation, null)
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
        val operation = systemPicker ?: return true
        if (!operation.waitingForActivity) return true
        operation.waitingForActivity = false
        if (operation.cancellation.isCanceled) {
            finishPicker(operation, null)
            return true
        }
        if (grantResults.firstOrNull() == PackageManager.PERMISSION_GRANTED) {
            completeSystemPick(operation)
        } else {
            if (grantResults.isEmpty()) finishPicker(operation, null)
            else finishPicker(operation, null, "AUDIO_PERMISSION_DENIED", "Music and audio access was declined.")
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
        val root = roots().find(tree)
        if (root == null || root.needsReapproval || uri == null || name == null) {
            result.error("RENAME_FAILED", "The selected song could not be renamed.", null)
            return
        }
        val operation = RenameOperation(Uri.parse(root.uri), root.selectionId,
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
                val root = roots().find(source.toString())
                if (root == null || root.selectionId != operation.selectionId ||
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
        val root = roots().find(selected)
        if (root == null || root.needsReapproval) {
            result.success(false)
            return
        }
        // Keep grant checks responsive while the catalog worker reads slow tags.
        accessWorker.execute {
            val accessible = probeAccess(Uri.parse(root.uri))
            main.post {
                if (channel == null) return@post
                val current = roots().find(root.uri)
                when {
                    current == null || current.selectionId != root.selectionId -> result.success(null)
                    current.needsReapproval -> result.success(false)
                    accessible == false -> {
                        scans.remove(root.uri)?.cancel()
                        run(result) {
                            // Confirm again after any picker work already queued for this root.
                            val active = roots().find(root.uri)
                            if (active == null || active.selectionId != root.selectionId) null
                            else checkFolderAccess(root.uri)
                        }
                    }
                    else -> result.success(accessible)
                }
            }
        }
    }

    private fun checkFolderAccess(selected: String, signal: CancellationSignal? = null): Boolean? {
        val current = roots()
        val root = current.find(selected) ?: return false
        if (root.needsReapproval) return false
        val source = Uri.parse(root.uri)
        return probeAccess(source, signal).also {
            if (it == false) invalidateAccess(current, root, source)
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
    private fun invalidateAccess(current: LocalMusicRoots, root: LocalMusicRoot, source: Uri) {
        completedCatalogs.remove(root.uri)
        // If durable storage is unavailable, retain the index until rename
        // events can be archived. The revoked source still fails access checks.
        try {
            saveRoots(current.withRoot(root.copy(needsReapproval = true)))
            archiveRenames(source, root.selectionId)
            clearLibraryCache(source, root.selectionId)
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
        val visibilityAliases = File(context.noBackupFilesDir, "music-visibility-${cacheKey(source, null)}.json")
        return LocalMusicCatalog(context, coverDirectory(key), indexFile(key), visibilityAliases)
    }

    private fun pendingRenames(): List<Map<String, String>> =
        (renameArchive.read() + roots().entries.flatMap { root ->
            val source = Uri.parse(root.uri)
            catalog(source, root.selectionId).pendingRenames(source)
        }).distinctBy { it.getValue("id") }

    private fun archiveRenames(source: Uri, selectionId: String?) {
        renameArchive.retain(catalog(source, selectionId).pendingRenames(source))
    }

    private fun acknowledgeRename(oldUri: String, newUri: String, id: String?) {
        val event = pendingRenames().firstOrNull {
            it["oldUri"] == oldUri && it["newUri"] == newUri && (id == null || it["id"] == id)
        } ?: return
        val eventId = event.getValue("id")
        for (root in roots().entries) {
            val source = Uri.parse(root.uri)
            catalog(source, root.selectionId).acknowledgeRename(
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
        for (operation in listOfNotNull(picker, systemPicker)) {
            finishPicker(operation, null, "PICKER_UNAVAILABLE", "The music source chooser was interrupted.")
            operation.cancellation.cancel()
        }
        rename?.let { completeRename(it, null) }
    }
    override fun onDetachedFromEngine(binding: FlutterPlugin.FlutterPluginBinding) {
        onDetachedFromActivity()
        scans.values.forEach(CancellationSignal::cancel)
        scans.clear()
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
