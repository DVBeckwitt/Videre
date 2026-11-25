package com.github.dvbeckwitt.videre

import android.content.ContentResolver
import android.content.ContentUris
import android.database.Cursor
import android.net.Uri
import android.os.Build
import android.os.CancellationSignal
import android.os.OperationCanceledException
import android.provider.MediaStore
import java.io.ByteArrayOutputStream
import java.io.IOException
import java.util.Locale

internal const val LOCAL_MUSIC_COVER_MAX_BYTES = 8 * 1024 * 1024
internal val localMusicAdjacentImageTypes = setOf("image/jpeg", "image/png", "image/webp")

internal data class LocalMusicCoverDocument(val uri: Uri, val size: Long?)

/** Opaque provider identifiers are kept separate from the conventional display names. */
internal class LocalMusicAdjacentCoverCandidates<T : Any> {
    private val candidates = sortedMapOf<Int, T?>()

    val isEmpty: Boolean get() = candidates.isEmpty()

    fun add(name: String, mime: String, document: () -> T) {
        val lowerName = name.lowercase(Locale.ROOT)
        val stem = stems.indexOf(lowerName.substringBeforeLast('.'))
        val extension = extensions.indexOf(lowerName.substringAfterLast('.', ""))
        if (stem < 0 || extension < 0) return
        val type = mime.substringBefore(';').trim().lowercase(Locale.ROOT)
        if (type !in localMusicAdjacentImageTypes && type !in genericImageTypes) return
        val rank = stem * extensions.size + extension
        val candidate = document()
        // Keep the priority deterministic even when a provider lists duplicate names.
        if (!candidates.containsKey(rank)) candidates[rank] = candidate
        else if (candidates[rank] != candidate) candidates[rank] = null
    }

    fun ranked(): Sequence<T> = candidates.values.asSequence().filterNotNull()

    private companion object {
        val stems = listOf("cover", "folder", "album", "front")
        val extensions = listOf("jpg", "jpeg", "png", "webp")
        val genericImageTypes = setOf("", "application/octet-stream", "image/jpg")
    }
}

/** Resolves one image per exact parent using only URIs that the provider listed. */
internal class LocalMusicAdjacentCovers(
    private val resolver: ContentResolver,
    private val signal: CancellationSignal,
) {
    private val folders = linkedMapOf<String, LocalMusicAdjacentCoverCandidates<LocalMusicCoverDocument>>()

    fun addFolder(parent: String, candidates: LocalMusicAdjacentCoverCandidates<LocalMusicCoverDocument>) {
        if (!candidates.isEmpty) folders[parent] = candidates
    }

    fun discoverMediaStore(tracks: Collection<LocalMusicRow>) {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.Q) return
        // Folder locations only exist for a valid volume and verified relative path.
        val parentsByVolume = tracks.asSequence().filter { it.folderLocations.isNotEmpty() }
            .mapNotNull { it.parentKey }.distinct().groupBy(
                keySelector = { it.substringBefore(':') },
                valueTransform = { it.substringAfter(':') },
            )
        for ((volume, parents) in parentsByVolume) {
            val collection = MediaStore.Images.Media.getContentUri(volume)
            for (paths in parents.chunked(64)) {
                signal.throwIfCanceled()
                discoverMediaStoreImages(volume, collection, paths)
            }
        }
    }

    private fun discoverMediaStoreImages(volume: String, collection: Uri, paths: List<String>) {
        val requested = paths.toSet()
        val relativePath = MediaStore.MediaColumns.RELATIVE_PATH
        val placeholders = paths.joinToString(", ") { "?" }
        try {
            resolver.query(collection, arrayOf(
                MediaStore.MediaColumns._ID, relativePath, MediaStore.MediaColumns.DISPLAY_NAME,
                MediaStore.MediaColumns.MIME_TYPE, MediaStore.MediaColumns.SIZE,
            ), "$relativePath IN ($placeholders)", paths.toTypedArray(), null, signal)?.use { cursor ->
                while (cursor.moveToNext()) {
                    signal.throwIfCanceled()
                    if (cursor.getType(0) != Cursor.FIELD_TYPE_INTEGER ||
                        cursor.getType(1) != Cursor.FIELD_TYPE_STRING) continue
                    val id = cursor.getLong(0)
                    val parent = cursor.getString(1)
                    if (id <= 0 || parent !in requested) continue
                    val name = cursor.getString(2) ?: continue
                    val key = "$volume:$parent"
                    val candidates = folders[key] ?: LocalMusicAdjacentCoverCandidates()
                    candidates.add(name, cursor.getString(3).orEmpty()) {
                        LocalMusicCoverDocument(
                            ContentUris.withAppendedId(collection, id),
                            if (cursor.getType(4) == Cursor.FIELD_TYPE_INTEGER) cursor.getLong(4) else null,
                        )
                    }
                    addFolder(key, candidates)
                }
            }
        } catch (cancelled: OperationCanceledException) {
            throw cancelled
        } catch (_: RuntimeException) {
            // The audio permission may expose no images on this Android version.
        }
    }

    fun cacheByParent(store: (ByteArray) -> String?): Map<String, String> = buildMap {
        for ((parent, candidates) in folders) {
            signal.throwIfCanceled()
            candidates.ranked().firstNotNullOfOrNull { cache(it, store) }?.let { put(parent, it) }
        }
    }

    private fun cache(document: LocalMusicCoverDocument, store: (ByteArray) -> String?): String? {
        if (document.size != null && document.size > LOCAL_MUSIC_COVER_MAX_BYTES) return null
        return try {
            val bytes = resolver.openAssetFileDescriptor(document.uri, "r", signal)?.use { asset ->
                asset.createInputStream().use { input ->
                    val output = ByteArrayOutputStream()
                    val buffer = ByteArray(8192)
                    while (true) {
                        signal.throwIfCanceled()
                        val read = input.read(buffer)
                        if (read < 0) break
                        if (read > LOCAL_MUSIC_COVER_MAX_BYTES - output.size()) return null
                        output.write(buffer, 0, read)
                    }
                    output.toByteArray()
                }
            } ?: return null
            signal.throwIfCanceled()
            store(bytes)
        } catch (cancelled: OperationCanceledException) {
            throw cancelled
        } catch (_: IOException) {
            null
        } catch (_: RuntimeException) {
            // Individual sibling files may disappear or be denied independently.
            null
        }
    }
}
