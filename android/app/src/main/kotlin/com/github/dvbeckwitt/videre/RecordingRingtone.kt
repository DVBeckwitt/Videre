package com.github.dvbeckwitt.videre

import android.app.Activity
import android.app.AlertDialog
import android.app.UiModeManager
import android.content.ContentResolver
import android.content.ContentValues
import android.content.Context
import android.content.Intent
import android.content.pm.PackageManager
import android.content.res.Configuration
import android.media.MediaExtractor
import android.media.MediaFormat
import android.media.RingtoneManager
import android.net.Uri
import android.os.Build
import android.os.Environment
import android.os.Handler
import android.os.Looper
import android.provider.MediaStore
import android.provider.Settings
import java.io.IOException
import java.util.Locale
import java.util.concurrent.ArrayBlockingQueue
import java.util.concurrent.RejectedExecutionException
import java.util.concurrent.ThreadPoolExecutor
import java.util.concurrent.TimeUnit

internal data class RingtoneSource(val uri: Uri, val fileName: String, val importMime: String?) {
    companion object {
        private val importTypes = mapOf(
            "aac" to "audio/aac", "amr" to "audio/amr", "flac" to "audio/flac",
            "m4a" to "audio/mp4", "mp3" to "audio/mpeg", "oga" to "audio/ogg",
            "ogg" to "audio/ogg", "opus" to "audio/ogg", "wav" to "audio/wav",
        )

        fun isLocal(context: Context, uri: Uri): Boolean {
            if (uri.isMediaStoreAudio()) return true
            if (Build.VERSION.SDK_INT < Build.VERSION_CODES.Q || uri.scheme != ContentResolver.SCHEME_CONTENT) {
                return false
            }
            val authority = uri.authority
            return authority == MediaStore.AUTHORITY ||
                authority == context.packageName + ".music_download_share" ||
                TakeoutFiles.isLocalDocument(uri.scheme, authority)
        }

        fun open(context: Context, uri: Uri, fileName: String): RingtoneSource? {
            if (!isLocal(context, uri)) return null
            val reuse = uri.isMediaStoreAudio() && (Build.VERSION.SDK_INT < Build.VERSION_CODES.Q ||
                isIndexedRingtone(context, uri))
            val importMime = if (reuse) {
                val type = context.contentResolver.getType(uri)
                if (type?.startsWith("audio/") != true && type != "application/ogg") return null
                null
            } else {
                // Use containers Android can consistently index as audio under Ringtones.
                val extension = fileName.substringAfterLast('.', "").lowercase(Locale.ROOT)
                importTypes[extension] ?: return null
            }
            val extractor = MediaExtractor()
            try {
                extractor.setDataSource(context, uri, null)
                val types = (0 until extractor.trackCount).map {
                    extractor.getTrackFormat(it).getString(MediaFormat.KEY_MIME)
                }
                if (types.none { it?.startsWith("audio/") == true } ||
                    types.any { it?.startsWith("video/") == true }) return null
                return RingtoneSource(uri, fileName, importMime)
            } finally {
                extractor.release()
            }
        }

        private fun isIndexedRingtone(context: Context, uri: Uri): Boolean =
            context.contentResolver.query(
                uri, arrayOf(MediaStore.Audio.AudioColumns.IS_RINGTONE), null, null, null,
            )?.use { it.moveToFirst() && it.getInt(0) != 0 } == true

        private fun Uri.isMediaStoreAudio(): Boolean {
            if (scheme != ContentResolver.SCHEME_CONTENT || authority != MediaStore.AUTHORITY) return false
            val segments = pathSegments
            return segments.size == 4 && segments[1] == "audio" && segments[2] == "media" &&
                (segments[3].toLongOrNull() ?: 0) > 0
        }
    }
}

/** One foreground request at a time across both single-file audio entry points. */
internal class RecordingRingtone(private val host: Activity) {
    private val context get() = host.applicationContext
    private val main = Handler(Looper.getMainLooper())
    private val worker = ThreadPoolExecutor(1, 1, 30, TimeUnit.SECONDS, ArrayBlockingQueue(8)).apply {
        allowCoreThreadTimeOut(true)
    }
    private var pending: Request? = null

    private class Request(
        val resolve: () -> RingtoneSource?,
        val stillCurrent: () -> Boolean,
        val reply: (String) -> Unit,
    ) {
        @Volatile var cancelled = false
        var waitingForSettings = false
        var source: RingtoneSource? = null
        var dialog: AlertDialog? = null
    }

    private fun available(): Boolean = !host.isDestroyed && !host.isFinishing &&
        host.getSystemService(UiModeManager::class.java)?.currentModeType != Configuration.UI_MODE_TYPE_TELEVISION &&
        !host.packageManager.hasSystemFeature(PackageManager.FEATURE_LEANBACK_ONLY)

    fun canSet(resolve: () -> RingtoneSource?, reply: (Boolean) -> Unit) {
        if (!available() || !runWorker({ resolve() != null }) { reply(available() && it == true) }) {
            reply(false)
        }
    }

    fun set(
        title: String?,
        resolve: () -> RingtoneSource?,
        stillCurrent: () -> Boolean,
        reply: (String) -> Unit,
    ) {
        if (!available() || pending != null) {
            reply(UNAVAILABLE)
            return
        }
        val request = Request(resolve, stillCurrent, reply)
        pending = request
        if (!runWorker(resolve) { source ->
                if (pending === request) {
                    when {
                        source == null -> finish(request, FAILED)
                        !available() -> finish(request, UNAVAILABLE)
                        else -> {
                            request.source = source
                            confirm(request, title?.trim()?.take(240)?.takeIf { it.isNotEmpty() } ?: source.fileName)
                        }
                    }
                }
            }) finish(request, UNAVAILABLE)
    }

    private fun confirm(request: Request, title: String) {
        try {
            val message = host.getString(
                if (Settings.System.canWrite(context)) R.string.ringtone_confirm_message
                else R.string.ringtone_confirm_settings_message, title,
            )
            request.dialog = AlertDialog.Builder(host)
                .setTitle(R.string.ringtone_confirm_title)
                .setMessage(message)
                .setNegativeButton(android.R.string.cancel) { _, _ -> finish(request, CANCELLED) }
                .setOnCancelListener { finish(request, CANCELLED) }
                .setPositiveButton(R.string.ringtone_confirm_button) { _, _ -> continueAfterConfirm(request) }
                .show()
        } catch (_: RuntimeException) {
            finish(request, UNAVAILABLE)
        }
    }

    private fun continueAfterConfirm(request: Request) {
        if (pending !== request) return
        request.dialog = null
        try {
            if (Settings.System.canWrite(context)) {
                apply(request)
            } else {
                request.waitingForSettings = true
                // This Settings action has no result payload. Read the permission on return.
                val ownPackage = Uri.fromParts("package", host.packageName, null)
                host.startActivityForResult(Intent(Settings.ACTION_MANAGE_WRITE_SETTINGS, ownPackage), SETTINGS_REQUEST)
            }
        } catch (_: RuntimeException) {
            finish(request, UNAVAILABLE)
        }
    }

    fun onActivityResult(requestCode: Int): Boolean {
        if (requestCode != SETTINGS_REQUEST) return false
        val request = pending?.takeIf { it.waitingForSettings } ?: return true
        request.waitingForSettings = false
        try {
            if (Settings.System.canWrite(context)) apply(request) else finish(request, CANCELLED)
        } catch (_: RuntimeException) {
            finish(request, UNAVAILABLE)
        }
        return true
    }

    private fun apply(request: Request) {
        if (!runWorker({ install(request) }) { finish(request, it ?: FAILED) }) {
            finish(request, UNAVAILABLE)
        }
    }

    private fun install(request: Request): String {
        if (request.cancelled || !Settings.System.canWrite(context)) return CANCELLED
        // The user may have left Videre to grant permission. Reopen and revalidate
        // the same recording before copying or changing the default sound.
        val source = request.resolve()?.takeIf { it == request.source } ?: return FAILED
        var imported: Uri? = null
        var safeToDelete = true
        try {
            val target = if (source.importMime != null && Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q) {
                importRecording(source, source.importMime).also { imported = it }
            } else source.uri
            if (!request.stillCurrent()) return FAILED
            if (request.cancelled || !Settings.System.canWrite(context)) return CANCELLED
            // Once the write begins, keep the copy if readback becomes unavailable.
            // It could already be the phone's ringtone.
            safeToDelete = false
            RingtoneManager.setActualDefaultRingtoneUri(context, RingtoneManager.TYPE_RINGTONE, target)
            if (RingtoneManager.getActualDefaultRingtoneUri(context, RingtoneManager.TYPE_RINGTONE) == target) {
                return SET
            }
            safeToDelete = true
            return FAILED
        } finally {
            if (safeToDelete) imported?.let(::deleteImport)
        }
    }

    @android.annotation.TargetApi(Build.VERSION_CODES.Q)
    private fun importRecording(source: RingtoneSource, mime: String): Uri {
        val resolver = context.contentResolver
        val extension = source.fileName.substringAfterLast('.').lowercase(Locale.ROOT)
        val name = source.fileName.substringBeforeLast('.').trim()
            .map { if (it.isISOControl() || it in "<>:\"/\\|?*") '_' else it }
            .joinToString("").trim('.', ' ').take(55).ifEmpty { "Videre" }
        val metadata = ContentValues().apply {
            put(MediaStore.MediaColumns.DISPLAY_NAME, "$name.$extension")
            put(MediaStore.MediaColumns.MIME_TYPE, mime)
            put(MediaStore.MediaColumns.RELATIVE_PATH, Environment.DIRECTORY_RINGTONES + "/")
            put(MediaStore.MediaColumns.IS_PENDING, 1)
        }
        val collection = MediaStore.Audio.Media.getContentUri(MediaStore.VOLUME_EXTERNAL_PRIMARY)
        val target = resolver.insert(collection, metadata) ?: throw IOException()
        try {
            val input = resolver.openInputStream(source.uri) ?: throw IOException()
            input.use {
                val output = resolver.openOutputStream(target, "w") ?: throw IOException()
                output.use { stream -> if (input.copyTo(stream) == 0L) throw IOException() }
            }
            val publish = ContentValues().apply { put(MediaStore.MediaColumns.IS_PENDING, 0) }
            if (resolver.update(target, publish, null, null) != 1) throw IOException()
            return target
        } catch (error: Exception) {
            deleteImport(target)
            throw error
        }
    }

    private fun deleteImport(uri: Uri) {
        try {
            context.contentResolver.delete(uri, null, null)
        } catch (_: Exception) {
            // Media storage may have become unavailable.
        }
    }

    private fun <T> runWorker(action: () -> T, completion: (T?) -> Unit): Boolean {
        try {
            worker.execute {
                val value = try {
                    action()
                } catch (_: Exception) {
                    // Provider failures may contain information about the recording.
                    null
                }
                main.post { completion(value) }
            }
            return true
        } catch (_: RejectedExecutionException) {
            return false
        }
    }

    private fun finish(request: Request, outcome: String) {
        if (pending !== request) return
        pending = null
        request.cancelled = outcome == CANCELLED
        request.dialog?.dismiss()
        request.dialog = null
        request.reply(outcome)
    }

    fun close() {
        pending?.let { finish(it, CANCELLED) }
        worker.shutdown()
    }

    companion object {
        const val SET = "set"
        const val CANCELLED = "cancelled"
        const val UNAVAILABLE = "unavailable"
        const val FAILED = "failed"
        private const val SETTINGS_REQUEST = 4481
    }
}
