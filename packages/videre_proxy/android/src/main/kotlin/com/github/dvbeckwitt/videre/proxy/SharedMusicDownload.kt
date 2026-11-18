package com.github.dvbeckwitt.videre.proxy

import android.content.Context
import android.net.Uri
import android.os.Build
import android.provider.MediaStore
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

    /** null means the row no longer exists; never accept another app's audio or another directory. */
    @Suppress("DEPRECATION")
    fun pending(context: Context, uri: Uri): Boolean? {
        require(Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q && isItem(uri.toString()))
        val columns = arrayOf(MediaStore.Audio.Media.OWNER_PACKAGE_NAME,
            MediaStore.Audio.Media.RELATIVE_PATH, MediaStore.Audio.Media.IS_PENDING)
        val cursor = context.contentResolver.query(MediaStore.setIncludePending(uri), columns, null, null, null)
            ?: throw IOException()
        return cursor.use {
            if (!it.moveToFirst()) return@use null
            if (it.getString(0) != context.packageName || it.getString(1) != DIRECTORY) throw SecurityException()
            it.getInt(2) != 0
        }
    }
}
