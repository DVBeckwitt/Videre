package com.github.dvbeckwitt.videre

import android.content.Context
import android.graphics.Bitmap
import android.graphics.BitmapFactory
import android.media.MediaMetadataRetriever
import android.net.Uri
import android.os.CancellationSignal
import android.provider.DocumentsContract
import android.provider.DocumentsContract.Document
import android.util.Base64
import java.io.ByteArrayOutputStream
import java.io.File
import java.io.FileNotFoundException
import java.io.IOException
import java.security.MessageDigest
import java.util.ArrayDeque
import java.util.Locale

internal class LocalMusicCatalog(private val context: Context, cache: File) {
    private val artwork = LocalMusicCovers(cache)

    fun tracks(tree: Uri, signal: CancellationSignal): List<Map<String, Any?>> {
        val root = DocumentsContract.getTreeDocumentId(tree)
        val directories = ArrayDeque<String>()
        val seen = hashSetOf(root)
        val tracks = mutableListOf<Map<String, Any?>>()
        directories.add(root)
        while (directories.isNotEmpty()) {
            signal.throwIfCanceled()
            val id = directories.removeFirst()
            val children = DocumentsContract.buildChildDocumentsUriUsingTree(tree, id)
            try {
                val cursor = context.contentResolver.query(children, arrayOf(Document.COLUMN_DOCUMENT_ID,
                    Document.COLUMN_DISPLAY_NAME, Document.COLUMN_MIME_TYPE), null, null, null, signal)
                    ?: throw IOException()
                cursor.use {
                    if (it.extras.getBoolean(DocumentsContract.EXTRA_LOADING, false) ||
                        it.extras.containsKey(DocumentsContract.EXTRA_ERROR)) throw IOException()
                    while (it.moveToNext()) {
                        signal.throwIfCanceled()
                        val child = it.getString(0) ?: continue
                        if (!seen.add(child)) continue
                        val name = it.getString(1) ?: continue
                        val mime = it.getString(2).orEmpty()
                        if (mime == Document.MIME_TYPE_DIR) {
                            directories.addLast(child)
                        } else if (isAudio(mime, name)) {
                            tracks.add(track(DocumentsContract.buildDocumentUriUsingTree(tree, child), name))
                        }
                    }
                }
            } catch (missing: FileNotFoundException) {
                // A subfolder can be moved while the directory tree is being walked.
                if (id == root) throw missing
            }
        }
        signal.throwIfCanceled()
        artwork.removeUnused()
        return tracks.sortedWith(compareBy(String.CASE_INSENSITIVE_ORDER) { it["title"] as String })
    }

    private fun track(uri: Uri, name: String): Map<String, Any?> {
        val values = mutableMapOf<String, Any?>("uri" to uri.toString(), "title" to fallbackTitle(name),
            "artist" to null, "album" to null, "durationMs" to 0L, "artPath" to null)
        val retriever = MediaMetadataRetriever()
        try {
            retriever.setDataSource(context, uri)
            fun tag(key: Int) = retriever.extractMetadata(key)?.trim()?.takeIf(String::isNotEmpty)?.take(1024)
            tag(MediaMetadataRetriever.METADATA_KEY_TITLE)?.let { values["title"] = it }
            values["artist"] = tag(MediaMetadataRetriever.METADATA_KEY_ARTIST)
            values["album"] = tag(MediaMetadataRetriever.METADATA_KEY_ALBUM)
            values["durationMs"] = tag(MediaMetadataRetriever.METADATA_KEY_DURATION)?.toLongOrNull()?.coerceAtLeast(0L) ?: 0L
            retriever.embeddedPicture?.let { values["artPath"] = artwork.store(it) }
        } catch (denied: SecurityException) {
            throw denied
        } catch (_: RuntimeException) {
            // Many playable files have incomplete tags or unsupported embedded pictures.
        } catch (_: IOException) {
            // A cover-cache failure must not prevent audio playback.
        } finally {
            try { retriever.release() } catch (_: IOException) { }
        }
        return values
    }

    companion object {
        private val audioExtensions = setOf("mp3", "m4a", "m4b", "aac", "flac", "ogg", "oga", "opus",
            "wav", "aif", "aiff", "amr", "wma", "mka", "mid", "midi", "caf", "alac")
        private val playlistExtensions = setOf("m3u", "m3u8", "mpd", "pls", "xspf", "asx", "ism", "sdp")
        internal fun isAudio(mime: String, name: String): Boolean {
            val type = mime.substringBefore(';').trim().lowercase(Locale.ROOT)
            val extension = name.substringAfterLast('.', "").lowercase(Locale.ROOT)
            if (extension in playlistExtensions || type.contains("mpegurl") || type == "audio/x-scpls") return false
            return type.startsWith("audio/") || ((type.isEmpty() || type == "application/octet-stream" ||
                type == "application/ogg") && extension in audioExtensions)
        }
        internal fun fallbackTitle(name: String): String =
            name.substringBeforeLast('.').takeIf { it.isNotBlank() } ?: name
    }
}

/** Repeated album covers share one thumbnail. The current library's cache is bounded even during a scan. */
private class LocalMusicCovers(private val folder: File) {
    private val unused = folder.listFiles().orEmpty().filter { it.isFile }.sortedBy { it.lastModified() }.toMutableSet()
    private var cacheBytes = unused.sumOf { it.length() }

    fun store(bytes: ByteArray): String? {
        if (bytes.isEmpty() || bytes.size > 8 * 1024 * 1024) return null
        val digest = MessageDigest.getInstance("SHA-256").digest(bytes)
        val file = File(folder, Base64.encodeToString(digest, Base64.NO_WRAP or Base64.NO_PADDING or Base64.URL_SAFE) + ".jpg")
        if (file.isFile) {
            unused.remove(file)
            return file.absolutePath
        }
        val options = BitmapFactory.Options().apply { inJustDecodeBounds = true }
        BitmapFactory.decodeByteArray(bytes, 0, bytes.size, options)
        if (options.outWidth <= 0 || options.outHeight <= 0) return null
        options.inJustDecodeBounds = false
        options.inSampleSize = 1
        while (maxOf(options.outWidth, options.outHeight) / options.inSampleSize > 512) options.inSampleSize *= 2
        val bitmap = BitmapFactory.decodeByteArray(bytes, 0, bytes.size, options) ?: return null
        val thumbnail = ByteArrayOutputStream()
        try {
            if (!bitmap.compress(Bitmap.CompressFormat.JPEG, 85, thumbnail)) return null
        } finally {
            bitmap.recycle()
        }
        val old = unused.iterator()
        while (cacheBytes + thumbnail.size() > 24 * 1024 * 1024 && old.hasNext()) {
            val stale = old.next()
            val size = stale.length()
            if (stale.delete()) cacheBytes -= size
            old.remove()
        }
        if (cacheBytes + thumbnail.size() > 24 * 1024 * 1024 || (!folder.isDirectory && !folder.mkdirs())) return null
        val temporary = File.createTempFile("cover-", ".tmp", folder)
        try {
            temporary.outputStream().use { thumbnail.writeTo(it) }
            if (!temporary.renameTo(file)) return null
            cacheBytes += thumbnail.size()
            return file.absolutePath
        } finally {
            temporary.delete()
        }
    }

    fun removeUnused() = unused.forEach { it.delete() }
}
