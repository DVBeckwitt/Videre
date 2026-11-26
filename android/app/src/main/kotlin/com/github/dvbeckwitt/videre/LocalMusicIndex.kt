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
    val adjacentCover: String? = null,
    val canEditTags: Boolean = false,
    val editedTagFileProof: String? = null,
    val contentAdvisory: LocalMusicAdvisory? = null,
) {
    val visibilityKey get() = visibilityProof?.let { visibilityAlias ?: it }
    val playbackId: String by lazy(LazyThreadSafetyMode.NONE) {
        val key = identityKey ?: BigInteger(1, MessageDigest.getInstance("SHA-256")
            .digest((identityUri ?: uri).toByteArray(Charsets.UTF_8))).toString(16).padStart(64, '0')
        "device:$key"
    }

    fun matchesRevision(previous: LocalMusicRow): Boolean =
        modifiedMs != null && sizeBytes != null &&
            modifiedMs == previous.modifiedMs && sizeBytes == previous.sizeBytes

    fun retainsMetadata(previous: LocalMusicRow): Boolean = if (previous.editedTagFileProof != null) {
        editedTagFileProof == previous.editedTagFileProof
    } else canReuseMetadata(previous)

    fun canReuseMetadata(previous: LocalMusicRow): Boolean = matchesRevision(previous) &&
        (visibilityProof == null || previous.visibilityProof == null || visibilityProof == previous.visibilityProof)

    fun cachedContentAdvisory(previous: LocalMusicRow?): LocalMusicAdvisory? =
        previous?.contentAdvisory?.takeIf {
            uri == previous.uri && identityKey == previous.identityKey &&
                visibilityProof == previous.visibilityProof && matchesRevision(previous)
        }

    fun needsTagRead(previous: LocalMusicRow?, loadCovers: Boolean = true): Boolean {
        val metadata = previous?.metadata ?: return true
        val sortTags = metadata.sortTags ?: return true
        return !metadata.albumTagsRead || !metadata.genreRead || !sortTags.discSubtitleRead || !sortTags.releaseKindRead ||
            metadata.tagValues == null || !metadata.replayGainRead || metadata.retryRead || !retainsMetadata(previous) ||
            identityKey != previous.identityKey || (loadCovers && metadata.coverReadDeferred)
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

    fun retainsEditedFileVisibility(previous: LocalMusicRow) = copy(
        visibilityAlias = previous.visibilityKey?.takeIf { visibilityProof != null && it != visibilityProof },
    )

    // MediaStore album IDs belong to a volume. SAF has no album entity: the
    // actual traversed parent plus both album tags identify a local grouping.
    fun albumKey(source: String): String? {
        val album = localCollectionTag(metadata?.album) ?: return null
        val parts = if (source == LocalMusicCatalog.SYSTEM_URI) {
            val id = mediaAlbumId?.takeIf { it > 0 } ?: return null
            listOf(source, uri.substringBeforeLast('/'), id.toString())
        } else {
            val parent = parentDocumentId?.takeIf { it.isNotBlank() } ?: return null
            val artist = localCollectionTag(metadata?.albumArtist) ?: return null
            listOf(source, parent, artist, album)
        }
        val input = parts.joinToString("") { "${it.length}:$it" }.toByteArray(Charsets.UTF_8)
        val digest = MessageDigest.getInstance("SHA-256").digest(input)
        return BigInteger(1, digest).toString(16).padStart(64, '0')
    }

    fun channelValue(
        artPath: String? = null,
        source: String? = null,
        adjacentArtPath: String? = null,
        tagSeparators: String = "",
    ): Map<String, Any?> = mapOf(
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
        "genre" to metadata?.genre,
        "artists" to localMusicTagList(metadata?.tagValues?.artists.orEmpty(), metadata?.artist, tagSeparators),
        "albumArtists" to localMusicTagList(metadata?.tagValues?.albumArtists.orEmpty(), metadata?.albumArtist, tagSeparators),
        "genres" to localMusicTagList(metadata?.tagValues?.genres.orEmpty(), metadata?.genre, tagSeparators),
        "albumKey" to source?.let(::albumKey),
        "releaseKind" to metadata?.sortTags?.releaseKind?.tag,
        "discNumber" to metadata?.discNumber,
        "discSubtitle" to metadata?.sortTags?.discSubtitle,
        "trackNumber" to metadata?.trackNumber,
        "releaseDate" to metadata?.releaseDate,
        "originalReleaseDate" to metadata?.originalReleaseDate,
        "replayGain" to metadata?.replayGain?.channelValue(),
        "durationMs" to (metadata?.durationMs ?: 0L),
        "artPath" to artPath,
        "adjacentArtPath" to adjacentArtPath,
        "addedMs" to addedMs,
        "modifiedMs" to modifiedMs,
        "sizeBytes" to sizeBytes,
        "firstSeen" to firstSeen,
        "canRename" to canRename,
        "canEditTags" to canEditTags,
        "parentDocumentId" to parentDocumentId,
        "identityUri" to identityUri,
        "identityKey" to identityKey,
        "visibilityKey" to visibilityKey,
        "isRecording" to isRecording,
        "contentAdvisory" to contentAdvisory?.channelValue,
        "folderLocations" to folderLocations.map { it.channelValue },
    )

    fun toJson(): JSONObject = JSONObject(channelValue()).apply {
        remove("artPath")
        remove("adjacentArtPath")
        remove("title")
        remove("artist")
        remove("album")
        remove("albumArtist")
        remove("titleSort")
        remove("artistSort")
        remove("albumSort")
        remove("albumArtistSort")
        remove("genre")
        remove("artists")
        remove("albumArtists")
        remove("genres")
        remove("albumKey")
        remove("releaseKind")
        remove("discNumber")
        remove("discSubtitle")
        remove("trackNumber")
        remove("releaseDate")
        remove("originalReleaseDate")
        remove("replayGain")
        remove("durationMs")
        remove("visibilityKey")
        put("metadata", metadata?.toJson())
        put("parentKey", parentKey)
        put("mediaAlbumId", mediaAlbumId)
        put("visibilityProof", visibilityProof)
        put("visibilityAlias", visibilityAlias)
        put("adjacentCover", adjacentCover)
        put("editedTagFileProof", editedTagFileProof)
        put("contentAdvisory", contentAdvisory?.let { it.channelValue ?: JSONObject.NULL })
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
            adjacentCover = json.stringOrNull("adjacentCover"),
            canEditTags = json.opt("canEditTags") == true,
            editedTagFileProof = json.stringOrNull("editedTagFileProof"),
            contentAdvisory = when (json.opt("contentAdvisory")) {
                1 -> LocalMusicAdvisory.EXPLICIT
                2 -> LocalMusicAdvisory.CLEAN
                JSONObject.NULL -> LocalMusicAdvisory.UNKNOWN
                else -> null
            },
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
    val genre: String? = null,
    val genreRead: Boolean = false,
    val retryRead: Boolean = false,
    val replayGain: LocalReplayGain? = null,
    val replayGainRead: Boolean = true,
    val coverReadDeferred: Boolean = false,
    // Null marks an older row or an interrupted stream read. A completed read may find no native lists.
    val tagValues: LocalMusicTagValues? = null,
) {
    fun toJson(): JSONObject = JSONObject()
        .put("title", title).put("artist", artist).put("album", album)
        .put("durationMs", durationMs).put("cover", cover)
        .put("albumArtist", albumArtist ?: JSONObject.NULL)
        .put("discNumber", discNumber).put("trackNumber", trackNumber)
        .put("releaseDate", releaseDate).put("originalReleaseDate", originalReleaseDate)
        .put("albumTagsRead", albumTagsRead)
        .apply {
            if (coverReadDeferred) put("coverReadDeferred", true)
            sortTags?.let {
                put("sortTags", JSONObject().put("title", it.title).put("artist", it.artist)
                    .put("album", it.album).put("albumArtist", it.albumArtist).apply {
                        // An explicit null records a completed read with no usable subtitle.
                        if (it.discSubtitleRead) put("discSubtitle", it.discSubtitle ?: JSONObject.NULL)
                        if (it.releaseKindRead) put("releaseKind", it.releaseKind?.tag ?: JSONObject.NULL)
                    })
            }
        }
        .apply {
            if (genreRead) put("genre", genre ?: JSONObject.NULL)
            tagValues?.let {
                put("tagValues", JSONObject().apply {
                    if (it.artists.isNotEmpty()) put("artists", JSONArray(it.artists))
                    if (it.albumArtists.isNotEmpty()) put("albumArtists", JSONArray(it.albumArtists))
                    if (it.genres.isNotEmpty()) put("genres", JSONArray(it.genres))
                })
            }
        }
        .apply { if (retryRead) put("retryRead", true) }
        .apply {
            if (replayGainRead) {
                put("replayGain", replayGain?.let { JSONObject(it.channelValue()) } ?: JSONObject.NULL)
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
                    it.stringOrNull("album"), it.stringOrNull("albumArtist"),
                    discSubtitle = it.stringOrNull("discSubtitle"),
                    discSubtitleRead = it.has("discSubtitle"),
                    releaseKind = LocalMusicReleaseKind.fromTag(it.opt("releaseKind") as? String),
                    releaseKindRead = it.has("releaseKind"))
            },
            localCollectionTag(json.stringOrNull("genre")),
            json.has("genre"),
            json.optBoolean("retryRead"),
            json.optJSONObject("replayGain")?.let {
                LocalReplayGain.fromValues(
                    it.optDouble("trackGainDb"), it.optDouble("albumGainDb"),
                    it.optDouble("trackPeak"), it.optDouble("albumPeak"),
                )
            },
            json.has("replayGain"),
            json.opt("coverReadDeferred") == true,
            json.optJSONObject("tagValues")?.let {
                LocalMusicTagValues(
                    artists = it.tagList("artists"),
                    albumArtists = it.tagList("albumArtists"),
                    genres = it.tagList("genres"),
                )
            },
        )
    }
}

internal fun localCollectionTag(text: String?): String? = text?.trim()?.takeIf {
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
    val moves: LocalMusicMoves = LocalMusicMoves(),
)

/** The metadata cache and any pending rename are committed in the same file. */
internal class LocalMusicIndex(file: File) {
    private val atomic = AtomicFile(file)

    // Playback can probe while a scan is writing. AtomicFile.openRead can
    // remove an in-progress staging file, so read only the published base here.
    fun containsCommittedTrack(source: String, uri: String): Boolean = try {
        val json = JSONObject(atomic.baseFile.readText())
        val tracks = json.getJSONArray("tracks")
        json.getString("source") == source &&
            (0 until tracks.length()).any { tracks.getJSONObject(it).getString("uri") == uri }
    } catch (_: IOException) {
        false
    } catch (_: JSONException) {
        false
    }

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
            val missing = json.optJSONArray("missingForRepair").objects(LocalMusicRow::fromJson)
                .associateBy { it.playbackId }
            val links = json.optJSONArray("reviewedMoves").objects {
                it.getString("originalId") to LocalMusicMoveLink(
                    it.getString("targetId"), it.getString("targetProof"), it.stringOrNull("originalPlaylistProof"),
                )
            }.toMap()
            LocalMusicSnapshot(rows, pending, unacknowledged, LocalMusicMoves(missing, links))
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
            .put("missingForRepair", JSONArray(snapshot.moves.missing.values.map(LocalMusicRow::toJson)))
            .put("reviewedMoves", JSONArray(snapshot.moves.links.map { (id, link) ->
                JSONObject().put("originalId", id).put("targetId", link.targetId).put("targetProof", link.targetProof)
                    .put("originalPlaylistProof", link.originalPlaylistProof)
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

private fun JSONObject.tagList(key: String): List<String> {
    val array = optJSONArray(key) ?: return emptyList()
    return List(array.length()) { array.opt(it) as? String }.mapNotNull(::localCollectionTag)
}

private fun JSONObject.stringOrNull(key: String): String? =
    if (isNull(key)) null else getString(key)

private fun JSONObject.longOrNull(key: String): Long? =
    if (isNull(key)) null else getLong(key)

private fun <T> JSONArray?.objects(read: (JSONObject) -> T): List<T> =
    if (this == null) emptyList() else List(length()) { read(getJSONObject(it)) }
