package com.github.dvbeckwitt.videre

import android.Manifest
import android.app.Activity
import android.content.ContentResolver
import android.content.Context
import android.content.Intent
import android.content.pm.PackageManager
import android.net.Uri
import android.os.Build
import android.os.Bundle
import android.os.CancellationSignal
import android.os.Handler
import android.os.Looper
import android.os.OperationCanceledException
import android.os.Process
import android.provider.DocumentsContract
import android.provider.DocumentsContract.Document
import android.provider.MediaStore
import android.system.Os
import android.system.OsConstants
import android.webkit.MimeTypeMap
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
import java.util.Locale
import java.util.UUID
import java.util.concurrent.Executors

class LocalMusicPlugin : FlutterPlugin, ActivityAware, PluginRegistry.ActivityResultListener,
    PluginRegistry.RequestPermissionsResultListener {
    private lateinit var context: Context
    private var channel: MethodChannel? = null
    private var activity: ActivityPluginBinding? = null
    private var picker: SourcePicker? = null
    private var systemPicker: SourcePicker? = null
    private var pendingShare: PendingShare? = null
    private var rename: RenameOperation? = null
    @Volatile private var tagEdit: TagEditOperation? = null
    // A scan supersedes only earlier work for the same root. Completed signals
    // also guard download matching until that root is rescanned or removed.
    private val scans = mutableMapOf<String, RootScan>()
    private val completedCatalogs = mutableMapOf<String, CompletedCatalog>()
    private lateinit var scanWatcher: LocalMusicScanWatcher
    private var watchId: Int? = null
    private val observedCatalogs = mutableMapOf<String, ObservedCatalog>()
    private val worker = Executors.newSingleThreadExecutor()
    private val accessWorker = Executors.newSingleThreadExecutor()
    private val playbackProbeWorker = Executors.newSingleThreadExecutor()
    private var playbackProbe: CancellationSignal? = null
    private val main = Handler(Looper.getMainLooper())
    private val preferences get() = context.getSharedPreferences("videre_local_music", Context.MODE_PRIVATE)
    private val scanPreferences get() = context.getSharedPreferences("videre_local_music_scan", Context.MODE_PRIVATE)
    private val systemSource get() = MediaStore.Audio.Media.EXTERNAL_CONTENT_URI
    private val renameArchive get() = LocalMusicRenameArchive(File(context.noBackupFilesDir, "music-rename-events.json"))

    private data class CompletedCatalog(
        val selectionId: String?, val signal: CancellationSignal,
    )

    private class SourcePicker(
        val result: MethodChannel.Result,
        val allowDocumentProviders: Boolean = false,
    ) {
        val cancellation = CancellationSignal()
        var waitingForActivity = true
    }

    private data class RootScan(val signal: CancellationSignal, var id: Int?)
    private data class ObservedCatalog(val selectionId: String?, val uris: Set<Uri>)

    private class RenameOperation(
        val source: Uri,
        val selectionId: String?,
        val uri: Uri,
        val name: String,
        val loadCovers: Boolean,
        val result: MethodChannel.Result,
    ) {
        var consent: LocalMusicRename.Step.Consent? = null
    }

    private data class TagTarget(
        val source: Uri, val selectionId: String?, val uri: Uri, val loadCovers: Boolean,
    )

    private class TagEditOperation(
        val target: TagTarget,
        val fileRevision: String,
        val changes: Map<String, String?>,
        val artwork: LocalMusicId3.ArtworkEdit?,
        val lyrics: LocalMusicUslt.Edit?,
        val result: MethodChannel.Result,
    ) {
        var consent: LocalMusicTagEdit.Step.Consent? = null
    }

    override fun onAttachedToEngine(binding: FlutterPlugin.FlutterPluginBinding) {
        context = binding.applicationContext
        scanWatcher = LocalMusicScanWatcher(context.contentResolver, main) { source ->
            val tree = source.toString()
            val id = watchId
            if (id != null && automaticScan() && roots().find(tree)?.needsReapproval == false) {
                channel?.invokeMethod("libraryChanged", mapOf("watchId" to id, "treeUri" to tree))
            }
        }
        channel = MethodChannel(binding.binaryMessenger, "com.github.dvbeckwitt.videre/local_music").also {
            it.setMethodCallHandler(::handle)
        }
    }

    private fun handle(call: MethodCall, result: MethodChannel.Result) {
        when (call.method) {
            "getFolder" -> {
                val folder = roots().channelValue() + ("tagSeparators" to tagSeparators())
                if (call.argument<Boolean>("includeScanPreference") == true) {
                    result.success(mapOf("folder" to folder, "automaticScan" to automaticScan()))
                } else {
                    result.success(folder)
                }
            }
            "setAutomaticScan" -> {
                scanPreferences.edit().putBoolean("enabled", call.argument<Boolean>("enabled") == true).apply()
                refreshScanWatcher()
                result.success(null)
            }
            "watchLibrary" -> {
                watchId = call.argument<Int>("watchId")
                refreshScanWatcher()
                result.success(null)
            }
            "cancelScan", "cancelTrackScan" -> {
                val id = call.argument<Int>("scanId")
                if (id != null) scans.values.firstOrNull { it.id == id }?.signal?.cancel()
                result.success(null)
            }
            "pickFolder" -> pickFolder(call.argument("initialUri"), allowDocumentProviders = false, result)
            "pickProviderFolder" -> pickFolder(call.argument("initialUri"), allowDocumentProviders = true, result)
            "setTagSeparators" -> run(result) {
                val value = call.argument<String>("separators") ?: return@run false
                if (value.length > LOCAL_MUSIC_TAG_SEPARATOR_OPTIONS.length ||
                    value.any { it !in LOCAL_MUSIC_TAG_SEPARATOR_OPTIONS }) return@run false
                val separators = LOCAL_MUSIC_TAG_SEPARATOR_OPTIONS.filter { it in value }
                val previous = tagSeparators()
                val saved = preferences.edit().putString("tagSeparators", separators).commit()
                if (!saved) preferences.edit().putString("tagSeparators", previous).apply()
                saved
            }
            "pickSystem" -> pickSystem(result)
            "checkFolderAccess" -> revalidateAccess(call.argument("treeUri"), result)
            "resolveOpenedAudio" -> run(result) {
                try {
                    resolveOpenedAudio(call)
                } catch (_: Exception) {
                    null
                }
            }
            "artworkCacheStatus", "clearArtworkCache" -> run(
                result, "ARTWORK_CACHE_UNAVAILABLE", "Could not manage extracted device artwork.",
            ) {
                val storage = LocalMusicArtworkStorage(context.cacheDir)
                if (call.method == "clearArtworkCache") storage.clear() else storage.status()
            }
            "listTracks" -> listTracks(
                call.argument("treeUri"), call.argument("scanId"),
                call.argument<Boolean>("force") == true, call.argument<Boolean>("detailed") == true,
                call.argument<Boolean>("loadCovers") != false, result,
            )
            "listIndexedPlaylists" -> run(result) {
                val tree = call.argument<String>("treeUri") ?: return@run null
                if (tree != systemSource.toString()) return@run null
                val completed = completedCatalogs[tree] ?: return@run null
                if (completed.selectionId != call.argument<String>("selectionId") ||
                    !catalogCurrent(tree, completed)) return@run null
                try {
                    if (checkFolderAccess(tree, completed.signal) != true) return@run null
                    readIndexedMusicPlaylists(context.contentResolver, completed.signal)?.takeIf {
                        checkFolderAccess(tree, completed.signal) == true && catalogCurrent(tree, completed)
                    }
                } catch (_: RuntimeException) {
                    // Playlist compatibility tables can be unavailable independently of audio.
                    null
                }
            }
            "canSeekProviderTrack" -> canSeekProviderTrack(call, result)
            "matchDownloadTracks" -> run(result) {
                val tree = call.argument<String>("treeUri") ?: return@run null
                if (roots().find(tree)?.isDocumentProvider != false) return@run null
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
            "readTrackLyrics" -> readTrack(call, result, LocalMusicCatalog::readTrackLyrics)
            "readTrackAudioFormat" -> readTrack(call, result, LocalMusicCatalog::readTrackAudioFormat)
            "listMovedFileRepairs", "confirmMovedFileRepair" -> reviewMovedFiles(call, result)
            "playlistLocations" -> run(result) {
                val tree = call.argument<String>("treeUri") ?: return@run null
                val completed = completedCatalogs[tree] ?: return@run null
                if (completed.selectionId != call.argument<String>("selectionId")) return@run null
                fun authorized() = catalogCurrent(tree, completed) &&
                    checkFolderAccess(tree, completed.signal) == true

                try {
                    if (!authorized()) return@run null
                    val source = Uri.parse(tree)
                    catalog(source, completed.selectionId)
                        .playlistLocations(source, completed.signal)
                        .takeIf { authorized() }
                } catch (_: OperationCanceledException) {
                    null
                }
            }
            "renameTrack" -> beginRename(call, result)
            "shareTrack" -> beginShare(result, listOfNotNull(call.arguments as? Map<*, *>))
            "shareTracks" -> {
                val tracks = call.argument<List<*>>("tracks").orEmpty()
                val requestId = call.argument<Int>("requestId")
                val requests = tracks.filterIsInstance<Map<*, *>>()
                if (requestId == null || requests.size < 2 || requests.size != tracks.size) {
                    result.success(false)
                } else {
                    beginShare(result, requests, requestId)
                }
            }
            "cancelShareTracks" -> {
                val requestId = call.argument<Int>("requestId")
                if (requestId != null && requestId == pendingShare?.requestId) cancelPendingShare()
                result.success(null)
            }
            "readTrackTags" -> readTrackTags(call, result)
            "editTrackTags" -> beginTagEdit(call, result)
            "canSetTrackRingtone" -> trackRingtone(call, result, probe = true)
            "setTrackRingtone" -> trackRingtone(call, result, probe = false)
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
                if (tree != null) {
                    cancelPendingShare(tree)
                    scans.remove(tree)?.signal?.cancel()
                }
                run(result) { forgetRoots { it.uri == tree } }
            }
            "forgetFolders" -> {
                cancelPendingShare()
                cancelPickers()
                scans.values.forEach { it.signal.cancel() }
                scans.clear()
                run(result) { forgetRoots { true } }
            }
            else -> result.notImplemented()
        }
    }

    private fun listTracks(
        tree: String?, scanId: Int?, force: Boolean, detailed: Boolean, loadCovers: Boolean, result: MethodChannel.Result,
    ) {
        if (tree == null || roots().find(tree) == null) {
            result.error("FOLDER_UNAVAILABLE", "Choose the music folder again.", null)
            return
        }
        val signal = CancellationSignal()
        val scan = RootScan(signal, scanId)
        scans.put(tree, scan)?.signal?.cancel()
        run(result, finished = { if (scans[tree] === scan) scan.id = null }) {
            signal.throwIfCanceled()
            val root = roots().find(tree) ?: throw SecurityException()
            when (checkFolderAccess(tree, signal)) {
                null -> throw ProviderTemporarilyUnavailable()
                false -> throw SecurityException()
                true -> try {
                    val source = Uri.parse(tree)
                    val report = if (detailed) LocalMusicScanReport() else null
                    val scanned = catalog(source, root.selectionId, loadCovers).tracks(
                        source, signal, force, isDocumentProvider = root.isDocumentProvider, report = report,
                    ) { batch ->
                        if (scanId != null && !root.isDocumentProvider) {
                            main.post {
                                if (scans[tree] === scan && !signal.isCanceled) {
                                    channel?.invokeMethod("trackBatch", mapOf("scanId" to scanId, "tracks" to batch))
                                }
                            }
                        }
                    }
                    when (checkFolderAccess(tree, signal)) {
                        false -> throw SecurityException()
                        null -> throw ProviderTemporarilyUnavailable()
                        true -> Unit
                    }
                    signal.throwIfCanceled()
                    val completed = CompletedCatalog(root.selectionId, signal)
                    if (!catalogCurrent(tree, completed)) throw SecurityException()
                    if (!scanned.partial) completedCatalogs[tree] = completed
                    main.post {
                        if (scans[tree] === scan && catalogCurrent(tree, completed)) {
                            val previous = observedCatalogs[tree]?.takeIf {
                                scanned.partial && it.selectionId == root.selectionId
                            }?.uris.orEmpty()
                            val targets = (scanned.notificationUris + previous)
                                .take(LocalMusicScanWatcher.MAX_NOTIFICATION_URIS).toSet()
                            observedCatalogs[tree] = ObservedCatalog(root.selectionId, targets)
                            refreshScanWatcher()
                        }
                    }
                    report?.channelResult(scanned.tracks)?.plus("partial" to scanned.partial) ?: scanned.tracks
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

    private fun automaticScan() = scanPreferences.getBoolean("enabled", false)

    private fun refreshScanWatcher() {
        val eligibleRoots = roots().entries.filterNot { it.needsReapproval }
        val activeUris = eligibleRoots.mapTo(mutableSetOf()) { it.uri }
        observedCatalogs.keys.retainAll(activeUris)
        if (watchId == null || !automaticScan()) {
            scanWatcher.close()
            return
        }
        scanWatcher.watch(eligibleRoots.associate { root ->
            val targets = observedCatalogs[root.uri]?.takeIf {
                it.selectionId == root.selectionId
            }?.uris.orEmpty()
            Uri.parse(root.uri) to targets
        })
    }

    private fun rootCurrent(tree: String?, selectionId: String?): Boolean =
        roots().find(tree)?.let { it.selectionId == selectionId && !it.needsReapproval } == true

    private fun catalogCurrent(tree: String, catalog: CompletedCatalog): Boolean =
        !catalog.signal.isCanceled && rootCurrent(tree, catalog.selectionId)

    private fun canSeekProviderTrack(call: MethodCall, result: MethodChannel.Result) {
        val tree = call.argument<String>("treeUri")
        val selectionId = call.argument<String>("selectionId")
        val uri = call.argument<String>("uri")
        val root = roots().find(tree)
        if (root == null || !root.isDocumentProvider || root.needsReapproval ||
            root.selectionId != selectionId || uri == null) {
            result.success(false)
            return
        }
        val signal = CancellationSignal()
        playbackProbe?.cancel()
        playbackProbe = signal
        var replied = false
        fun finish(seekable: Boolean) {
            if (replied) return
            replied = true
            if (playbackProbe === signal) playbackProbe = null
            if (channel != null) {
                result.success(seekable && !signal.isCanceled && roots().find(tree) == root)
            }
        }
        val timeout = Runnable {
            finish(false)
            signal.cancel()
        }
        main.postDelayed(timeout, SEEK_PROBE_TIMEOUT_MS)
        playbackProbeWorker.execute {
            val seekable = try {
                signal.throwIfCanceled()
                val source = Uri.parse(root.uri)
                val document = Uri.parse(uri)
                if (roots().find(tree) != root || grant(source)?.isReadPermission != true ||
                    !catalog(source, selectionId).containsCommittedTrack(source, document)) false
                else {
                    // Match Media3's content source, which requests the original media.
                    val options = Bundle().apply {
                        putBoolean(MediaStore.EXTRA_ACCEPT_ORIGINAL_MEDIA_FORMAT, true)
                    }
                    context.contentResolver.openTypedAssetFileDescriptor(document, "*/*", options, signal)?.use {
                        Os.lseek(it.fileDescriptor, 0L, OsConstants.SEEK_CUR)
                    } != null
                }
            } catch (_: Exception) {
                // Pipes, disconnected providers and lost grants cannot establish seekability.
                false
            }
            main.post {
                main.removeCallbacks(timeout)
                finish(seekable)
            }
        }
    }

    private fun roots(): LocalMusicRoots = LocalMusicRoots.read(preferences.all)

    private fun tagSeparators(): String = preferences.getString("tagSeparators", "").orEmpty()

    private fun saveRoots(configuration: LocalMusicRoots) {
        val edit = preferences.edit().putString(LocalMusicRoots.KEY, configuration.toJson())
        listOf("uri", "name", "selectionId", "ownsRead", "needsReapproval").forEach { edit.remove(it) }
        check(edit.commit())
        main.post { if (channel != null) refreshScanWatcher() }
    }

    private fun resolveOpenedAudio(call: MethodCall): Map<String, String?>? {
        val incoming = openedAudioContentUri(call.argument<String>("uri")) ?: return null
        val uri = Uri.parse(incoming.toString())
        if (!hasOpenedAudioReadGrant(context, uri)) return null
        val title = openedAudioTitle(context, uri) ?: return null
        val indexed = if (call.argument<Boolean>("allowIndexed") == false) null else runCatching {
            indexedOpenedAudio(uri, call.argument("treeUri"), call.argument("selectionId"))
        }.getOrNull()
        if (!hasOpenedAudioReadGrant(context, uri)) return null
        return mapOf("uri" to uri.toString(), "title" to title, "indexedUri" to indexed)
    }

    private fun indexedOpenedAudio(uri: Uri, requestedTree: String?, requestedSelection: String?): String? {
        val availableRoots = roots().entries.filter { root ->
            !root.needsReapproval && !root.isDocumentProvider &&
                (requestedTree == null || (root.uri == requestedTree && root.selectionId == requestedSelection))
        }
        return availableRoots.mapNotNull { root ->
            fun authorized() = roots().find(root.uri) == root && checkFolderAccess(root.uri) == true

            if (!authorized()) return@mapNotNull null
            val source = Uri.parse(root.uri)
            catalog(source, root.selectionId).indexedOpenedAudio(source, uri)?.takeIf { authorized() }
        }.distinct().singleOrNull()
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

    private fun reviewMovedFiles(call: MethodCall, result: MethodChannel.Result) = run(result) {
        val tree = call.argument<String>("treeUri") ?: return@run null
        if (roots().find(tree)?.isDocumentProvider != false) return@run null
        val completed = completedCatalogs[tree] ?: return@run null
        if (completed.selectionId != call.argument<String>("selectionId") ||
            !catalogCurrent(tree, completed)) return@run null
        fun authorized() = catalogCurrent(tree, completed) &&
            checkFolderAccess(tree, completed.signal) == true

        try {
            if (!authorized()) return@run null
            val source = Uri.parse(tree)
            val catalog = catalog(source, completed.selectionId)
            if (call.method == "listMovedFileRepairs") {
                catalog.movedFileRepairs(source).takeIf { catalogCurrent(tree, completed) }
            } else {
                val missingId = call.argument<String>("missingId") ?: return@run null
                val candidateId = call.argument<String>("candidateId") ?: return@run null
                catalog.confirmMovedFileRepair(source, missingId, candidateId, completed.signal, ::authorized)
            }
        } catch (_: OperationCanceledException) {
            null
        }
    }

    private fun readTrack(
        call: MethodCall, result: MethodChannel.Result,
        read: LocalMusicCatalog.(Uri, String, String) -> Map<String, Any?>?,
    ) {
        val arguments = call.arguments as? Map<*, *>
        val tree = arguments?.get("treeUri") as? String
        val selection = arguments?.get("selectionId")
        val trackUri = arguments?.get("trackUri") as? String
        val trackId = arguments?.get("trackId") as? String
        if (tree == null || trackUri == null || trackId == null ||
            (selection != null && selection !is String)) {
            result.success(null)
            return
        }
        val selectionId = selection as? String
        run(result) {
            fun sourceStillAuthorized(): Boolean =
                rootCurrent(tree, selectionId) && checkFolderAccess(tree) == true

            if (!sourceStillAuthorized()) return@run null
            val source = Uri.parse(tree)
            val value = catalog(source, selectionId).read(source, trackUri, trackId)
            value?.takeIf { sourceStillAuthorized() }
        }
    }

    private fun pickFolder(initial: String?, allowDocumentProviders: Boolean, result: MethodChannel.Result) {
        val host = activity?.activity
        if (host == null || promptPending()) {
            result.error("PICKER_UNAVAILABLE", "The music folder picker is unavailable.", null)
            return
        }
        val intent = Intent(Intent.ACTION_OPEN_DOCUMENT_TREE).apply {
            addFlags(Intent.FLAG_GRANT_READ_URI_PERMISSION or Intent.FLAG_GRANT_PERSISTABLE_URI_PERMISSION or
                Intent.FLAG_GRANT_PREFIX_URI_PERMISSION)
            if (!allowDocumentProviders) putExtra(Intent.EXTRA_LOCAL_ONLY, true)
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O && initial != null &&
                DocumentsContract.isTreeUri(Uri.parse(initial))) {
                putExtra(DocumentsContract.EXTRA_INITIAL_URI, Uri.parse(initial))
            }
        }
        picker = SourcePicker(result, allowDocumentProviders)
        try {
            host.startActivityForResult(intent, FOLDER_REQUEST)
        } catch (_: RuntimeException) {
            picker = null
            result.error("PICKER_UNAVAILABLE", "The music folder picker is unavailable.", null)
        }
    }

    override fun onActivityResult(requestCode: Int, resultCode: Int, data: Intent?): Boolean {
        if (requestCode == TAG_EDIT_REQUEST) {
            resumeTagEdit(resultCode == Activity.RESULT_OK, data)
            return true
        }
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
        cancelPendingShare()
        val code = if (operation.allowDocumentProviders) "PROVIDER_FOLDER_UNAVAILABLE" else "FOLDER_UNAVAILABLE"
        val message = if (operation.allowDocumentProviders) "The document provider folder could not be opened."
            else "The music folder could not be opened."
        runPicker(operation, code, message) {
            val tree = data?.data ?: throw IOException()
            require(tree.scheme == "content" && !tree.authority.isNullOrEmpty() &&
                tree.encodedQuery == null && tree.encodedFragment == null &&
                tree.pathSegments.size == 2 && DocumentsContract.isTreeUri(tree))
            require(data.flags and Intent.FLAG_GRANT_READ_URI_PERMISSION != 0)
            selectFolder(tree, operation.allowDocumentProviders, operation.cancellation)
        }
        return true
    }

    private fun selectFolder(tree: Uri, allowDocumentProviders: Boolean, signal: CancellationSignal): LocalMusicRoots {
        val current = roots()
        val previous = current.find(tree.toString())
        val alreadyReadable = grant(tree)?.isReadPermission == true
        val selectionId = selectionIdForPick(previous?.selectionId, sameFolder = previous != null,
            hasReadGrant = alreadyReadable, needsReapproval = previous?.needsReapproval == true)
        context.contentResolver.takePersistableUriPermission(tree, Intent.FLAG_GRANT_READ_URI_PERMISSION)
        try {
            val root = LocalMusicRoot(tree.toString(), folderName(tree, allowDocumentProviders, signal), selectionId,
                ownsRead = !alreadyReadable || previous?.ownsRead == true,
                isDocumentProvider = allowDocumentProviders)
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

    private fun promptPending() = picker != null || systemPicker != null || rename != null || tagEdit != null

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
        cancelPendingShare()
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
        if (requestCode == TAG_EDIT_PERMISSION_REQUEST) {
            resumeTagEdit(grantResults.firstOrNull() == PackageManager.PERMISSION_GRANTED)
            return true
        }
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
        if (root.isDocumentProvider) {
            result.error("RENAME_UNSUPPORTED", "The selected song could not be renamed.", null)
            return
        }
        val operation = RenameOperation(Uri.parse(root.uri), root.selectionId,
            Uri.parse(uri), name, call.argument<Boolean>("loadCovers") != false, result)
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
                val catalog = catalog(source, operation.selectionId, operation.loadCovers)
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

    private fun trackRingtone(call: MethodCall, result: MethodChannel.Result, probe: Boolean) {
        val action = (activity?.activity as? MainActivity)?.recordingRingtone
        val tree = call.argument<String>("treeUri")
        val selection = call.argument<String>("selectionId")
        val uri = call.argument<String>("uri")?.let(Uri::parse)
        val trackId = call.argument<String>("trackId")
        if (action == null || tree == null || uri == null || trackId == null ||
            uri.encodedQuery != null || uri.encodedFragment != null || promptPending() ||
            !RingtoneSource.isLocal(context, uri)) {
            result.success(if (probe) false else RecordingRingtone.UNAVAILABLE)
            return
        }

        val source = Uri.parse(tree)
        fun sourceAccessible(): Boolean {
            val root = roots().find(tree) ?: return false
            return root.selectionId == selection && !root.isDocumentProvider &&
                checkFolderAccess(tree) == true
        }

        fun trackName(): String? =
            if (sourceAccessible()) catalog(source, selection).shareableTrackName(source, uri, trackId)
            else null

        fun resolve(): RingtoneSource? {
            val name = trackName() ?: return null
            return RingtoneSource.open(context, uri, name)
        }

        if (probe) action.canSet(::resolve, result::success)
        else action.set(call.argument("title"), ::resolve, { trackName() != null }, result::success)
    }

    private fun tagTarget(call: MethodCall): TagTarget? {
        val tree = call.argument<String>("treeUri") ?: return null
        val uri = call.argument<String>("uri") ?: return null
        val selectionId = call.argument<String>("selectionId")
        val root = roots().find(tree) ?: return null
        if (root.needsReapproval || root.isDocumentProvider || root.selectionId != selectionId) return null
        return TagTarget(Uri.parse(root.uri), selectionId, Uri.parse(uri),
            loadCovers = call.argument<Boolean>("loadCovers") != false)
    }

    private fun currentTagCatalog(target: TagTarget): LocalMusicCatalog {
        val source = target.source.toString()
        val root = roots().find(source)
        if (root == null || root.isDocumentProvider || root.selectionId != target.selectionId) {
            throw LocalMusicTagEdit.Failure("TAGS_CHANGED")
        }
        if (checkFolderAccess(source) != true) throw LocalMusicTagEdit.Failure("TAGS_ACCESS")
        return catalog(target.source, target.selectionId, target.loadCovers)
    }

    private fun readTrackTags(call: MethodCall, result: MethodChannel.Result) {
        val target = tagTarget(call)
        if (target == null || promptPending()) {
            result.error("TAGS_CHANGED", "The selected song is unavailable.", null)
            return
        }
        worker.execute {
            try {
                val name = currentTagCatalog(target).tagEditName(target.source, target.uri)
                val tags = LocalMusicTagEdit(context).inspect(target.source, target.uri, name)
                main.post {
                    result.success(mapOf(
                        "revision" to tags.revision,
                        "values" to tags.tags.values,
                        "editableFields" to tags.tags.editableFields.toList(),
                        "id3Version" to tags.tags.version,
                        "artworkEditable" to tags.artwork.editable,
                        "hasArtwork" to tags.artwork.hasFrontCover,
                        "artworkRemovable" to tags.artwork.removable,
                    ))
                }
            } catch (failure: Exception) {
                main.post { result.error(tagFailureCode(failure), "The embedded tags could not be read.", null) }
            }
        }
    }

    private fun beginTagEdit(call: MethodCall, result: MethodChannel.Result) {
        val target = tagTarget(call)
        val revision = call.argument<String>("revision")
        val entries = call.argument<Any>("changes") as? Map<*, *>
        val rawLyrics = call.argument<Any>("lyrics")
        val lyrics = (rawLyrics as? Map<*, *>)?.let(::readLyricsEdit)
        val hasArtworkChange = call.hasArgument("artwork")
        val image = call.argument<Any>("artwork")
        if (target == null || promptPending()) {
            result.error("TAGS_CHANGED", "The selected song is unavailable.", null)
            return
        }
        if (image != null && (image !is ByteArray || image.size > LocalMusicId3.MAX_ARTWORK_SIZE)) {
            result.error("TAGS_ARTWORK_INVALID", "Choose a supported JPEG or PNG image.", null)
            return
        }
        if (revision == null || !TAG_REVISION.matches(revision) || entries == null ||
            (rawLyrics != null && lyrics == null) ||
            (entries.isEmpty() && !hasArtworkChange && lyrics == null) ||
            entries.any { (key, value) ->
                key !is String || key !in LocalMusicId3.supportedFields || (value != null && value !is String)
            }) {
            result.error("TAGS_UNSUPPORTED", "The requested embedded tags cannot be edited.", null)
            return
        }
        val changes = entries.entries.associate { (key, value) -> key as String to value as String? }
        val artwork = if (hasArtworkChange) LocalMusicId3.ArtworkEdit(image as ByteArray?) else null
        val operation = TagEditOperation(target, revision, changes, artwork, lyrics, result)
        tagEdit = operation
        runTagEdit(operation)
    }

    private fun readLyricsEdit(entries: Map<*, *>): LocalMusicUslt.Edit? {
        if (entries.size != 3) return null
        val language = entries["language"] as? String ?: return null
        val descriptor = entries["descriptor"] as? String ?: return null
        val text = entries["text"] as? String ?: return null
        return LocalMusicUslt.Edit(language, descriptor, text)
    }

    private fun runTagEdit(
        operation: TagEditOperation,
        consent: LocalMusicTagEdit.Step.Consent? = null,
        data: Intent? = null,
    ) {
        worker.execute {
            if (tagEdit !== operation) return@execute
            val target = operation.target
            try {
                val catalog = currentTagCatalog(target)
                val name = catalog.tagEditName(target.source, target.uri)
                val editor = LocalMusicTagEdit(context)
                if (tagEdit !== operation) return@execute
                when (val step = if (consent == null) {
                    editor.begin(
                        target.source, target.uri, name, operation.fileRevision, operation.changes,
                        artwork = operation.artwork, lyrics = operation.lyrics,
                    )
                } else editor.finish(consent, data)) {
                    is LocalMusicTagEdit.Step.Consent -> main.post { requestTagConsent(operation, step) }
                    is LocalMusicTagEdit.Step.Done -> {
                        val updated = if (step.changed) {
                            try {
                                catalog.editedTags(target.source, target.uri, operation.changes.keys, step, operation.artwork)
                            } catch (_: Exception) {
                                throw LocalMusicTagEdit.Failure("TAGS_SAVED_REFRESH_REQUIRED")
                            }
                        } else catalog.indexedTrack(target.source, target.uri)
                        main.post { completeTagEdit(operation, updated) }
                    }
                }
            } catch (failure: Exception) {
                main.post { completeTagEdit(operation, null, tagFailureCode(failure)) }
            }
        }
    }

    private fun requestTagConsent(operation: TagEditOperation, consent: LocalMusicTagEdit.Step.Consent) {
        if (tagEdit !== operation) return
        val host = activity?.activity
        if (host == null) {
            completeTagEdit(operation, null, "TAGS_ACCESS")
            return
        }
        operation.consent = consent
        try {
            when (val request = consent.request) {
                is LocalMusicRename.Request.SelectDocument ->
                    host.startActivityForResult(request.intent, TAG_EDIT_REQUEST)
                is LocalMusicRename.Request.Write ->
                    host.startIntentSenderForResult(request.sender, TAG_EDIT_REQUEST, null, 0, 0, 0)
                is LocalMusicRename.Request.LegacyWrite ->
                    host.requestPermissions(arrayOf(request.permission), TAG_EDIT_PERMISSION_REQUEST)
            }
        } catch (_: RuntimeException) {
            completeTagEdit(operation, null, "TAGS_ACCESS")
        } catch (_: android.content.IntentSender.SendIntentException) {
            completeTagEdit(operation, null, "TAGS_ACCESS")
        }
    }

    private fun resumeTagEdit(approved: Boolean, data: Intent? = null) {
        val operation = tagEdit ?: return
        val consent = operation.consent ?: return
        operation.consent = null
        if (approved) runTagEdit(operation, consent, data) else completeTagEdit(operation, null)
    }

    private fun completeTagEdit(operation: TagEditOperation, updated: Map<String, Any?>?, error: String? = null) {
        if (tagEdit !== operation) return
        tagEdit = null
        if (error == null) operation.result.success(updated)
        else operation.result.error(error, "The embedded tags could not be updated.", null)
    }

    private fun tagFailureCode(failure: Exception): String = when (failure) {
        is LocalMusicTagEdit.Failure -> failure.code
        is SecurityException -> "TAGS_ACCESS"
        else -> "TAGS_FAILED"
    }

    private data class PendingShare(
        val result: MethodChannel.Result,
        val requestId: Int?,
        val sourceTrees: Set<String>,
        val cancellation: CancellationSignal = CancellationSignal(),
    )

    private data class DeviceShare(
        val source: Uri, val selection: String?, val uri: Uri, val trackId: String?, val visibilityKey: String?,
    )

    private fun beginShare(result: MethodChannel.Result, tracks: List<Map<*, *>>, requestId: Int? = null) {
        val host = activity?.activity
        if (host == null || tracks.isEmpty() || pendingShare != null || promptPending()) {
            result.success(false)
            return
        }
        val devices = try {
            buildMap<Int, DeviceShare> {
                for ((index, track) in tracks.withIndex()) {
                    if (requestId != null && track["download"] is Map<*, *>) continue
                    val source = Uri.parse(requireNotNull(track["treeUri"] as? String))
                    val uri = Uri.parse(requireNotNull(track["uri"] as? String))
                    val trackId = track["trackId"] as? String
                    require(uri.scheme == ContentResolver.SCHEME_CONTENT && uri != source &&
                        uri.encodedQuery == null && uri.encodedFragment == null)
                    require(requestId == null || trackId != null)
                    put(index, DeviceShare(
                        source, track["selectionId"] as String?, uri, trackId, track["visibilityKey"] as String?,
                    ))
                }
            }
        } catch (_: IllegalArgumentException) {
            result.success(false)
            return
        } catch (_: ClassCastException) {
            result.success(false)
            return
        }
        val deviceSources = devices.values.groupBy { it.source to it.selection }
        fun sourcesCurrent(): Boolean {
            val approved = roots()
            return deviceSources.keys.all { (source, selection) ->
                approved.find(source.toString())?.let {
                    it.selectionId == selection && !it.needsReapproval
                } == true
            }
        }
        if (!sourcesCurrent()) {
            result.success(false)
            return
        }

        val share = PendingShare(result, requestId, deviceSources.keys.mapTo(mutableSetOf()) { it.first.toString() })
        pendingShare = share
        worker.execute {
            val attachments = try {
                check(sourcesCurrent())
                val deviceNames = buildMap<DeviceShare, String> {
                    for ((key, files) in deviceSources) {
                        share.cancellation.throwIfCanceled()
                        val (source, selection) = key
                        check(checkFolderAccess(source.toString(), share.cancellation) == true)
                        val names = catalog(source, selection)
                            .shareableTrackNames(source, files.map { Triple(it.uri, it.trackId, it.visibilityKey) })
                        putAll(files.zip(names))
                    }
                }
                tracks.mapIndexed { index, track ->
                    share.cancellation.throwIfCanceled()
                    val device = devices[index]
                    if (device == null) {
                        resolveMusicDownloadShare(context, track["download"] as Map<*, *>)
                    } else {
                        device.uri to requireNotNull(trackShareMime(device.uri, deviceNames.getValue(device)))
                    }
                }
            } catch (_: Exception) {
                // Provider failures may contain information about the selected files.
                null
            }
            main.post {
                if (pendingShare !== share) return@post
                pendingShare = null
                val launched = if (attachments == null || activity?.activity !== host ||
                    host.isFinishing || host.isDestroyed || promptPending() || !sourcesCurrent()) {
                    false
                } else try {
                    if (requestId == null) {
                        val (uri, mime) = attachments.single()
                        shareAudioFile(host, uri, mime)
                    } else {
                        shareAudioFiles(host, attachments)
                    }
                    true
                } catch (_: RuntimeException) {
                    false
                }
                result.success(launched)
            }
        }
    }

    private fun cancelPendingShare(tree: String? = null) {
        val share = pendingShare ?: return
        if (tree != null && tree !in share.sourceTrees) return
        pendingShare = null
        share.cancellation.cancel()
        share.result.success(false)
    }

    private fun trackShareMime(uri: Uri, name: String): String? {
        val resolver = context.contentResolver
        val mime = resolver.getType(uri).orEmpty().substringBefore(';').trim().lowercase(Locale.ROOT)
        if (!LocalMusicCatalog.isAudio(mime, name)) return null
        val descriptor = resolver.openAssetFileDescriptor(uri, "r") ?: return null
        descriptor.close()
        if (mime.startsWith("audio/")) return mime
        val extension = name.substringAfterLast('.', "").lowercase(Locale.ROOT)
        val inferred = MimeTypeMap.getSingleton().getMimeTypeFromExtension(extension)
        return inferred?.takeIf { it.startsWith("audio/") } ?: "audio/*"
    }

    private fun folderName(tree: Uri, isDocumentProvider: Boolean, signal: CancellationSignal): String {
        val root = DocumentsContract.buildDocumentUriUsingTree(tree, DocumentsContract.getTreeDocumentId(tree))
        return context.contentResolver.query(root, arrayOf(Document.COLUMN_DISPLAY_NAME, Document.COLUMN_MIME_TYPE),
            null, null, null, signal)?.use {
            if (isDocumentProvider && (it.extras.getBoolean(DocumentsContract.EXTRA_LOADING, false) ||
                it.extras.containsKey(DocumentsContract.EXTRA_ERROR))) return@use null
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
            val accessible = probeAccess(Uri.parse(root.uri), root.isDocumentProvider)
            main.post {
                if (channel == null) return@post
                val current = roots().find(root.uri)
                when {
                    current == null || current.selectionId != root.selectionId ||
                        current.isDocumentProvider != root.isDocumentProvider -> result.success(null)
                    current.needsReapproval -> result.success(false)
                    accessible == false -> {
                        cancelPendingShare(root.uri)
                        scans.remove(root.uri)?.signal?.cancel()
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
        return probeAccess(source, root.isDocumentProvider, signal).also {
            if (it == false) invalidateAccess(current, root, source)
        }
    }

    // A grant can outlive the selected directory. Only inspect its root, without
    // enumerating children, opening media or displaying another permission prompt.
    private fun probeAccess(tree: Uri, isDocumentProvider: Boolean, signal: CancellationSignal? = null): Boolean? =
        try {
            if (tree == systemSource) mayReadSystemAudio()
            else if (grant(tree)?.isReadPermission != true) false
            else {
                val root = DocumentsContract.buildDocumentUriUsingTree(tree, DocumentsContract.getTreeDocumentId(tree))
                val cursor = context.contentResolver.query(root, arrayOf(Document.COLUMN_MIME_TYPE), null, null, null, signal)
                if (cursor == null) {
                    // DocumentsProvider can translate a missing document to a null cursor.
                    // A supported path lookup can in turn report FileNotFoundException.
                    if (!isDocumentProvider && Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
                        DocumentsContract.findDocumentPath(context.contentResolver, root)
                    }
                    null
                } else cursor.use {
                    if (it.extras.getBoolean(DocumentsContract.EXTRA_LOADING, false) ||
                        it.extras.containsKey(DocumentsContract.EXTRA_ERROR)) null
                    else if (it.moveToFirst() && it.getString(0) == Document.MIME_TYPE_DIR) true
                    else if (isDocumentProvider) null else false
                }
            }
        } catch (_: FileNotFoundException) {
            if (isDocumentProvider && grant(tree)?.isReadPermission == true) null else false
        } catch (_: IOException) {
            null
        } catch (_: SecurityException) {
            // A provider can deny a query for reasons outside Android's URI grant,
            // for example when its account is disconnected. Preserve the root in that case.
            if (isDocumentProvider && context.checkUriPermission(
                    tree, Process.myPid(), Process.myUid(), Intent.FLAG_GRANT_READ_URI_PERMISSION,
                ) == PackageManager.PERMISSION_GRANTED) null else false
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

    private fun catalog(source: Uri, selectionId: String?, loadCovers: Boolean = true): LocalMusicCatalog {
        val key = cacheKey(source, selectionId)
        val visibilityAliases = File(context.noBackupFilesDir, "music-visibility-${cacheKey(source, null)}.json")
        return LocalMusicCatalog(context, coverDirectory(key), indexFile(key), visibilityAliases, loadCovers, tagSeparators())
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

    private fun run(
        result: MethodChannel.Result,
        errorCode: String = "FOLDER_UNAVAILABLE",
        errorMessage: String = "Choose the music folder again.",
        finished: () -> Unit = {},
        action: () -> Any?,
    ) {
        fun reply(send: () -> Unit) {
            main.post {
                if (channel != null) {
                    finished()
                    send()
                }
            }
        }
        worker.execute {
            try {
                val value = action()
                reply { result.success(value) }
            } catch (_: OperationCanceledException) {
                reply { result.error("SCAN_CANCELLED", "The music scan was cancelled.", null) }
            } catch (_: ProviderTemporarilyUnavailable) {
                reply { result.error("SCAN_UNAVAILABLE", "The music scan is temporarily unavailable.", null) }
            } catch (_: Exception) {
                // A provider error may contain a device path or account name.
                reply { result.error(errorCode, errorMessage, null) }
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
        cancelPendingShare()
    }
    override fun onDetachedFromActivity() {
        onDetachedFromActivityForConfigChanges()
        for (operation in listOfNotNull(picker, systemPicker)) {
            finishPicker(operation, null, "PICKER_UNAVAILABLE", "The music source chooser was interrupted.")
            operation.cancellation.cancel()
        }
        rename?.let { completeRename(it, null) }
        tagEdit?.takeIf { it.consent != null }?.let { completeTagEdit(it, null) }
    }
    override fun onDetachedFromEngine(binding: FlutterPlugin.FlutterPluginBinding) {
        onDetachedFromActivity()
        tagEdit = null
        scans.values.forEach { it.signal.cancel() }
        scans.clear()
        scanWatcher.close()
        accessWorker.shutdownNow()
        playbackProbe?.cancel()
        playbackProbe = null
        playbackProbeWorker.shutdownNow()
        worker.shutdownNow()
        channel?.setMethodCallHandler(null)
        channel = null
    }

    companion object {
        private const val FOLDER_REQUEST = 4403
        private const val AUDIO_PERMISSION_REQUEST = 4404
        private const val RENAME_REQUEST = 4405
        private const val RENAME_PERMISSION_REQUEST = 4406
        private const val SEEK_PROBE_TIMEOUT_MS = 3000L
        private const val TAG_EDIT_REQUEST = 4451
        private const val TAG_EDIT_PERMISSION_REQUEST = 4452
        private val TAG_REVISION = Regex("[a-f0-9]{64}")

        internal fun selectionIdForPick(previous: String?, sameFolder: Boolean,
            hasReadGrant: Boolean, needsReapproval: Boolean): String? =
            if (sameFolder && hasReadGrant && !needsReapproval) previous else UUID.randomUUID().toString()
    }
}
