package com.github.dvbeckwitt.videre

import android.app.Activity
import android.content.ContentResolver
import android.content.Context
import android.content.Intent
import android.net.Uri
import android.os.Handler
import android.os.Looper
import android.provider.DocumentsContract
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
import java.io.File
import java.io.FileNotFoundException
import java.util.concurrent.Executors

/** Stores profile-specific video associations with Android's read grants. */
class LocalMusicVideoPairingPlugin : FlutterPlugin, ActivityAware,
    PluginRegistry.ActivityResultListener {
    private lateinit var context: Context
    private lateinit var archive: AtomicFile
    private var channel: MethodChannel? = null
    private var activity: ActivityPluginBinding? = null
    private var picker: Picker? = null
    private val main = Handler(Looper.getMainLooper())
    private val resolver get() = context.contentResolver

    private data class Key(val profileId: String, val recordingId: String)

    private data class Pairing(val uri: String, val name: String, val offsetMs: Long) {
        fun arguments() = mapOf("uri" to uri, "name" to name, "offsetMs" to offsetMs)
    }

    private class Archive(
        val pairings: MutableMap<Key, Pairing> = linkedMapOf(),
        val ownedGrants: MutableSet<String> = linkedSetOf(),
    )

    private class Picker(val key: Key, val result: MethodChannel.Result) {
        var cancelled = false

        fun cancel() {
            if (cancelled) return
            cancelled = true
            result.success(null)
        }
    }

    override fun onAttachedToEngine(binding: FlutterPlugin.FlutterPluginBinding) {
        context = binding.applicationContext
        archive = AtomicFile(File(context.noBackupFilesDir, "music-video-pairings.json"))
        channel = MethodChannel(binding.binaryMessenger, CHANNEL).also {
            it.setMethodCallHandler(::handle)
        }
    }

    private fun handle(call: MethodCall, result: MethodChannel.Result) {
        val method = call.method
        if (method !in methods) {
            result.notImplemented()
            return
        }
        val args = call.arguments as? Map<*, *>
        val profileId = (args?.get("profileId") as? String)?.takeIf(profilePattern::matches)
        if (profileId == null) {
            invalidArgument(result)
            return
        }
        if (method == "forgetProfile") {
            // Keep the request slot until the activity returns its cancelled result.
            picker?.takeIf { it.key.profileId == profileId }?.cancel()
            run(result) {
                val state = readArchive()
                if (state.pairings.keys.removeAll { it.profileId == profileId }) writeArchive(state)
                releaseUnusedGrants(state)
                null
            }
            return
        }
        val recordingId = (args?.get("recordingId") as? String)?.takeIf(recordingPattern::matches)
        if (recordingId == null) {
            invalidArgument(result)
            return
        }
        val key = Key(profileId, recordingId)
        if (method == "pick") {
            pick(key, result)
            return
        }
        val expectedUri = args?.get("expectedUri") as? String
        if (method != "get" && expectedUri.isNullOrEmpty()) {
            invalidArgument(result)
            return
        }
        val offset = when (val value = args?.get("offsetMs")) {
            is Int -> value.toLong()
            is Long -> value
            else -> null
        }
        if (method == "setOffset" && (offset == null || offset !in offsetRange)) {
            invalidArgument(result)
            return
        }
        run(result) {
            val state = readArchive()
            val pairing = state.pairings[key]
            if (method == "get") return@run pairing?.arguments()
            if (pairing == null || pairing.uri != expectedUri) return@run false
            when (method) {
                "setOffset" -> {
                    val newOffset = checkNotNull(offset)
                    if (pairing.offsetMs != newOffset) {
                        state.pairings[key] = pairing.copy(offsetMs = newOffset)
                        writeArchive(state)
                    }
                    true
                }
                "remove" -> {
                    state.pairings.remove(key)
                    writeArchive(state)
                    releaseUnusedGrants(state)
                    true
                }
                "open" -> isReadable(Uri.parse(pairing.uri))
                else -> error("Unknown pairing operation")
            }
        }
    }

    private fun pick(key: Key, result: MethodChannel.Result) {
        val host = activity?.activity
        if (host == null || picker != null) {
            result.error("PICKER_UNAVAILABLE", null, null)
            return
        }
        val intent = Intent(Intent.ACTION_OPEN_DOCUMENT).apply {
            type = "video/*"
            addCategory(Intent.CATEGORY_OPENABLE)
            putExtra(Intent.EXTRA_LOCAL_ONLY, true)
            addFlags(Intent.FLAG_GRANT_READ_URI_PERMISSION or Intent.FLAG_GRANT_PERSISTABLE_URI_PERMISSION)
        }
        picker = Picker(key, result)
        try {
            host.startActivityForResult(intent, PICK_REQUEST)
        } catch (_: RuntimeException) {
            picker = null
            result.error("PICKER_UNAVAILABLE", null, null)
        }
    }

    override fun onActivityResult(requestCode: Int, resultCode: Int, data: Intent?): Boolean {
        if (requestCode != PICK_REQUEST) return false
        val request = picker ?: return true
        picker = null
        if (request.cancelled) return true
        if (resultCode != Activity.RESULT_OK) {
            request.cancel()
            return true
        }
        run(request.result) {
            val selected = requireNotNull(data)
            val uri = requireNotNull(selected.data)
            require(selected.flags and Intent.FLAG_GRANT_READ_URI_PERMISSION != 0)
            require(uri.scheme == ContentResolver.SCHEME_CONTENT && DocumentsContract.isDocumentUri(context, uri))
            pair(request.key, uri).arguments()
        }
        return true
    }

    private fun pair(key: Key, uri: Uri): Pairing {
        val state = readArchive()
        require(resolver.getType(uri)?.startsWith("video/", ignoreCase = true) == true)
        val name = displayName(uri)
        val uriString = uri.toString()
        val existing = state.pairings[key]
        val alreadyGranted = hasReadGrant(uri)
        if (!alreadyGranted) resolver.takePersistableUriPermission(uri, Intent.FLAG_GRANT_READ_URI_PERMISSION)
        val saved = try {
            check(isReadable(uri))
            if (!alreadyGranted) state.ownedGrants.add(uriString)
            val offset = existing?.takeIf { it.uri == uriString }?.offsetMs ?: 0L
            val pairing = Pairing(uriString, name, offset)
            state.pairings[key] = pairing
            writeArchive(state)
            pairing
        } catch (failure: Exception) {
            if (!alreadyGranted) releaseReadGrant(uri)
            throw failure
        }
        releaseUnusedGrants(state)
        return saved
    }

    private fun displayName(uri: Uri): String = runCatching {
        resolver.query(uri, arrayOf(OpenableColumns.DISPLAY_NAME), null, null, null)?.use {
            val index = it.getColumnIndex(OpenableColumns.DISPLAY_NAME)
            if (index >= 0 && it.moveToFirst()) it.getString(index) else null
        }
    }.getOrNull()?.filterNot(Char::isISOControl)?.trim()?.take(255).orEmpty()

    private fun hasReadGrant(uri: Uri) =
        resolver.persistedUriPermissions.any { it.uri == uri && it.isReadPermission }

    private fun isReadable(uri: Uri): Boolean = runCatching {
        hasReadGrant(uri) && resolver.openFileDescriptor(uri, "r")?.use { true } == true
    }.getOrDefault(false)

    private fun releaseReadGrant(uri: Uri): Boolean = runCatching {
        if (hasReadGrant(uri)) resolver.releasePersistableUriPermission(uri, Intent.FLAG_GRANT_READ_URI_PERMISSION)
    }.isSuccess

    private fun releaseUnusedGrants(state: Archive) {
        val inUse = state.pairings.values.mapTo(hashSetOf()) { it.uri }
        if (state.ownedGrants.removeAll { it !in inUse && releaseReadGrant(Uri.parse(it)) }) {
            // The association write already succeeded. Keep any unreleased grant in the
            // archive for a later mutation to retry if persisting cleanup fails.
            runCatching { writeArchive(state) }
        }
    }

    private fun readArchive(): Archive {
        val data = try {
            JSONObject(archive.readFully().toString(Charsets.UTF_8))
        } catch (_: FileNotFoundException) {
            // With an existing file, I/O failure must leave the old archive intact.
            if (archive.baseFile.exists()) throw IllegalStateException("Pairing archive inaccessible")
            return Archive()
        }
        val state = Archive()
        val pairs = data.getJSONArray("pairings")
        for (index in 0 until pairs.length()) {
            val entry = pairs.getJSONObject(index)
            state.pairings[Key(entry.getString("profileId"), entry.getString("recordingId"))] =
                Pairing(entry.getString("uri"), entry.getString("name"), entry.getLong("offsetMs"))
        }
        val grants = data.getJSONArray("ownedGrants")
        for (index in 0 until grants.length()) state.ownedGrants.add(grants.getString(index))
        return state
    }

    private fun writeArchive(state: Archive) {
        val pairs = state.pairings.map { (key, pairing) ->
            JSONObject(pairing.arguments()).put("profileId", key.profileId).put("recordingId", key.recordingId)
        }
        val data = JSONObject().put("pairings", JSONArray(pairs)).put("ownedGrants", JSONArray(state.ownedGrants))
        val output = archive.startWrite()
        try {
            output.write(data.toString().toByteArray(Charsets.UTF_8))
            archive.finishWrite(output)
        } catch (failure: Exception) {
            archive.failWrite(output)
            throw failure
        }
    }

    private fun invalidArgument(result: MethodChannel.Result) = result.error("INVALID_ARGUMENT", null, null)

    private fun run(result: MethodChannel.Result, operation: () -> Any?) {
        worker.execute {
            try {
                val value = operation()
                main.post { result.success(value) }
            } catch (_: Exception) {
                main.post { result.error("VIDEO_PAIRING_FAILED", null, null) }
            }
        }
    }

    override fun onAttachedToActivity(binding: ActivityPluginBinding) {
        activity = binding
        binding.addActivityResultListener(this)
    }

    override fun onDetachedFromActivityForConfigChanges() {
        activity?.removeActivityResultListener(this)
        activity = null
    }

    override fun onReattachedToActivityForConfigChanges(binding: ActivityPluginBinding) =
        onAttachedToActivity(binding)

    override fun onDetachedFromActivity() {
        onDetachedFromActivityForConfigChanges()
        picker?.cancel()
        picker = null
    }

    override fun onDetachedFromEngine(binding: FlutterPlugin.FlutterPluginBinding) {
        onDetachedFromActivity()
        channel?.setMethodCallHandler(null)
        channel = null
    }

    private companion object {
        const val CHANNEL = "com.github.dvbeckwitt.videre/local_music_video"
        const val PICK_REQUEST = 4411
        val worker = Executors.newSingleThreadExecutor()
        val profilePattern = Regex("[a-zA-Z0-9_-]{1,128}")
        val recordingPattern = Regex("device:[a-f0-9]{64}")
        val offsetRange = -86_400_000L..86_400_000L
        val methods = setOf("get", "pick", "setOffset", "remove", "open", "forgetProfile")
    }
}
