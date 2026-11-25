package com.github.dvbeckwitt.videre.proxy

import android.content.Context
import android.net.Uri
import android.os.Build
import android.os.Environment
import android.provider.DocumentsContract
import android.provider.MediaStore
import java.io.FileNotFoundException
import java.io.IOException

/** Public Android music files that Videre created. SAF documents use their own grant checks. */
object SharedMusicDownload {
    const val COLLECTION = "content://media/external_primary/audio/media"
    const val DIRECTORY = "Music/Videre/"
    private val item = Regex("${Regex.escape(COLLECTION)}/[1-9][0-9]*")

    fun isItem(value: String): Boolean = item.matches(value)

    fun acceptsFile(name: String, mime: String): Boolean =
        name.isNotBlank() && !name.startsWith('.') && name.length <= 240 &&
            name.none { it < ' ' || it == '/' || it == '\\' } &&
            when (mime) {
                "audio/mpeg" -> name.endsWith(".mp3", ignoreCase = true)
                "audio/mp4" -> name.endsWith(".m4a", ignoreCase = true)
                "audio/ogg" -> name.endsWith(".ogg", ignoreCase = true)
                else -> false
            }

    private enum class Row { MISSING, MOVED, PENDING, PUBLISHED }

    @Suppress("DEPRECATION")
    private fun row(context: Context, uri: Uri): Row {
        require(Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q && isItem(uri.toString()))
        val columns = arrayOf(MediaStore.Audio.Media.OWNER_PACKAGE_NAME,
            MediaStore.Audio.Media.RELATIVE_PATH, MediaStore.Audio.Media.IS_PENDING)
        val cursor = context.contentResolver.query(MediaStore.setIncludePending(uri), columns, null, null, null)
            ?: throw IOException()
        return cursor.use {
            if (!it.moveToFirst()) {
                // Only confirm absence on mounted storage after the provider has finished loading.
                val volume = Environment.getExternalStorageState()
                if ((volume != Environment.MEDIA_MOUNTED && volume != Environment.MEDIA_MOUNTED_READ_ONLY) ||
                    it.extras.getBoolean(DocumentsContract.EXTRA_LOADING, false) ||
                    it.extras.containsKey(DocumentsContract.EXTRA_ERROR)) throw IOException()
                return@use Row.MISSING
            }
            if (it.getString(0) != context.packageName) throw SecurityException()
            if (it.isNull(1) || it.isNull(2)) throw IOException()
            if (it.getString(1) != DIRECTORY) return@use Row.MOVED
            if (it.getInt(2) != 0) Row.PENDING else Row.PUBLISHED
        }
    }

    /** Playback and writes may use only owned rows still in Videre's music directory. */
    fun pending(context: Context, uri: Uri): Boolean? = when (row(context, uri)) {
        Row.MISSING -> null
        Row.MOVED -> throw SecurityException()
        Row.PENDING -> true
        Row.PUBLISHED -> false
    }

    fun exportExists(context: Context, uri: Uri): Boolean = when (row(context, uri)) {
        Row.MISSING, Row.MOVED -> false
        Row.PENDING -> throw IOException()
        Row.PUBLISHED -> true
    }

    /** MediaStore's indexed size can lag behind the bytes already written to a pending item. */
    fun documentSize(context: Context, uri: Uri): Long? {
        when (row(context, uri)) {
            Row.MISSING -> return 0L
            Row.MOVED -> return null
            else -> Unit
        }
        val bytes = try {
            context.contentResolver.openFileDescriptor(uri, "r")?.use {
                it.statSize.takeIf { size -> size >= 0L }
            }
        } catch (_: FileNotFoundException) {
            null
        }
        // The user can move or remove a song while the descriptor is being opened.
        return when (row(context, uri)) {
            Row.MISSING -> 0L
            Row.MOVED -> null
            else -> bytes
        }
    }

    /** Moving a song releases it from Downloads. Keep the location check atomic with deletion. */
    fun deleteAtDestination(context: Context, uri: Uri) {
        when (row(context, uri)) {
            Row.MISSING, Row.MOVED -> return
            else -> {
                val selection = "${MediaStore.MediaColumns.OWNER_PACKAGE_NAME} = ? AND ${MediaStore.MediaColumns.RELATIVE_PATH} = ?"
                if (context.contentResolver.delete(uri, selection, arrayOf(context.packageName, DIRECTORY)) == 1) return
            }
        }
        // A file manager can move or delete the row between the metadata query and the delete.
        when (row(context, uri)) {
            Row.MISSING, Row.MOVED -> return
            else -> throw IOException()
        }
    }
}
