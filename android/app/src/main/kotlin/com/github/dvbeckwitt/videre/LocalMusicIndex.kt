package com.github.dvbeckwitt.videre

import android.util.AtomicFile
import org.json.JSONArray
import org.json.JSONException
import org.json.JSONObject
import java.io.File
import java.io.FileNotFoundException
import java.io.IOException
import java.math.BigInteger
import java.security.MessageDigest

internal data class LocalMusicRow(
    val uri: String,
    val fileName: String,
    val addedMs: Long,
    val modifiedMs: Long?,
    val sizeBytes: Long?,
    val firstSeen: Boolean,
    val canRename: Boolean,
    val parentDocumentId: String?,
    val parentKey: String?,
    val identityUri: String? = null,
    val identityKey: String? = null,
    val metadata: LocalMusicMetadata? = null,
    val mediaAlbumId: Long? = null,
    val visibilityProof: String? = null,
    val visibilityAlias: String? = null,
    val isRecording: Boolean = false,
    val folderLocations: List<LocalMusicFolderLocation> = emptyList(),
) {
    val visibilityKey get() = visibilityProof?.let { visibilityAlias ?: it }

    fun matchesRevision(previous: LocalMusicRow): Boolean =
        modifiedMs != null && sizeBytes != null &&
            modifiedMs == previous.modifiedMs && sizeBytes == previous.sizeBytes

    fun needsTagRead(previous: LocalMusicRow?): Boolean {
        val metadata = previous?.metadata ?: return true
        return !metadata.albumTagsRead || metadata.sortTags == null || !matchesRevision(previous) ||
            identityKey != previous.identityKey
    }

    fun inheritsIdentity(previous: LocalMusicRow) = copy(
        identityUri = (previous.identityUri ?: previous.uri).takeUnless { it == uri },
        identityKey = previous.identityKey,
    )

    fun inheritsVisibility(previous: LocalMusicRow, confirmedRename: Boolean = false) = copy(
        visibilityAlias = previous.visibilityKey?.takeIf {
            visibilityProof != null && it != visibilityProof &&
                (visibilityProof == previous.visibilityProof || confirmedRename)
        },
    )

    // MediaStore album IDs belong to a volume. SAF has no album entity: the
    // actual traversed parent plus both album tags identify a local grouping.
    fun albumKey(source: String): String? {
        val album = localAlbumTag(metadata?.album) ?: return null
        val parts = if (source == LocalMusicCatalog.SYSTEM_URI) {
            val id = mediaAlbumId?.takeIf { it > 0 } ?: return null
            listOf(source, uri.substringBeforeLast('/'), id.toString())
        } else {
            val parent = parentDocumentId?.takeIf { it.isNotBlank() } ?: return null
            val artist = localAlbumTag(metadata?.albumArtist) ?: return null
            listOf(source, parent, artist, album)
        }
        val input = parts.joinToString("") { "${it.length}:$it" }.toByteArray(Charsets.UTF_8)
        val digest = MessageDigest.getInstance("SHA-256").digest(input)
        return BigInteger(1, digest).toString(16).padStart(64, '0')
    }

    fun channelValue(artPath: String? = null, source: String? = null): Map<String, Any?> = mapOf(
        "uri" to uri,
        "fileName" to fileName,
        "title" to (metadata?.title ?: LocalMusicCatalog.fallbackTitle(fileName)),
        "artist" to metadata?.artist,
        "album" to metadata?.album,
        "albumArtist" to metadata?.albumArtist,
        "titleSort" to metadata?.sortTags?.title,
        "artistSort" to metadata?.sortTags?.artist,
        "albumSort" to metadata?.sortTags?.album,
        "albumArtistSort" to metadata?.sortTags?.albumArtist,
        "albumKey" to source?.let(::albumKey),
        "discNumber" to metadata?.discNumber,
        "trackNumber" to metadata?.trackNumber,
        "releaseDate" to metadata?.releaseDate,
        "originalReleaseDate" to metadata?.originalReleaseDate,
        "durationMs" to (metadata?.durationMs ?: 0L),
        "artPath" to artPath,
        "addedMs" to addedMs,
        "modifiedMs" to modifiedMs,
        "sizeBytes" to sizeBytes,
        "firstSeen" to firstSeen,
        "canRename" to canRename,
        "parentDocumentId" to parentDocumentId,
        "identityUri" to identityUri,
        "identityKey" to identityKey,
        "visibilityKey" to visibilityKey,
        "isRecording" to isRecording,
        "folderLocations" to folderLocations.map { it.channelValue },
    )

    fun toJson(): JSONObject = JSONObject(channelValue()).apply {
        remove("artPath")
        remove("title")
        remove("artist")
        remove("album")
        remove("albumArtist")
        remove("titleSort")
        remove("artistSort")
        remove("albumSort")
        remove("albumArtistSort")
        remove("albumKey")
        remove("discNumber")
        remove("trackNumber")
        remove("releaseDate")
        remove("originalReleaseDate")
        remove("durationMs")
        remove("visibilityKey")
        put("metadata", metadata?.toJson())
        put("parentKey", parentKey)
        put("mediaAlbumId", mediaAlbumId)
        put("visibilityProof", visibilityProof)
        put("visibilityAlias", visibilityAlias)
        put("folderLocations", JSONArray(folderLocations.map { JSONObject(it.channelValue) }))
    }

    companion object {
        fun fromJson(json: JSONObject): LocalMusicRow = LocalMusicRow(
            uri = json.getString("uri"),
            fileName = json.getString("fileName"),
            addedMs = json.getLong("addedMs"),
            modifiedMs = json.longOrNull("modifiedMs"),
            sizeBytes = json.longOrNull("sizeBytes"),
            firstSeen = json.getBoolean("firstSeen"),
            canRename = json.getBoolean("canRename"),
            parentDocumentId = json.stringOrNull("parentDocumentId"),
            parentKey = json.stringOrNull("parentKey"),
            identityUri = json.stringOrNull("identityUri"),
            identityKey = json.stringOrNull("identityKey"),
            metadata = json.optJSONObject("metadata")?.let(LocalMusicMetadata::fromJson),
            mediaAlbumId = json.longOrNull("mediaAlbumId"),
            visibilityProof = json.stringOrNull("visibilityProof"),
            visibilityAlias = json.stringOrNull("visibilityAlias"),
            isRecording = json.opt("isRecording") == true,
            folderLocations = LocalMusicFolderLocation.fromJson(json.optJSONArray("folderLocations")),
        )
    }
}

internal data class LocalMusicMetadata(
    val title: String?,
    val artist: String?,
    val album: String?,
    val durationMs: Long,
    val cover: String? = null,
    val albumArtist: String? = null,
    val discNumber: Int? = null,
    val trackNumber: Int? = null,
    val releaseDate: String? = null,
    val originalReleaseDate: String? = null,
    val albumTagsRead: Boolean = false,
    // Null denotes a legacy row or an interrupted read. An empty result is cached.
    val sortTags: LocalMusicSortTags? = null,
) {
    fun toJson(): JSONObject = JSONObject()
        .put("title", title).put("artist", artist).put("album", album)
        .put("durationMs", durationMs).put("cover", cover)
        .put("albumArtist", albumArtist ?: JSONObject.NULL)
        .put("discNumber", discNumber).put("trackNumber", trackNumber)
        .put("releaseDate", releaseDate).put("originalReleaseDate", originalReleaseDate)
        .put("albumTagsRead", albumTagsRead)
        .apply {
            sortTags?.let {
                put("sortTags", JSONObject().put("title", it.title).put("artist", it.artist)
                    .put("album", it.album).put("albumArtist", it.albumArtist))
            }
        }

    companion object {
        fun fromJson(json: JSONObject): LocalMusicMetadata = LocalMusicMetadata(
            json.stringOrNull("title"),
            json.stringOrNull("artist"),
            json.stringOrNull("album"),
            json.getLong("durationMs"),
            json.stringOrNull("cover"),
            json.stringOrNull("albumArtist"),
            localAlbumPosition(json.opt("discNumber")?.toString()),
            localAlbumPosition(json.opt("trackNumber")?.toString()),
            localReleaseDate(json.stringOrNull("releaseDate")),
            localReleaseDate(json.stringOrNull("originalReleaseDate")),
            // Refresh legacy tags once without losing dates, track IDs or the rename journal.
            json.opt("albumTagsRead") == true,
            json.optJSONObject("sortTags")?.let {
                LocalMusicSortTags(it.stringOrNull("title"), it.stringOrNull("artist"),
                    it.stringOrNull("album"), it.stringOrNull("albumArtist"))
            },
        )
    }
}

internal fun localAlbumTag(text: String?): String? = text?.trim()?.takeIf {
    it.isNotEmpty() && it.length <= 1024 && !it.equals("<unknown>", ignoreCase = true) &&
        it.none(Char::isISOControl)
}

internal data class PendingLocalMusicRename(
    val id: String,
    val previous: LocalMusicRow,
    val name: String,
    val equivalentDocument: String? = null,
) {
    fun targets(row: LocalMusicRow): Boolean =
        previous.parentKey != null && previous.parentKey == row.parentKey &&
            previous.fileName != name && row.fileName == name

    // A provider retaining the same item URI supplies a stronger identity than
    // a candidate reached through the journal's requested destination name.
    fun matches(row: LocalMusicRow): Boolean = targets(row) &&
        if (previous.uri == row.uri) {
            previous.sizeBytes == null || previous.sizeBytes == row.sizeBytes
        } else {
            row.matchesRevision(previous)
        }

    fun replacedAtOldPath(row: LocalMusicRow): Boolean =
        previous.uri == row.uri &&
            (differentKnownValue(previous.sizeBytes, row.sizeBytes) ||
                differentKnownValue(previous.modifiedMs, row.modifiedMs))

    fun recover(old: LocalMusicRow?, candidates: Sequence<LocalMusicRow>): LocalMusicRow? {
        if (old != null && matches(old)) return old
        if (old != null && !replacedAtOldPath(old)) return null
        return candidates.filter(::matches).take(2).toList().singleOrNull()
    }

    fun originalStillAtOldPath(old: LocalMusicRow?, hasTarget: Boolean): Boolean =
        old != null && !hasTarget && old.fileName == previous.fileName && old.matchesRevision(previous)

    private fun differentKnownValue(previous: Long?, current: Long?): Boolean =
        previous != null && current != null && previous != current
}

internal data class LocalMusicUriChange(val id: String, val oldUri: String, val newUri: String)

internal data class LocalMusicSnapshot(
    val tracks: Map<String, LocalMusicRow> = emptyMap(),
    val pending: List<PendingLocalMusicRename> = emptyList(),
    val unacknowledged: List<LocalMusicUriChange> = emptyList(),
)

/** The metadata cache and any pending rename are committed in the same file. */
internal class LocalMusicIndex(file: File) {
    private val atomic = AtomicFile(file)

    fun read(source: String): LocalMusicSnapshot = try {
        val json = JSONObject(atomic.readFully().toString(Charsets.UTF_8))
        if (json.getString("source") != source) LocalMusicSnapshot()
        else {
            val tracks = json.getJSONArray("tracks")
            val rows = buildMap {
                for (i in 0 until tracks.length()) {
                    val row = LocalMusicRow.fromJson(tracks.getJSONObject(i))
                    put(row.uri, row)
                }
            }
            val pending = json.optJSONArray("pending").objects {
                PendingLocalMusicRename(
                    it.getString("id"),
                    LocalMusicRow.fromJson(it.getJSONObject("previous")),
                    it.getString("name"),
                    it.stringOrNull("equivalentDocument"),
                )
            }
            val unacknowledged = json.optJSONArray("unacknowledged").objects {
                LocalMusicUriChange(it.getString("id"), it.getString("oldUri"), it.getString("newUri"))
            }
            LocalMusicSnapshot(rows, pending, unacknowledged)
        }
    } catch (_: FileNotFoundException) {
        LocalMusicSnapshot()
    } catch (_: JSONException) {
        LocalMusicSnapshot()
    }

    fun write(source: String, snapshot: LocalMusicSnapshot) {
        val json = JSONObject().put("source", source)
            .put("tracks", JSONArray(snapshot.tracks.values.map(LocalMusicRow::toJson)))
            .put("pending", JSONArray(snapshot.pending.map {
                JSONObject().put("id", it.id).put("previous", it.previous.toJson()).put("name", it.name)
                    .put("equivalentDocument", it.equivalentDocument)
            }))
            .put("unacknowledged", JSONArray(snapshot.unacknowledged.map {
                JSONObject().put("id", it.id).put("oldUri", it.oldUri).put("newUri", it.newUri)
            }))
        val stream = atomic.startWrite()
        try {
            stream.write(json.toString().toByteArray(Charsets.UTF_8))
            atomic.finishWrite(stream)
        } catch (failure: IOException) {
            atomic.failWrite(stream)
            throw failure
        }
    }

    fun clear() = atomic.delete()
}

private fun JSONObject.stringOrNull(key: String): String? =
    if (isNull(key)) null else getString(key)

private fun JSONObject.longOrNull(key: String): Long? =
    if (isNull(key)) null else getLong(key)

private fun <T> JSONArray?.objects(read: (JSONObject) -> T): List<T> =
    if (this == null) emptyList() else List(length()) { read(getJSONObject(it)) }
