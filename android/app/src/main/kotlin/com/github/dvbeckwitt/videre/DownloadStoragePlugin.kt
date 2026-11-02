package com.github.dvbeckwitt.videre

import android.app.Activity
import android.content.Context
import android.content.Intent
import android.net.Uri
import android.os.Build
import android.os.Handler
import android.os.Looper
import android.provider.DocumentsContract
import io.flutter.embedding.engine.plugins.FlutterPlugin
import io.flutter.embedding.engine.plugins.activity.ActivityAware
import io.flutter.embedding.engine.plugins.activity.ActivityPluginBinding
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import io.flutter.plugin.common.PluginRegistry
import java.io.File
import java.io.FileNotFoundException
import java.io.IOException
import java.util.concurrent.ConcurrentHashMap
import java.util.concurrent.Executors
import java.util.concurrent.atomic.AtomicBoolean

/** The engine owns storage work; opening the picker is the only Activity operation. */
class DownloadStoragePlugin : FlutterPlugin, ActivityAware, PluginRegistry.ActivityResultListener {
    private lateinit var context: Context
    private var channel: MethodChannel? = null
    private var activity: ActivityPluginBinding? = null
    private var pendingPicker: MethodChannel.Result? = null
    private val main = Handler(Looper.getMainLooper())
    private val worker = Executors.newSingleThreadExecutor()
    private val writes = ConcurrentHashMap<String, AtomicBoolean>()

    override fun onAttachedToEngine(binding: FlutterPlugin.FlutterPluginBinding) {
        context = binding.applicationContext
        channel = MethodChannel(binding.binaryMessenger, "videre/download_storage").also {
            it.setMethodCallHandler(::handle)
        }
    }

    private fun handle(call: MethodCall, result: MethodChannel.Result) {
        when (call.method) {
            "pickFolder" -> pickFolder(call.argument("initialUri"), result)
            "cancelWrite" -> {
                call.argument<String>("id")?.let { writes[it]?.set(true) }
                result.success(null)
            }
            "writeDocument" -> {
                val id = call.argument<String>("id")
                if (id == null || writes.containsKey(id)) {
                    result.error("DOWNLOAD_STORAGE", "Invalid storage operation.", null)
                    return
                }
                val cancelled = AtomicBoolean(false)
                writes[id] = cancelled
                run(result) {
                    try {
                        val uri = document(call.argument<String>("uri")!!)
                        if (!exists(uri)) throw IOException()
                        val source = File(call.argument<String>("source")!!).canonicalFile
                        val privateRoot = File(context.applicationInfo.dataDir).canonicalPath + File.separator
                        require(source.path.startsWith(privateRoot) && source.isFile)
                        if (cancelled.get()) throw IOException()
                        source.inputStream().use { input ->
                            (context.contentResolver.openOutputStream(uri, "wt") ?: throw IOException()).use { output ->
                                val buffer = ByteArray(64 * 1024)
                                while (true) {
                                    if (cancelled.get() || Thread.currentThread().isInterrupted) throw IOException()
                                    val count = input.read(buffer)
                                    if (count < 0) break
                                    output.write(buffer, 0, count)
                                }
                                output.flush()
                            }
                        }
                        if (cancelled.get()) throw IOException()
                        null
                    } finally {
                        writes.remove(id)
                    }
                }
            }
            "checkFolder" -> run(result) { folder(call.argument<String>("uri")!!); null }
            "prepareDocument" -> run(result) {
                val tree = Uri.parse(call.argument<String>("folder")!!)
                val parent = folder(tree.toString())
                val existing = call.argument<String>("existing")
                if (existing != null) {
                    val uri = document(existing)
                    require(uri.authority == tree.authority &&
                        DocumentsContract.getTreeDocumentId(uri) == DocumentsContract.getTreeDocumentId(tree))
                    if (exists(uri)) return@run uri.toString()
                }
                val name = call.argument<String>("name")!!
                val mime = call.argument<String>("mime")!!
                require(name.isNotBlank() && name.length <= 240 && !name.contains('/') && !name.contains('\\'))
                require(mime == "video/webm" || mime == "audio/webm")
                (DocumentsContract.createDocument(context.contentResolver, parent, mime, name)
                    ?: throw IOException()).toString()
            }
            "deleteDocument" -> run(result) {
                val uri = document(call.argument<String>("uri")!!)
                if (exists(uri) && !DocumentsContract.deleteDocument(context.contentResolver, uri)) throw IOException()
                null
            }
            else -> result.notImplemented()
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

    private fun requireGrant(uri: Uri) {
        require(uri.scheme == "content" && DocumentsContract.isTreeUri(uri))
        val tree = DocumentsContract.buildTreeDocumentUri(uri.authority, DocumentsContract.getTreeDocumentId(uri))
        if (context.contentResolver.persistedUriPermissions.none {
                it.uri == tree && it.isReadPermission && it.isWritePermission
            }) throw SecurityException()
    }

    private fun document(value: String): Uri {
        val uri = Uri.parse(value)
        requireGrant(uri)
        require(DocumentsContract.isDocumentUri(context, uri))
        return uri
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
            if (it.extras.getBoolean(DocumentsContract.EXTRA_LOADING, false)) throw IOException()
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
        channel?.setMethodCallHandler(null)
        channel = null
    }

    companion object { private const val REQUEST_CODE = 4402 }
}
