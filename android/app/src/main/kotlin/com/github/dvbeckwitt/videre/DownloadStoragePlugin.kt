package com.github.dvbeckwitt.videre

import android.app.Activity
import android.content.ContentValues
import android.content.Context
import android.content.Intent
import android.database.Cursor
import android.media.MediaScannerConnection
import android.net.Uri
import android.os.Build
import android.os.Environment
import android.os.Handler
import android.os.Looper
import android.os.storage.StorageManager
import android.provider.DocumentsContract
import android.provider.DocumentsContract.Document
import android.provider.MediaStore
import androidx.core.content.FileProvider
import io.flutter.embedding.engine.plugins.FlutterPlugin
import io.flutter.embedding.engine.plugins.activity.ActivityAware
import io.flutter.embedding.engine.plugins.activity.ActivityPluginBinding
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import io.flutter.plugin.common.PluginRegistry
import java.io.File
import java.io.FileNotFoundException
import java.io.IOException
import java.io.InputStream
import java.io.OutputStream
import java.util.concurrent.ArrayBlockingQueue
import java.util.concurrent.ConcurrentHashMap
import java.util.concurrent.Executors
import java.util.concurrent.RejectedExecutionException
import java.util.concurrent.ThreadPoolExecutor
import java.util.concurrent.TimeUnit
import java.util.concurrent.atomic.AtomicBoolean
import com.github.dvbeckwitt.videre.proxy.DownloadDocumentIntegrity
import com.github.dvbeckwitt.videre.proxy.SharedMusicDownload

/** The engine owns storage work; system pickers and sharing use the Activity. */
class DownloadStoragePlugin : FlutterPlugin, ActivityAware, PluginRegistry.ActivityResultListener {
    private lateinit var context: Context
    private var channel: MethodChannel? = null
    private var activity: ActivityPluginBinding? = null
    private var pendingPicker: MethodChannel.Result? = null
    private var pendingShare: MethodChannel.Result? = null
    private val main = Handler(Looper.getMainLooper())
    private val worker = Executors.newSingleThreadExecutor()
    private val sizeWorker = ThreadPoolExecutor(2, 2, 30L, TimeUnit.SECONDS, ArrayBlockingQueue(4)).apply {
        allowCoreThreadTimeOut(true)
    }
    // Accessed only on the engine's main thread, including completion and detach.
    private val pendingSizes = mutableSetOf<MethodChannel.Result>()
    private val writes = ConcurrentHashMap<String, AtomicBoolean>()

    override fun onAttachedToEngine(binding: FlutterPlugin.FlutterPluginBinding) {
        context = binding.applicationContext
        channel = MethodChannel(binding.binaryMessenger, "videre/download_storage").also {
            it.setMethodCallHandler(::handle)
        }
    }

    private fun handle(call: MethodCall, result: MethodChannel.Result) {
        when (call.method) {
            "sharedMusicFolder" -> result.success(
                if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q) SharedMusicDownload.COLLECTION else null)
            "pickFolder" -> pickFolder(call.argument("initialUri"), result)
            "cancelWrite" -> {
                call.argument<String>("id")?.let { writes[it]?.set(true) }
                result.success(null)
            }
            "writeDocument" -> transfer(call, result) { cancelled ->
                val uri = Uri.parse(call.argument<String>("uri")!!)
                val source = File(call.argument<String>("source")!!).canonicalFile
                val privateRoot = File(context.applicationInfo.dataDir).canonicalPath + File.separator
                require(source.path.startsWith(privateRoot) && source.isFile)
                val shared = SharedMusicDownload.isItem(uri.toString())
                if (shared) {
                    when (SharedMusicDownload.pending(context, uri)) {
                        null -> throw IOException()
                        false -> setPending(uri, true)
                        true -> Unit
                    }
                } else if (!exists(document(uri.toString()))) throw IOException()
                source.inputStream().use { input ->
                    (context.contentResolver.openOutputStream(uri, "wt") ?: throw IOException()).use { output ->
                        copy(input, output, cancelled)
                    }
                }
                if (cancelled.get()) throw IOException()
                if (shared) setPending(uri, false) else scanAudioDocument(uri)
            }
            "readDocument" -> transfer(call, result) { cancelled ->
                val uri = document(call.argument<String>("uri")!!, writable = false)
                val tree = Uri.parse(call.argument<String>("folderUri")!!)
                require(tree == DocumentsContract.buildTreeDocumentUri(uri.authority, DocumentsContract.getTreeDocumentId(uri)))
                val root = File(File(context.applicationInfo.dataDir).canonicalFile, "app_flutter/downloads")
                val destination = exportInputFile(root, File(call.argument<String>("destination")!!)) ?: throw IOException()
                val input = context.contentResolver.openInputStream(uri) ?: throw IOException()
                try {
                    input.use { source -> destination.outputStream().use { copy(source, it, cancelled) } }
                    if (cancelled.get()) throw IOException()
                } catch (error: Exception) {
                    destination.delete()
                    throw error
                }
            }
            "checkFolder" -> run(result) {
                val uri = call.argument<String>("uri")!!
                if (uri == SharedMusicDownload.COLLECTION) {
                    require(Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q &&
                        Environment.getExternalStorageState() == Environment.MEDIA_MOUNTED)
                } else folder(uri)
                null
            }
            "inspectDocument" -> run(result) {
                DownloadDocumentIntegrity.inspect(context, call.argument<String>("uri")!!,
                    call.argument<String>("folderUri")!!)
            }
            "probeMusicFiles" -> probeMusicFiles(call, result)
            "shareMusicFile" -> shareMusicFile(call, result)
            "canSetMusicRingtone" -> musicRingtone(call, result, probe = true)
            "setMusicRingtone" -> musicRingtone(call, result, probe = false)
            "documentSize" -> measureDocument(call, result)
            "exportExists" -> run(result) {
                val uri = Uri.parse(call.argument<String>("uri")!!)
                val folderValue = call.argument<String>("folderUri")!!
                if (folderValue == SharedMusicDownload.COLLECTION) {
                    SharedMusicDownload.exportExists(context, uri)
                } else {
                    document(uri.toString(), writable = false)
                    require(Uri.parse(folderValue) == DocumentsContract.buildTreeDocumentUri(uri.authority, DocumentsContract.getTreeDocumentId(uri)))
                    exists(uri)
                }
            }
            "prepareDocument" -> run(result) {
                val tree = Uri.parse(call.argument<String>("folder")!!)
                val existing = call.argument<String>("existing")
                val name = call.argument<String>("name")!!
                val mime = call.argument<String>("mime")!!
                if (tree.toString() == SharedMusicDownload.COLLECTION) {
                    return@run prepareSharedMusic(existing, name, mime).toString()
                }
                val parent = folder(tree.toString())
                if (existing != null) {
                    val uri = document(existing)
                    require(uri.authority == tree.authority &&
                        DocumentsContract.getTreeDocumentId(uri) == DocumentsContract.getTreeDocumentId(tree))
                    if (exists(uri)) return@run uri.toString()
                }
                require(name.isNotBlank() && name.length <= 240 && !name.contains('/') && !name.contains('\\'))
                require(mime in setOf("video/webm", "audio/webm", "video/mp4", "audio/mp4", "audio/ogg", "audio/mpeg"))
                (DocumentsContract.createDocument(context.contentResolver, parent, mime, name)
                    ?: throw IOException()).toString()
            }
            "deleteDocument" -> run(result) {
                val uri = Uri.parse(call.argument<String>("uri")!!)
                if (SharedMusicDownload.isItem(uri.toString())) {
                    SharedMusicDownload.deleteAtDestination(context, uri)
                } else if (exists(document(uri.toString())) &&
                    !DocumentsContract.deleteDocument(context.contentResolver, uri)) throw IOException()
                null
            }
            else -> result.notImplemented()
        }
    }

    private fun prepareSharedMusic(existing: String?, name: String, mime: String): Uri {
        val visibleName = name.trimStart('.')
        require(Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q && SharedMusicDownload.acceptsFile(visibleName, mime))
        if (existing != null) {
            val uri = Uri.parse(existing)
            if (SharedMusicDownload.pending(context, uri) != null) return uri
        }
        val values = ContentValues().apply {
            put(MediaStore.MediaColumns.DISPLAY_NAME, visibleName)
            put(MediaStore.MediaColumns.MIME_TYPE, mime)
            put(MediaStore.MediaColumns.RELATIVE_PATH, SharedMusicDownload.DIRECTORY)
            put(MediaStore.MediaColumns.IS_PENDING, 1)
        }
        return context.contentResolver.insert(Uri.parse(SharedMusicDownload.COLLECTION), values)
            ?: throw IOException()
    }

    private fun setPending(uri: Uri, pending: Boolean) {
        val values = ContentValues().apply { put(MediaStore.MediaColumns.IS_PENDING, if (pending) 1 else 0) }
        if (context.contentResolver.update(uri, values, null, null) != 1) throw IOException()
    }

    /** A SAF provider may be a cloud service. Only scan files on a known local shared volume. */
    @Suppress("DEPRECATION")
    private fun scanAudioDocument(uri: Uri) {
        if (uri.authority != "com.android.externalstorage.documents") return
        try {
            val mime = context.contentResolver.getType(uri) ?: return
            if (!mime.startsWith("audio/") && mime != "application/ogg") return
            val id = DocumentsContract.getDocumentId(uri)
            val volume = id.substringBefore(':')
            val manager = context.getSystemService(StorageManager::class.java)
            val root = when {
                volume.equals("primary", true) -> Environment.getExternalStorageDirectory()
                Build.VERSION.SDK_INT >= Build.VERSION_CODES.R ->
                    manager.storageVolumes.firstOrNull { volume.equals(it.uuid, true) }?.directory
                else -> {
                    // Before API 30 StorageVolume has no directory getter. Match its UUID to this
                    // app's known external files directory, then remove the app-specific suffix.
                    val files = context.getExternalFilesDirs(null).filterNotNull().firstOrNull {
                        volume.equals(manager.getStorageVolume(it)?.uuid, true)
                    }
                    val suffix = "/Android/data/${context.packageName}/files"
                    files?.path?.takeIf { it.endsWith(suffix) }?.let { File(it.removeSuffix(suffix)) }
                }
            } ?: return
            val path = sharedAudioFile(root, DocumentsContract.getTreeDocumentId(uri), id) ?: return
            MediaScannerConnection.scanFile(context, arrayOf(path.path), arrayOf(mime), null)
        } catch (_: Exception) {
            // The document is already saved. A provider may not expose a scannable filesystem path.
        }
    }

    private fun run(result: MethodChannel.Result, action: () -> Any?) {
        worker.execute {
            try {
                val value = action()
                main.post { result.success(value) }
            } catch (_: Exception) {
                // Provider errors can contain local paths or account identifiers.
                main.post { result.error("DOWNLOAD_STORAGE", "Could not access the download folder. Reconnect the storage or choose the folder again.", null) }
            }
        }
    }

    private fun measureDocument(call: MethodCall, result: MethodChannel.Result) = runMetadataProbe(result) {
        val value = call.argument<String>("uri")!!
        val destination = call.argument<String>("folderUri")!!
        if (destination == SharedMusicDownload.COLLECTION) {
            SharedMusicDownload.documentSize(context, Uri.parse(value))
        } else {
            safDocumentSize(document(value, writable = false), Uri.parse(destination))
        }
    }

    private fun probeMusicFiles(call: MethodCall, result: MethodChannel.Result) = runMetadataProbe(result) {
        val profile = call.argument<String>("profileId") ?: return@runMetadataProbe null
        val files = call.argument<List<*>>("files") ?: return@runMetadataProbe null
        val includeAudioFormat = call.argument<Boolean>("includeAudioFormat") == true
        if (!downloadProfileId.matches(profile) || files.size > 64 ||
            (includeAudioFormat && files.size != 1)) return@runMetadataProbe null
        buildMap {
            for (value in files) {
                val file = value as? Map<*, *> ?: continue
                val key = file["key"] as? String ?: continue
                val video = file["videoId"] as? String ?: continue
                val uri = file["uri"] as? String ?: continue
                val folder = file["folderUri"] as? String
                val expected = file["expectedSha256"] as? String
                if (key.length !in 1..128 || !downloadProfileId.matches(video) || uri.length !in 1..32768 ||
                    (file["folderUri"] != null && (folder == null || folder.length !in 1..32768))) continue
                if (file["expectedSha256"] != null &&
                    (files.size != 1 || expected == null || !downloadContentHash.matches(expected))) continue
                val resolved = Uri.parse(uri)
                val destination = folder?.let(Uri::parse)
                if (resolved.encodedQuery != null || resolved.encodedFragment != null ||
                    destination?.encodedQuery != null || destination?.encodedFragment != null) continue
                try {
                    if (includeAudioFormat) {
                        if (expected != null) continue
                        val identity = file["expectedIdentity"] as? String
                        if (file["expectedIdentity"] != null &&
                            (identity == null || !downloadContentHash.matches(identity))) continue
                        val length = when (val size = file["expectedByteLength"]) {
                            is Int -> size.toLong()
                            is Long -> size
                            null -> null
                            else -> continue
                        }
                        if (length != null && length <= 0L) continue
                        val (stamp, format) = DownloadDocumentIntegrity.readVerifiedFile(
                            context, uri, folder, profile, video, identity, length, MusicFileAudioFormat::read,
                        )
                        put(key, mapOf("identity" to stamp.identity, "byteLength" to stamp.byteLength,
                            "audioFormat" to format))
                    } else {
                        val stamp = DownloadDocumentIntegrity.probe(context, uri, folder, profile, video, expected)
                        put(key, mapOf("identity" to stamp.identity, "byteLength" to stamp.byteLength))
                    }
                } catch (_: Exception) {
                    // One missing, unmounted or moved file should not suppress others.
                }
            }
        }
    }

    private fun musicRingtone(call: MethodCall, result: MethodChannel.Result, probe: Boolean) {
        val action = (activity?.activity as? MainActivity)?.recordingRingtone
        val original = call.argument<String>("uri")?.let(Uri::parse)
        val extension = musicShareExtensions[call.argument<String>("mime")]
        val privateDownload = Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q &&
            original?.scheme == "file" && original.authority.isNullOrEmpty()
        if (action == null || original == null || extension == null || pendingPicker != null ||
            (!privateDownload && !RingtoneSource.isLocal(context, original))) {
            result.success(if (probe) false else RecordingRingtone.UNAVAILABLE)
            return
        }
        val title = call.argument<String>("title")?.trim()?.take(240)?.takeIf { it.isNotEmpty() }
        fun resolve(): RingtoneSource? {
            val attachment = resolveMusicShare(call).first
            val name = title ?: call.argument<String>("videoId") ?: return null
            return RingtoneSource.open(context, attachment, "$name.$extension")
        }

        if (probe) action.canSet(::resolve, result::success)
        else action.set(title, ::resolve, { resolveMusicShare(call).first.scheme == "content" }, result::success)
    }

    private fun shareMusicFile(call: MethodCall, result: MethodChannel.Result) {
        val host = activity?.activity
        if (host == null || pendingShare != null) {
            result.success(false)
            return
        }
        pendingShare = result
        try {
            sizeWorker.execute {
                val attachment = try {
                    resolveMusicDownloadShare(context, call.arguments as Map<*, *>)
                } catch (_: Exception) {
                    null
                }
                main.post {
                    if (pendingShare !== result) return@post
                    pendingShare = null
                    val launched = if (attachment == null || activity?.activity !== host || host.isFinishing) {
                        false
                    } else try {
                        shareAudioFile(host, attachment.first, attachment.second)
                        true
                    } catch (_: RuntimeException) {
                        false
                    }
                    result.success(launched)
                }
            }
        } catch (_: RejectedExecutionException) {
            pendingShare = null
            result.success(false)
        }
    }

    private fun runMetadataProbe(result: MethodChannel.Result, action: () -> Any?) {
        pendingSizes.add(result)
        try {
            sizeWorker.execute {
                val value = try {
                    action()
                } catch (_: Exception) {
                    null
                }
                main.post { if (pendingSizes.remove(result)) result.success(value) }
            }
        } catch (_: RejectedExecutionException) {
            pendingSizes.remove(result)
            result.success(null)
        }
    }

    private fun transfer(call: MethodCall, result: MethodChannel.Result, action: (AtomicBoolean) -> Unit) {
        val id = call.argument<String>("id")
        val cancelled = AtomicBoolean(false)
        if (id.isNullOrEmpty() || writes.putIfAbsent(id, cancelled) != null) {
            result.error("DOWNLOAD_STORAGE", "Invalid storage operation.", null)
            return
        }
        run(result) {
            try {
                if (cancelled.get()) throw IOException()
                action(cancelled)
                null
            } finally {
                writes.remove(id)
            }
        }
    }

    private fun copy(input: InputStream, output: OutputStream, cancelled: AtomicBoolean) {
        val buffer = ByteArray(64 * 1024)
        while (true) {
            if (cancelled.get() || Thread.currentThread().isInterrupted) throw IOException()
            val count = input.read(buffer)
            if (count < 0) break
            output.write(buffer, 0, count)
        }
        output.flush()
    }

    private fun requireGrant(uri: Uri, writable: Boolean = true) {
        require(uri.scheme == "content" && DocumentsContract.isTreeUri(uri))
        val tree = DocumentsContract.buildTreeDocumentUri(uri.authority, DocumentsContract.getTreeDocumentId(uri))
        if (context.contentResolver.persistedUriPermissions.none {
                it.uri == tree && it.isReadPermission && (!writable || it.isWritePermission)
            }) throw SecurityException()
    }

    private fun document(value: String, writable: Boolean = true): Uri {
        val uri = Uri.parse(value)
        requireGrant(uri, writable)
        require(DocumentsContract.isDocumentUri(context, uri))
        return uri
    }

    private fun Cursor.completeListing() =
        !extras.getBoolean(DocumentsContract.EXTRA_LOADING, false) && !extras.containsKey(DocumentsContract.EXTRA_ERROR)

    private fun Cursor.fileSize(): Long? {
        val mime = getColumnIndex(Document.COLUMN_MIME_TYPE)
        val size = getColumnIndex(Document.COLUMN_SIZE)
        if (mime < 0 || getString(mime).isNullOrEmpty() || getString(mime) == Document.MIME_TYPE_DIR ||
            size < 0 || getType(size) != Cursor.FIELD_TYPE_INTEGER) return null
        return getLong(size).takeIf { it >= 0L }
    }

    /** Videre creates its documents directly in the selected tree. A grant alone also covers descendants. */
    private fun safDocumentSize(uri: Uri, tree: Uri): Long? {
        val treeId = DocumentsContract.getTreeDocumentId(uri)
        require(tree == DocumentsContract.buildTreeDocumentUri(uri.authority, treeId))
        val documentId = DocumentsContract.getDocumentId(uri)
        if (treeId == documentId) return null
        val resolver = context.contentResolver
        val columns = arrayOf(Document.COLUMN_DOCUMENT_ID, Document.COLUMN_MIME_TYPE, Document.COLUMN_SIZE)

        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
            val path = try {
                DocumentsContract.findDocumentPath(resolver, uri)?.path
            } catch (_: UnsupportedOperationException) {
                null
            } catch (_: FileNotFoundException) {
                null
            }
            if (!path.isNullOrEmpty()) {
                if (path.size < 2 || path.last() != documentId || path[path.lastIndex - 1] != treeId) return null
                return resolver.query(uri, columns, null, null, null)?.use {
                    if (it.completeListing() && it.moveToFirst() &&
                        it.getString(it.getColumnIndexOrThrow(Document.COLUMN_DOCUMENT_ID)) == documentId) it.fileSize() else null
                }
            }
        }

        val children = DocumentsContract.buildChildDocumentsUriUsingTree(tree, treeId)
        resolver.query(children, columns, null, null, null)?.use {
            if (!it.completeListing()) return null
            val id = it.getColumnIndexOrThrow(Document.COLUMN_DOCUMENT_ID)
            while (it.moveToNext()) {
                if (it.isNull(id)) return null
                if (it.getString(id) == documentId) return it.fileSize()
            }
        } ?: return null
        // An unavailable folder can look empty. Confirm the directory itself is accessible.
        val root = DocumentsContract.buildDocumentUriUsingTree(tree, treeId)
        return resolver.query(root, arrayOf(Document.COLUMN_MIME_TYPE), null, null, null)?.use {
            if (it.completeListing() && it.moveToFirst() && it.getString(0) == Document.MIME_TYPE_DIR) 0L else null
        }
    }

    private fun folder(value: String): Uri {
        val tree = Uri.parse(value)
        requireGrant(tree)
        val uri = DocumentsContract.buildDocumentUriUsingTree(tree, DocumentsContract.getTreeDocumentId(tree))
        context.contentResolver.query(uri, arrayOf(
            DocumentsContract.Document.COLUMN_MIME_TYPE, DocumentsContract.Document.COLUMN_FLAGS
        ), null, null, null)?.use { cursor ->
            if (cursor.moveToFirst() && cursor.getString(0) == DocumentsContract.Document.MIME_TYPE_DIR &&
                cursor.getInt(1) and DocumentsContract.Document.FLAG_DIR_SUPPORTS_CREATE != 0) return uri
        }
        throw IOException()
    }

    private fun exists(uri: Uri): Boolean {
        try {
            context.contentResolver.query(uri, arrayOf(DocumentsContract.Document.COLUMN_MIME_TYPE),
                null, null, null)?.use {
                if (it.moveToFirst()) {
                    require(it.getString(0) != DocumentsContract.Document.MIME_TYPE_DIR)
                    return true
                }
            }
        } catch (_: FileNotFoundException) { }
        // Android can return null for both a missing file and a failed provider.
        // Only accept absence when the chosen folder is accessible and its
        // complete listing no longer contains the document we created there.
        folder(uri.toString())
        val children = DocumentsContract.buildChildDocumentsUriUsingTree(uri,
            DocumentsContract.getTreeDocumentId(uri))
        val id = DocumentsContract.getDocumentId(uri)
        context.contentResolver.query(children, arrayOf(DocumentsContract.Document.COLUMN_DOCUMENT_ID),
            null, null, null)?.use {
            if (it.extras.getBoolean(DocumentsContract.EXTRA_LOADING, false) ||
                it.extras.containsKey(DocumentsContract.EXTRA_ERROR)) throw IOException()
            while (it.moveToNext()) {
                if (it.isNull(0) || it.getString(0) == id) throw IOException()
            }
            return false
        }
        throw IOException()
    }

    private fun pickFolder(initialUri: String?, result: MethodChannel.Result) {
        val host = activity?.activity
        if (pendingPicker != null || host == null) {
            result.error("PICKER_UNAVAILABLE", "The folder picker is not available right now.", null)
            return
        }
        pendingPicker = result
        try {
            host.startActivityForResult(Intent(Intent.ACTION_OPEN_DOCUMENT_TREE).apply {
                addFlags(Intent.FLAG_GRANT_READ_URI_PERMISSION or Intent.FLAG_GRANT_WRITE_URI_PERMISSION or
                    Intent.FLAG_GRANT_PERSISTABLE_URI_PERMISSION or Intent.FLAG_GRANT_PREFIX_URI_PERMISSION)
                putExtra(Intent.EXTRA_LOCAL_ONLY, true)
                if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O && initialUri != null) {
                    putExtra(DocumentsContract.EXTRA_INITIAL_URI, Uri.parse(initialUri))
                }
            }, REQUEST_CODE)
        } catch (_: Exception) {
            pendingPicker = null
            result.error("PICKER_UNAVAILABLE", "No folder picker is available on this device.", null)
        }
    }

    override fun onActivityResult(requestCode: Int, resultCode: Int, data: Intent?): Boolean {
        if (requestCode != REQUEST_CODE) return false
        val result = pendingPicker ?: return true
        pendingPicker = null
        if (resultCode != Activity.RESULT_OK) {
            result.success(null)
            return true
        }
        run(result) {
            val tree = data?.data ?: throw IOException()
            val flags = data.flags and (Intent.FLAG_GRANT_READ_URI_PERMISSION or Intent.FLAG_GRANT_WRITE_URI_PERMISSION)
            context.contentResolver.takePersistableUriPermission(tree, flags)
            val root = folder(tree.toString())
            val name = context.contentResolver.query(root,
                arrayOf(DocumentsContract.Document.COLUMN_DISPLAY_NAME), null, null, null)?.use {
                if (it.moveToFirst()) it.getString(0) else null
            } ?: throw IOException()
            mapOf("uri" to tree.toString(), "name" to name)
        }
        return true
    }

    override fun onAttachedToActivity(binding: ActivityPluginBinding) {
        activity = binding
        binding.addActivityResultListener(this)
    }
    override fun onReattachedToActivityForConfigChanges(binding: ActivityPluginBinding) = onAttachedToActivity(binding)
    override fun onDetachedFromActivityForConfigChanges() {
        activity?.removeActivityResultListener(this)
        activity = null
        pendingShare?.success(false)
        pendingShare = null
    }
    override fun onDetachedFromActivity() {
        onDetachedFromActivityForConfigChanges()
        pendingPicker?.error("PICKER_UNAVAILABLE", "The folder picker was interrupted.", null)
        pendingPicker = null
    }
    override fun onDetachedFromEngine(binding: FlutterPlugin.FlutterPluginBinding) {
        onDetachedFromActivity()
        writes.values.forEach { it.set(true) }
        worker.shutdownNow()
        sizeWorker.shutdownNow()
        pendingSizes.forEach { it.success(null) }
        pendingSizes.clear()
        channel?.setMethodCallHandler(null)
        channel = null
    }

    companion object { private const val REQUEST_CODE = 4402 }
}

class MusicDownloadShareProvider : FileProvider()

private val downloadProfileId = Regex("[A-Za-z0-9_-]{1,128}")
private val downloadContentHash = Regex("[0-9a-f]{64}")
private val musicShareExtensions = mapOf(
    "audio/mpeg" to "mp3", "audio/mp4" to "m4a", "audio/ogg" to "ogg", "audio/webm" to "webm",
)

internal fun resolveMusicDownloadShare(context: Context, arguments: Map<*, *>): Pair<Uri, String> {
    val profile = requireNotNull(arguments["profileId"] as? String)
    val video = requireNotNull(arguments["videoId"] as? String)
    val value = requireNotNull(arguments["uri"] as? String)
    val folder = arguments["folderUri"] as String?
    val mime = requireNotNull(arguments["mime"] as? String)
    val identity = arguments["expectedIdentity"] as String?
    val sha256 = arguments["expectedSha256"] as String?
    val length = (arguments["byteLength"] as Number?)?.toLong()
    val extension = requireNotNull(musicShareExtensions[mime])
    require(downloadProfileId.matches(profile) && downloadProfileId.matches(video))
    require(value.length in 1..32768 && (folder == null || folder.length in 1..32768))
    require(identity == null || downloadContentHash.matches(identity))
    require(sha256 == null || downloadContentHash.matches(sha256))
    val uri = Uri.parse(value)
    val destination = folder?.let(Uri::parse)
    require(uri.encodedQuery == null && uri.encodedFragment == null &&
        destination?.encodedQuery == null && destination?.encodedFragment == null)

    val stamp = DownloadDocumentIntegrity.probe(context, value, folder, profile, video, sha256)
    require((identity == null || identity == stamp.identity) &&
        (length == null || length == stamp.byteLength))
    if (uri.scheme == "file") {
        val file = File(requireNotNull(uri.path)).canonicalFile
        require(file.name == "$video.$extension")
        val contentUri = FileProvider.getUriForFile(context, "${context.packageName}.music_download_share", file)
        return contentUri to mime
    }

    val providerType = context.contentResolver.getType(uri)
    val shareMime = when {
        providerType?.startsWith("audio/") == true -> providerType
        providerType.isNullOrEmpty() || providerType == "application/octet-stream" ||
            providerType == "application/${mime.substringAfter('/')}" ||
            (mime == "audio/webm" && providerType == "video/webm") -> mime
        else -> throw IOException()
    }
    return uri to shareMime
}

/** Resolve only immediate files of the granted tree from Android's ExternalStorageProvider. */
internal fun sharedAudioFile(volumeRoot: File, treeId: String, documentId: String): File? {
    val volume = treeId.substringBefore(':')
    if (volume.isEmpty() || ':' !in treeId || !documentId.startsWith("$volume:")) return null
    val directory = treeId.substringAfter(':')
    val relative = documentId.substringAfter(':')
    if (relative.substringBeforeLast('/', "") != directory ||
        relative.split('/').any { it.isEmpty() || it == "." || it == ".." || '\\' in it }) return null
    val root = volumeRoot.canonicalFile
    val file = File(root, relative)
    return file.takeIf { it.canonicalFile == it.absoluteFile }
}

/** A legacy export may write only its own temporary input beneath a Videre download directory. */
internal fun exportInputFile(downloads: File, destination: File): File? {
    val root = downloads.canonicalFile
    // Android may return the application directory using either /data/data or /data/user/0.
    val file = File(destination.parentFile?.canonicalFile ?: return null, destination.name)
    if (file != file.canonicalFile || !exportInputName.matches(file.name)) return null
    val parent = file.parentFile ?: return null
    if (parent != root && !(parent.parentFile == File(root, "profiles") && profileName.matches(parent.name))) return null
    return file
}

private val profileName = Regex("[A-Za-z0-9_-]{1,128}")
private val exportInputName = Regex("[A-Za-z0-9_-]{1,128}(?:\\.(?:webm|mp4|m4a|mp3|ogg))?\\.export-input\\.part")
