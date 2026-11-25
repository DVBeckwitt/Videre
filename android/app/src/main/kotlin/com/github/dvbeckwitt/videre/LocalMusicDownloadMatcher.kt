package com.github.dvbeckwitt.videre

import android.content.ContentUris
import android.content.Context
import android.net.Uri
import android.os.Build
import android.os.CancellationSignal
import android.os.OperationCanceledException
import android.provider.DocumentsContract
import android.provider.MediaStore
import com.github.dvbeckwitt.videre.proxy.DownloadDocumentIntegrity
import com.github.dvbeckwitt.videre.proxy.LocalStorageFileIdentity

internal data class LocalMusicDownloadCandidate(
    val key: String,
    val uri: Uri,
    val folder: String,
    val file: LocalStorageFileIdentity,
) {
    companion object {
        private val digest = Regex("[0-9a-f]{64}")

        fun parse(value: Any?): LocalMusicDownloadCandidate? {
            val row = value as? Map<*, *> ?: return null
            val key = row["key"] as? String ?: return null
            val raw = row["uri"] as? String ?: return null
            val folder = row["folderUri"] as? String ?: return null
            val identity = row["identity"] as? String ?: return null
            val bytes = when (val length = row["byteLength"]) {
                is Int -> length.toLong()
                is Long -> length
                else -> return null
            }
            if (key.length !in 1..128 || raw.length !in 1..32768 || folder.length !in 1..32768 ||
                !digest.matches(identity) || bytes <= 0L) return null
            val uri = Uri.parse(raw)
            val destination = Uri.parse(folder)
            if (!isPlainContent(uri) || !isPlainContent(destination)) return null
            return LocalMusicDownloadCandidate(key, uri, folder, LocalStorageFileIdentity(identity, bytes))
        }

        private fun isPlainContent(uri: Uri): Boolean =
            uri.scheme == "content" && !uri.authority.isNullOrEmpty() &&
                uri.encodedQuery == null && uri.encodedFragment == null
    }
}

/** Compares completed downloads only with the approved catalog's current rows. */
internal class LocalMusicDownloadMatcher(
    private val context: Context,
    private val source: Uri,
    tracks: Map<String, LocalMusicRow>,
    private val signal: CancellationSignal,
) {
    private val system = source.toString() == LocalMusicCatalog.SYSTEM_URI
    private val byUri = tracks.keys
    private val bySize = tracks.values.groupBy { it.sizeBytes }
    private val byDocument = if (system) emptyMap() else tracks.keys
        .mapNotNull { raw -> documentKey(Uri.parse(raw))?.let { it to raw } }
        .groupBy({ it.first }, { it.second })
    private val measured = mutableMapOf<String, LocalStorageFileIdentity?>()
    private var remainingFallback = 64

    fun match(download: LocalMusicDownloadCandidate): List<String> {
        signal.throwIfCanceled()
        val verified = optional {
            DownloadDocumentIntegrity.probeDocument(context, download.uri, download.folder, signal)
        }
        if (verified != download.file) return emptyList()

        // Exact URI equality already shares the same successfully opened handle.
        val raw = download.uri.toString()
        if (raw in byUri) return listOf(raw)
        val matches = linkedSetOf<String>()
        for (candidate in providerAliases(download.uri)) {
            if (candidate !in byUri) continue
            if (measure(candidate) == verified) matches.add(candidate)
        }
        if (matches.isNotEmpty()) return matches.toList()

        // Some providers expose distinct locators and no conversion API. A
        // short size bucket bounds descriptor lookups; equality still depends
        // exclusively on the regular-file stamp, not size alone.
        val sizes = bySize[verified.byteLength].orEmpty()
        if (sizes.size > 8) return emptyList()
        for (candidate in sizes) {
            if (!measured.containsKey(candidate.uri)) {
                if (remainingFallback <= 0) continue
                --remainingFallback
            }
            if (measure(candidate.uri) == verified) matches.add(candidate.uri)
        }
        return matches.toList()
    }

    private fun providerAliases(uri: Uri): List<String> {
        if (system) {
            val media = if (uri.authority == MediaStore.AUTHORITY) uri
                else if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q)
                    optional { MediaStore.getMediaUri(context, uri) } else null
            val canonical = media?.let(::canonicalMediaItem)
            return listOfNotNull(canonical)
        }
        val document = if (uri.authority != MediaStore.AUTHORITY) uri
            else if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O)
                optional { MediaStore.getDocumentUri(context, uri) } else null
        return document?.let(::documentKey)?.let { byDocument[it] }.orEmpty()
    }

    private fun canonicalMediaItem(uri: Uri): String? {
        val parts = uri.pathSegments
        val row = parts.lastOrNull()?.toLongOrNull()?.takeIf { it > 0L } ?: return null
        if (uri.authority != MediaStore.AUTHORITY || uri.encodedQuery != null ||
            uri.encodedFragment != null || (parts.size != 3 && parts.size != 4)) return null
        val indexedCollection = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q) {
            val volume = optional {
                val columns = arrayOf(MediaStore.Audio.Media._ID, MediaStore.MediaColumns.VOLUME_NAME)
                context.contentResolver.query(uri, columns, null, null, null, signal)?.use {
                    if (it.moveToFirst() && it.getLong(0) == row) it.getString(1) else null
                }
            } ?: return null
            if (volume == MediaStore.VOLUME_INTERNAL) return null
            MediaStore.Audio.Media.getContentUri(volume)
        } else source
        return ContentUris.withAppendedId(indexedCollection, row).toString()
    }

    private fun documentKey(uri: Uri): Pair<String, String>? = optional {
        val authority = uri.authority ?: return@optional null
        if (!DocumentsContract.isDocumentUri(context, uri)) return@optional null
        authority to DocumentsContract.getDocumentId(uri)
    }

    private fun measure(raw: String): LocalStorageFileIdentity? {
        if (!measured.containsKey(raw)) {
            measured[raw] = optional {
                DownloadDocumentIntegrity.probeIndexedDocument(context, Uri.parse(raw), signal)
            }
        }
        return measured[raw]
    }

    private inline fun <T> optional(action: () -> T?): T? = try {
        action()
    } catch (cancelled: OperationCanceledException) {
        throw cancelled
    } catch (_: Exception) {
        null
    }
}
