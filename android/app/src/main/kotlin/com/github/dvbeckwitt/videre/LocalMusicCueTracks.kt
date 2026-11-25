package com.github.dvbeckwitt.videre

import android.content.ContentResolver
import android.net.Uri
import android.os.CancellationSignal
import android.os.OperationCanceledException
import android.provider.DocumentsContract
import java.io.IOException

/** Resolves CUE references against the same provider traversal used for audio discovery. */
internal class LocalMusicCueTracks(
    private val resolver: ContentResolver,
    private val tree: Uri,
    private val signal: CancellationSignal,
) {
    private data class SheetDocument(val parent: String, val name: String, val id: String)

    private val directories = mutableMapOf<Pair<String, String>, MutableList<String>>()
    private val sheets = mutableListOf<SheetDocument>()

    fun addDirectory(parent: String, name: String, id: String) {
        directories.getOrPut(parent to name) { mutableListOf() }.add(id)
    }

    fun addSheet(parent: String, name: String, id: String) {
        sheets.add(SheetDocument(parent, name, id))
    }

    fun tracks(
        audio: Collection<LocalMusicRow>,
        channelValue: (LocalMusicRow) -> Map<String, Any?>,
    ): List<Map<String, Any?>> = buildList {
        if (sheets.isEmpty()) return@buildList
        val byLocation = audio.groupBy { it.parentDocumentId to it.fileName }
        val readable = mutableMapOf<String, Boolean>()
        for (document in sheets) {
            signal.throwIfCanceled()
            val sheetUri = DocumentsContract.buildDocumentUriUsingTree(tree, document.id)
            val sheet = optionalDocument {
                resolver.openAssetFileDescriptor(sheetUri, "r", signal)?.use { asset ->
                    asset.createInputStream().use { LocalMusicCueSheet.parse(it) }
                }
            } ?: continue
            val albumTitle = sheet.title ?: LocalMusicCatalog.fallbackTitle(document.name)
            val albumKey = localMusicVisibilityFingerprint("cue-album", sheetUri.toString())
            for (file in sheet.files) {
                signal.throwIfCanceled()
                val resolved = resolveCueAudio(document.parent, file.relativePath, directories, byLocation)
                    ?: continue
                val metadata = resolved.metadata ?: continue
                val durationMs = metadata.durationMs
                if (durationMs <= 0 || durationMs > Long.MAX_VALUE / 1000L) continue
                if (!readable.getOrPut(resolved.uri) { canRead(resolved.uri) }) continue
                val base = channelValue(resolved)
                for (track in file.tracks) {
                    val durationUs = cuePlaybackDurationUs(track, durationMs * 1000L) ?: continue
                    val identity = localMusicVisibilityFingerprint(
                        "cue-track", sheetUri.toString(), track.number.toString(),
                        resolved.identityKey ?: resolved.identityUri ?: resolved.uri,
                        resolved.visibilityKey.orEmpty(), track.startUs.toString(), track.endUs?.toString().orEmpty(),
                    )
                    add(base + mapOf(
                        "title" to (track.title ?: "$albumTitle (${track.number})"),
                        "artist" to (track.performer ?: sheet.performer ?: metadata.artist),
                        "album" to albumTitle,
                        "albumArtist" to (sheet.performer ?: metadata.albumArtist),
                        "albumKey" to albumKey,
                        "durationMs" to (durationUs / 1000L),
                        "canRename" to false,
                        "identityUri" to null,
                        "identityKey" to identity,
                        "visibilityKey" to resolved.visibilityKey?.let {
                            localMusicVisibilityFingerprint("cue-visibility", identity)
                        },
                        "cueStartUs" to track.startUs,
                        "cueEndUs" to track.endUs,
                    ))
                }
            }
        }
    }

    private fun canRead(rawUri: String): Boolean = optionalDocument {
        resolver.openAssetFileDescriptor(Uri.parse(rawUri), "r", signal)?.use { true }
    } ?: false

    private inline fun <T> optionalDocument(action: () -> T?): T? = try {
        signal.throwIfCanceled()
        action().also { signal.throwIfCanceled() }
    } catch (cancelled: OperationCanceledException) {
        throw cancelled
    } catch (_: IOException) {
        null
    } catch (_: SecurityException) {
        // Individual files may disappear or become unreadable during a scan.
        null
    } catch (_: IllegalArgumentException) {
        null
    }
}

internal fun <T> resolveCueAudio(
    sheetParent: String,
    relativePath: List<String>,
    directories: Map<Pair<String, String>, List<String>>,
    audio: Map<Pair<String?, String>, List<T>>,
): T? {
    val name = relativePath.lastOrNull() ?: return null
    var parent = sheetParent
    for (directory in relativePath.dropLast(1)) {
        parent = directories[parent to directory]?.singleOrNull() ?: return null
    }
    return audio[parent to name]?.singleOrNull()
}

internal fun cuePlaybackDurationUs(track: LocalMusicCueTrack, fileDurationUs: Long): Long? {
    val end = track.endUs ?: fileDurationUs
    if (track.startUs < 0 || track.startUs >= end || end > fileDurationUs) return null
    return end - track.startUs
}
