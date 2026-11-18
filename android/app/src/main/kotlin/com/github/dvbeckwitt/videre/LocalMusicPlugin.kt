package com.github.dvbeckwitt.videre

import android.app.Activity
import android.content.Context
import android.content.Intent
import android.net.Uri
import android.os.Build
import android.os.CancellationSignal
import android.os.Handler
import android.os.Looper
import android.os.OperationCanceledException
import android.provider.DocumentsContract
import android.provider.DocumentsContract.Document
import io.flutter.embedding.engine.plugins.FlutterPlugin
import io.flutter.embedding.engine.plugins.activity.ActivityAware
import io.flutter.embedding.engine.plugins.activity.ActivityPluginBinding
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import io.flutter.plugin.common.PluginRegistry
import java.io.File
import java.io.IOException
import java.util.concurrent.Executors

class LocalMusicPlugin : FlutterPlugin, ActivityAware, PluginRegistry.ActivityResultListener {
    private lateinit var context: Context
    private var channel: MethodChannel? = null
    private var activity: ActivityPluginBinding? = null
    private var picker: MethodChannel.Result? = null
    private var scan: CancellationSignal? = null
    private val worker = Executors.newSingleThreadExecutor()
    private val main = Handler(Looper.getMainLooper())
    private val preferences get() = context.getSharedPreferences("videre_local_music", Context.MODE_PRIVATE)
    private val covers get() = File(context.cacheDir, "local_music_covers")

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
                result.success((saved["uri"] as? String)?.let { mapOf("uri" to it, "name" to saved["name"]) })
            }
            "pickFolder" -> pickFolder(call.argument("initialUri"), result)
            "listTracks" -> {
                val tree = call.argument<String>("treeUri")
                scan?.cancel()
                val signal = CancellationSignal()
                scan = signal
                run(result) {
                    require(tree != null && tree == preferences.getString("uri", null))
                    val uri = Uri.parse(tree)
                    check(grant(uri)?.isReadPermission == true)
                    folderName(uri, signal)
                    LocalMusicCatalog(context, covers).tracks(uri, signal)
                }
            }
            "forgetFolder" -> {
                val tree = call.argument<String>("treeUri")
                scan?.cancel()
                run(result) {
                    if (tree != null && tree == preferences.getString("uri", null)) {
                        val ownsRead = preferences.getBoolean("ownsRead", false)
                        check(preferences.edit().clear().commit())
                        releaseRead(Uri.parse(tree), ownsRead)
                        clearCovers()
                    }
                    null
                }
            }
            else -> result.notImplemented()
        }
    }

    private fun pickFolder(initial: String?, result: MethodChannel.Result) {
        val host = activity?.activity
        if (host == null || picker != null) {
            result.error("PICKER_UNAVAILABLE", "The music folder picker is unavailable.", null)
            return
        }
        val intent = Intent(Intent.ACTION_OPEN_DOCUMENT_TREE).apply {
            addFlags(Intent.FLAG_GRANT_READ_URI_PERMISSION or Intent.FLAG_GRANT_PERSISTABLE_URI_PERMISSION or
                Intent.FLAG_GRANT_PREFIX_URI_PERMISSION)
            putExtra(Intent.EXTRA_LOCAL_ONLY, true)
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O && initial != null) {
                putExtra(DocumentsContract.EXTRA_INITIAL_URI, Uri.parse(initial))
            }
        }
        picker = result
        try {
            host.startActivityForResult(intent, REQUEST_CODE)
        } catch (_: RuntimeException) {
            picker = null
            result.error("PICKER_UNAVAILABLE", "The music folder picker is unavailable.", null)
        }
    }

    override fun onActivityResult(requestCode: Int, resultCode: Int, data: Intent?): Boolean {
        if (requestCode != REQUEST_CODE) return false
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

    private fun selectFolder(tree: Uri): Map<String, String> {
        val old = preferences.getString("uri", null)
        val oldOwned = preferences.getBoolean("ownsRead", false)
        val alreadyReadable = grant(tree)?.isReadPermission == true
        context.contentResolver.takePersistableUriPermission(tree, Intent.FLAG_GRANT_READ_URI_PERMISSION)
        val name = try {
            val display = folderName(tree, null)
            check(preferences.edit().putString("uri", tree.toString()).putString("name", display)
                .putBoolean("ownsRead", !alreadyReadable || (old == tree.toString() && oldOwned)).commit())
            display
        } catch (failure: Exception) {
            releaseRead(tree, !alreadyReadable)
            throw failure
        }
        if (old != null && old != tree.toString()) {
            releaseRead(Uri.parse(old), oldOwned)
            clearCovers()
        }
        return mapOf("uri" to tree.toString(), "name" to name)
    }

    private fun folderName(tree: Uri, signal: CancellationSignal?): String {
        val root = DocumentsContract.buildDocumentUriUsingTree(tree, DocumentsContract.getTreeDocumentId(tree))
        return context.contentResolver.query(root, arrayOf(Document.COLUMN_DISPLAY_NAME, Document.COLUMN_MIME_TYPE),
            null, null, null, signal)?.use {
            if (it.moveToFirst() && it.getString(1) == Document.MIME_TYPE_DIR) it.getString(0) else null
        } ?: throw IOException()
    }

    private fun grant(tree: Uri) = context.contentResolver.persistedUriPermissions.firstOrNull { it.uri == tree }

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

    private fun clearCovers() {
        covers.listFiles()?.forEach { it.delete() }
    }

    private fun run(result: MethodChannel.Result, action: () -> Any?) {
        worker.execute {
            try {
                val value = action()
                main.post { if (channel != null) result.success(value) }
            } catch (_: OperationCanceledException) {
                main.post { if (channel != null) result.error("SCAN_CANCELLED", "The music scan was cancelled.", null) }
            } catch (_: Exception) {
                // A provider error may contain a device path or account name.
                main.post { if (channel != null) result.error("FOLDER_UNAVAILABLE", "Choose the music folder again.", null) }
            }
        }
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
        picker?.error("PICKER_UNAVAILABLE", "The music folder picker was interrupted.", null)
        picker = null
    }
    override fun onDetachedFromEngine(binding: FlutterPlugin.FlutterPluginBinding) {
        onDetachedFromActivity()
        scan?.cancel()
        worker.shutdownNow()
        channel?.setMethodCallHandler(null)
        channel = null
    }

    companion object { private const val REQUEST_CODE = 4403 }
}
