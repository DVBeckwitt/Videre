package com.github.dvbeckwitt.videre

import android.content.ContentUris
import android.content.Context
import android.database.Cursor
import android.graphics.Bitmap
import android.graphics.BitmapFactory
import android.media.MediaMetadataRetriever
import android.net.Uri
import android.os.Build
import android.os.CancellationSignal
import android.os.Environment
import android.os.OperationCanceledException
import android.os.SystemClock
import android.provider.DocumentsContract
import android.provider.DocumentsContract.Document
import android.provider.MediaStore
import android.provider.MediaStore.Audio.Media as Audio
import android.system.ErrnoException
import android.system.Os
import android.system.OsConstants
import android.util.Base64
import android.util.Log
import java.io.ByteArrayOutputStream
import java.io.File
import java.io.IOException
import java.security.MessageDigest
import java.util.ArrayDeque
import java.util.Locale
import java.util.UUID

internal data class LocalMusicScanResult(
    val tracks: List<Map<String, Any?>>,
    val partial: Boolean,
    val notificationUris: Set<Uri>,
)

internal class LocalMusicCatalog(
    private val context: Context, cache: File, indexFile: File, visibilityAliasFile: File,
    private val loadCovers: Boolean = true,
    private val tagSeparators: String = "",
) {
    private val artwork by lazy { LocalMusicCovers(cache) }
    private val index = LocalMusicIndex(indexFile)
    private val visibilityArchive = LocalMusicVisibilityAliasArchive(visibilityAliasFile)

    fun tracks(
        source: Uri,
        signal: CancellationSignal,
        force: Boolean = false,
        isDocumentProvider: Boolean = false,
        report: LocalMusicScanReport? = null,
        publish: (List<Map<String, Any?>>) -> Unit = {},
    ): LocalMusicScanResult {
        val started = SystemClock.elapsedRealtime()
        val sourceKey = source.toString()
        val snapshot = index.read(sourceKey)
        val visibilityAliases = visibilityArchive.read()
        val scanned = linkedMapOf<String, LocalMusicRow>()
        val mediaSummaries = mutableMapOf<String, LocalMusicMetadata>()
        // A path-based provider can reuse the old URI after a rename. Reserve
        // the ID for the renamed song until it actually leaves this library.
        val reserved = buildMap {
            (snapshot.tracks.values + snapshot.pending.map { it.previous }).forEach { row ->
                if (row.identityKey == null) put(row.identityUri ?: row.uri, row.uri)
            }
        }
        val reservedVisibility = snapshot.tracks.values.mapNotNull { row ->
            row.visibilityAlias?.let { it to row.uri }
        }.toMap()
        val batch = TrackBatch(publish)
        val coverRepairs = if (loadCovers) LocalMusicCoverRepairs() else null
        val adjacentArtwork = if (loadCovers && !isDocumentProvider) LocalMusicAdjacentCovers(context.contentResolver, signal) else null
        val scanTime = System.currentTimeMillis()
        val pendingTargets = snapshot.pending.groupBy { it.name }
        val pendingSources = snapshot.pending.mapTo(mutableSetOf()) { it.previous.uri }
        val held = mutableSetOf<String>()

        fun publishDiscovered(row: LocalMusicRow) {
            if (force || isDocumentProvider) return
            val value = channelValue(row, sourceKey)
            coverRepairs?.consider(row, value["artPath"] != null)
            batch.add(value)
        }

        fun collect(draft: LocalMusicRow) {
            val previous = snapshot.tracks[draft.uri]
            val editedFileProof = previous?.editedTagFileProof?.takeIf { proof ->
                !isDocumentProvider && descriptorVisibilityProof(Uri.parse(draft.uri), signal) == proof
            }
            val row = draft.copy(
                addedMs = if (draft.firstSeen) previous?.addedMs ?: scanTime else draft.addedMs,
                firstSeen = draft.firstSeen && (previous?.firstSeen != false),
                metadata = if (previous?.editedTagFileProof != null) {
                    previous.metadata?.takeIf { editedFileProof != null } ?: draft.metadata
                } else {
                    previous?.metadata?.takeIf { draft.canReuseMetadata(previous) } ?: draft.metadata
                },
                editedTagFileProof = editedFileProof,
                mediaAlbumId = draft.mediaAlbumId.takeUnless {
                    editedFileProof != null && previous?.mediaAlbumId == null &&
                        localAlbumTag(draft.metadata?.album) != previous?.metadata?.album
                },
                adjacentCover = if (!loadCovers && previous?.parentKey == draft.parentKey)
                    previous?.adjacentCover else null,
            )
            val inherited = when {
                previous != null && editedFileProof != null ->
                    row.inheritsIdentity(previous).retainsEditedFileVisibility(previous)
                previous != null -> row.inheritsIdentity(previous).inheritsVisibility(previous)
                draft.uri in reserved && reserved[draft.uri] != draft.uri ->
                    row.copy(identityKey = newIdentityKey())
                else -> row
            }
            val protected = snapshot.moves.protectIdentity(inherited, previous, ::newIdentityKey)
            val indexed = if (previous != null && protected.identityKey != inherited.identityKey) {
                protected.copy(addedMs = if (draft.firstSeen) scanTime else draft.addedMs,
                    firstSeen = draft.firstSeen, metadata = draft.metadata)
            } else protected
            val withVisibility = indexed.let {
                val aliasOwner = it.visibilityKey?.let(reservedVisibility::get)
                if (aliasOwner != null && aliasOwner != it.uri) {
                    // Reusing the old URI must not reuse a key still owned by
                    // the other, renamed file even if revision values repeat.
                    it.copy(visibilityAlias = newIdentityKey())
                } else it
            }
            val verified = if (editedFileProof != null) {
                // MediaStore can publish its new revision after our descriptor
                // has closed. Anchor the visibility key to the verified file.
                if (previous?.visibilityProof != withVisibility.visibilityProof) {
                    retainTagVisibility(withVisibility, editedFileProof)
                }
                withVisibility
            } else visibilityAliases.resolve(withVisibility) {
                if (isDocumentProvider) null else descriptorVisibilityProof(Uri.parse(withVisibility.uri), signal)
            }
            // A path involved in an unfinished rename may already contain a replacement.
            val cachedAdvisory = verified.cachedContentAdvisory(previous.takeUnless { force || verified.uri in pendingSources })
            val identified = verified.copy(
                contentAdvisory = if (isDocumentProvider) null else
                    cachedAdvisory ?: readContentAdvisory(Uri.parse(verified.uri), signal),
            )
            scanned[identified.uri] = identified
            // Wait for the complete listing before choosing a recovery match.
            // A provisional identity would briefly describe the wrong file.
            val waitForRecovery = pendingTargets[identified.fileName]?.any { it.targets(identified) } == true ||
                identified.uri in pendingSources
            if (editedFileProof == null && (force || identified.needsTagRead(previous, loadCovers) || waitForRecovery)) {
                // Verified edits, including clears, must not use stale MediaStore summaries.
                draft.metadata?.let { mediaSummaries[draft.uri] = it }
            }
            if (waitForRecovery) {
                held.add(identified.uri)
            } else {
                publishDiscovered(identified)
            }
        }

        val system = sourceKey == SYSTEM_URI
        val cues = if (system || isDocumentProvider) null else LocalMusicCueTracks(context.contentResolver, source, signal)
        val notificationUris = linkedSetOf<Uri>()
        val incompleteListing = if (system) {
            scanMediaStore(source, signal, report, ::collect)
            false
        } else {
            scanFolder(source, signal, notificationUris, adjacentArtwork, cues, isDocumentProvider, report, ::collect)
        }
        signal.throwIfCanceled()
        // Provider scans publish a complete listing without opening audio documents.
        if (isDocumentProvider) {
            index.write(sourceKey, snapshot.copy(tracks = scanned))
            return LocalMusicScanResult(orderedTracks(scanned, sourceKey), false, notificationUris)
        }
        val pending = mutableListOf<PendingLocalMusicRename>()
        val changes = snapshot.unacknowledged.toMutableList()
        val recovered = mutableSetOf<String>()
        var moves = snapshot.moves
        if (incompleteListing) {
            // A missing subtree can contain a competing rename match. Keep
            // the journal and the last known identities until a full listing.
            held.forEach(scanned::remove)
            pending.addAll(snapshot.pending)
        }
        for (rename in snapshot.pending.takeUnless { incompleteListing }.orEmpty()) {
            val previous = rename.previous
            val old = scanned[previous.uri]
            val targets = held.asSequence()
                .filter { it !in recovered }
                .mapNotNull(scanned::get)
                .filter(rename::targets)
                .toList()
            val match = rename.recover(old, targets.asSequence())
            val originalStillPresent = rename.originalStillAtOldPath(old, targets.isNotEmpty())
            if (old != null && old.uri != match?.uri && !originalStillPresent &&
                (old.identityKey == null || old.identityKey == previous.identityKey)) {
                // The same path can now describe another file. Keep the original
                // session ID reserved until a unique recovery can be proven.
                scanned[old.uri] = old.copy(
                    addedMs = if (old.firstSeen) scanTime else old.addedMs,
                    identityUri = null,
                    identityKey = newIdentityKey(),
                    metadata = null,
                )
            }
            if (match != null) {
                recovered.add(match.uri)
                val recoveredRow = match.inheritsIdentity(previous).copy(
                    addedMs = previous.addedMs,
                    firstSeen = previous.firstSeen,
                ).inheritsVisibility(previous, confirmedRename = match.matchesRevision(previous))
                scanned[match.uri] = recoveredRow
                moves = moves.verifiedRename(previous, recoveredRow)
                val matchedVisibility = recoveredRow.visibilityKey
                if (old != null && old.uri != match.uri && matchedVisibility != null &&
                    scanned[old.uri]?.visibilityKey == matchedVisibility) {
                    scanned[old.uri] = scanned.getValue(old.uri).copy(visibilityAlias = newIdentityKey())
                }
                changes.addAll(uriChanges(rename, match.uri))
            } else if (!originalStillPresent) {
                if (old != null && targets.isNotEmpty() && old.visibilityKey == previous.visibilityKey) {
                    // The journal cannot establish which candidate owns the
                    // old proof. Let the unresolved source remain visible.
                    scanned[old.uri] = scanned.getValue(old.uri).copy(
                        visibilityProof = null, visibilityAlias = null,
                    )
                }
                pending.add(rename)
            }
        }
        if (!incompleteListing) moves = moves.observe(snapshot.tracks.values, scanned.values)
        if (!force && !incompleteListing) {
            index.write(sourceKey, LocalMusicSnapshot(
                tracks = scanned.mapValues { (uri, row) ->
                    // For uncached rows, keep only file attributes until the tag
                    // pass succeeds. MediaStore's summary is useful on screen but
                    // doesn't count as retained embedded metadata.
                    val previous = snapshot.tracks[uri]
                    if (previous?.metadata != null && row.retainsMetadata(previous) &&
                        row.identityKey == previous.identityKey) row else row.copy(metadata = null)
                },
                pending = pending,
                unacknowledged = changes,
                moves = moves,
            ))
        }
        held.forEach { uri -> scanned[uri]?.let(::publishDiscovered) }
        batch.flush()

        var reads = 0
        var partial = incompleteListing
        scanned.entries.forEach { entry ->
            signal.throwIfCanceled()
            val row = entry.value
            val previous = snapshot.tracks[row.uri]
            if (force || row.needsTagRead(previous, loadCovers)) {
                ++reads
                val metadata = readMetadata(Uri.parse(row.uri), mediaSummaries[row.uri], signal)
                signal.throwIfCanceled()
                if (metadata == null) partial = true
                // Leave an unsuccessful read eligible for an incremental retry.
                entry.setValue(row.copy(metadata = metadata ?: row.metadata?.copy(retryRead = true)))
                if (!force) batch.add(channelValue(entry.value, sourceKey))
            }
        }
        var coverReads = 0
        for ((cover, uri) in coverRepairs?.candidates.orEmpty()) {
            signal.throwIfCanceled()
            // A normal tag read may have already regenerated this shared cover.
            if (artwork.path(cover) != null) continue
            ++coverReads
            repairCover(Uri.parse(uri), cover, signal)
        }
        batch.flush()
        if (adjacentArtwork != null) {
            if (system) adjacentArtwork.discoverMediaStore(scanned.values)
            val adjacentByParent = adjacentArtwork.cacheByParent(artwork::storeAdjacent)
            for (entry in scanned.entries) {
                val cover = adjacentByParent[entry.value.parentKey] ?: continue
                entry.setValue(entry.value.copy(adjacentCover = cover))
            }
        }
        // Keep cached membership when discovery could not enumerate the whole
        // tree. A later complete listing can prove which rows were removed.
        val tracks = if (incompleteListing) snapshot.tracks + scanned else scanned
        val channelTracks = tracks.values.sortedWith(compareBy(String.CASE_INSENSITIVE_ORDER) {
            it.metadata?.title ?: fallbackTitle(it.fileName)
        }).map { channelValue(it, sourceKey) }
        val virtualTracks = cues?.tracks(scanned.values) { channelValue(it, sourceKey) }.orEmpty()
        signal.throwIfCanceled()
        index.write(sourceKey, LocalMusicSnapshot(tracks, pending, changes, moves))
        if (!force) virtualTracks.forEach(batch::add)
        batch.flush()
        if (loadCovers) artwork.removeUnused()
        Log.d("VidereLocalMusic",
            "tracks=${tracks.size} tagReads=$reads coverReads=$coverReads partial=$partial elapsedMs=${SystemClock.elapsedRealtime() - started}")
        return LocalMusicScanResult(channelTracks + virtualTracks, partial, notificationUris)
    }

    private fun orderedTracks(rows: Map<String, LocalMusicRow>, source: String) =
        rows.values.sortedWith(compareBy(String.CASE_INSENSITIVE_ORDER) {
            it.metadata?.title ?: fallbackTitle(it.fileName)
        }).map { channelValue(it, source) }

    fun indexedTrack(source: Uri, uri: Uri): Map<String, Any?>? =
        index.read(source.toString()).tracks[uri.toString()]?.let { channelValue(it, source.toString()) }

    fun movedFileRepairs(source: Uri): Map<String, Any> {
        val snapshot = index.read(source.toString())
        return snapshot.moves.channelValue(snapshot.tracks.values)
    }

    fun confirmMovedFileRepair(
        source: Uri, missingId: String, candidateId: String, signal: CancellationSignal,
        stillCurrent: () -> Boolean,
    ): Map<String, Any>? {
        val snapshot = index.read(source.toString())
        val original = snapshot.moves.missing[missingId] ?: return null
        val candidate = snapshot.tracks.values.find { it.playbackId == candidateId } ?: return null
        val reviewed = snapshot.moves.confirm(missingId, candidate) ?: return null
        val target = Uri.parse(candidate.uri)
        // A matching listing alone can outlive the file it describes.
        if (!canRead(target, signal) || readVisibilityProof(source, target) != candidate.visibilityProof) return null
        val old = Uri.parse(original.uri)
        val oldProof = readVisibilityProof(source, old)
        if ((oldProof == null || original.visibilityProof == null || oldProof == original.visibilityProof) &&
            canRead(old, signal)) return null
        signal.throwIfCanceled()
        if (!stillCurrent()) return null
        index.write(source.toString(), snapshot.copy(moves = reviewed))
        return reviewed.channelValue(snapshot.tracks.values)
    }

    private fun canRead(uri: Uri, signal: CancellationSignal): Boolean = try {
        context.contentResolver.openFileDescriptor(uri, "r", signal)?.use { true } == true
    } catch (cancelled: OperationCanceledException) {
        throw cancelled
    } catch (_: Exception) {
        false
    }

    fun containsCommittedTrack(source: Uri, uri: Uri): Boolean =
        index.containsCommittedTrack(source.toString(), uri.toString())

    private fun sameRecording(source: Uri, uri: Uri, track: LocalMusicRow): Boolean =
        track.editedTagFileProof?.let { descriptorVisibilityProof(uri) == it }
            ?: (track.visibilityProof == null || readVisibilityProof(source, uri) == track.visibilityProof)

    fun shareableTrackName(source: Uri, uri: Uri, trackId: String?): String? {
        val track = index.read(source.toString()).tracks[uri.toString()] ?: return null
        if (trackId != null && trackId != track.playbackId) return null
        return track.fileName.takeIf { sameRecording(source, uri, track) }
    }

    private fun <T> readVerifiedTrack(
        source: Uri, trackUri: String, trackId: String, read: (LocalMusicRow, Uri) -> T?,
    ): T? {
        val track = index.read(source.toString()).tracks[trackUri] ?: return null
        if (trackId != track.playbackId) return null
        val uri = Uri.parse(track.uri)
        if (!sameRecording(source, uri, track)) return null
        return read(track, uri)?.takeIf { sameRecording(source, uri, track) }
    }

    fun readTrackAudioFormat(source: Uri, trackUri: String, trackId: String): Map<String, Any?>? =
        readVerifiedTrack(source, trackUri, trackId) { _, uri -> MusicFileAudioFormat.read(context, uri) }

    fun readTrackLyrics(source: Uri, trackUri: String, trackId: String): Map<String, Any>? =
        readVerifiedTrack(source, trackUri, trackId) { track, uri ->
            val embedded = try {
                val audio = context.contentResolver.openInputStream(uri) ?: return@readVerifiedTrack null
                audio.use(LocalMusicEmbeddedLyrics::read)
            } catch (_: IOException) {
                return@readVerifiedTrack null
            } catch (_: SecurityException) {
                return@readVerifiedTrack null
            }
            // Android's system audio permission doesn't grant access to sibling
            // documents. Only a selected document tree provides that access.
            val sidecars = if (source.toString() == SYSTEM_URI) emptyMap() else readSidecars(source, uri, track)
            // An empty result still confirms that this audio file was readable.
            buildMap {
                putAll(sidecars)
                if (embedded != null) put("embedded", embedded)
            }
        }

    private fun readSidecars(tree: Uri, audio: Uri, track: LocalMusicRow): Map<String, Any> = try {
        val parent = track.parentDocumentId
        if (parent == null) emptyMap() else {
            val resolver = context.contentResolver
            val children = DocumentsContract.buildChildDocumentsUriUsingTree(tree, parent)
            val columns = arrayOf(Document.COLUMN_DOCUMENT_ID, Document.COLUMN_DISPLAY_NAME,
                Document.COLUMN_MIME_TYPE, Document.COLUMN_FLAGS)
            val candidates = resolver.query(children, columns, null, null, null)?.use { cursor ->
                if (cursor.extras.getBoolean(DocumentsContract.EXTRA_LOADING, false) ||
                    cursor.extras.containsKey(DocumentsContract.EXTRA_ERROR)) return@use emptyList()
                val siblings = sequence {
                    while (cursor.moveToNext()) {
                        val id = cursor.getString(0)?.takeIf(String::isNotEmpty) ?: continue
                        val name = cursor.getString(1)?.takeIf(String::isNotEmpty) ?: continue
                        val mime = cursor.getString(2).orEmpty()
                        val flags = cursor.numeric(Document.COLUMN_FLAGS) ?: 0L
                        if (mime == Document.MIME_TYPE_DIR ||
                            flags and (Document.FLAG_VIRTUAL_DOCUMENT or Document.FLAG_PARTIAL).toLong() != 0L) continue
                        yield(LocalMusicSidecarLyrics.Sibling(id, name, isAudio(mime, name)))
                    }
                }
                LocalMusicSidecarLyrics.candidates(DocumentsContract.getDocumentId(audio), track.fileName, siblings)
            }.orEmpty()
            LocalMusicSidecarLyrics.readCandidates(candidates) { id ->
                val sidecar = DocumentsContract.buildDocumentUriUsingTree(tree, id)
                resolver.openInputStream(sidecar)
            }
        }
    } catch (_: RuntimeException) {
        emptyMap()
    }

    fun indexedOpenedAudio(source: Uri, uri: Uri): String? {
        val tracks = index.read(source.toString()).tracks
        if (tracks.isEmpty()) return null
        return LocalMusicDownloadMatcher(context, source, tracks, CancellationSignal()).matchOpenedAudio(uri)
    }

    fun shareableTrackNames(
        source: Uri, tracks: List<Triple<Uri, String?, String?>>,
    ): List<String> {
        val indexed = index.read(source.toString()).tracks
        return tracks.map { (uri, trackId, visibilityKey) ->
            val track = requireNotNull(indexed[uri.toString()])
            require(trackId == null || trackId == track.playbackId)
            require(visibilityKey == null || visibilityKey == track.visibilityKey)
            require(sameRecording(source, uri, track))
            track.fileName
        }
    }

    fun tagEditName(source: Uri, uri: Uri): String {
        val row = index.read(source.toString()).tracks[uri.toString()]
            ?: throw LocalMusicTagEdit.Failure("TAGS_CHANGED")
        if (!row.canEditTags) throw LocalMusicTagEdit.Failure("TAGS_UNSUPPORTED")
        val current = readVisibilityProof(source, uri) ?: throw LocalMusicTagEdit.Failure("TAGS_CHANGED")
        val matches = if (row.editedTagFileProof != null) descriptorVisibilityProof(uri) == row.editedTagFileProof
            else current == row.visibilityProof
        if (!matches) throw LocalMusicTagEdit.Failure("TAGS_CHANGED")
        return row.fileName
    }

    fun editedTags(
        source: Uri, uri: Uri, changedFields: Set<String>, edit: LocalMusicTagEdit.Step.Done,
        artworkEdit: LocalMusicId3.ArtworkEdit? = null,
    ): Map<String, Any?> {
        val key = source.toString()
        val snapshot = index.read(key)
        val previous = snapshot.tracks[uri.toString()] ?: throw IOException()
        val providerProof = readVisibilityProof(source, uri) ?: throw IOException()
        if (descriptorVisibilityProof(uri) != edit.fileProof) throw IOException()
        val prior = previous.metadata ?: LocalMusicMetadata(null, null, null, 0L)
        fun tag(field: String, value: String?): String? = if (field in changedFields) {
            edit.values[field]?.trim()?.takeIf(String::isNotEmpty)?.take(1024)
        } else value
        val cover = when {
            artworkEdit == null -> prior.cover
            !loadCovers -> null
            artworkEdit.image != null -> artwork.store(artworkEdit.image) ?: throw IOException()
            else -> {
                var remaining: String? = null
                readMedia(uri) { retriever ->
                    remaining = retriever.embeddedPicture?.let { artwork.store(it) }
                }
                remaining
            }
        }
        val genreEdited = "genre" in changedFields
        val releaseEdited = "releaseDate" in changedFields
        var genre = if (genreEdited) localCollectionTag(edit.values["genre"]) else prior.genre
        var releaseDate = if (releaseEdited) edit.values["releaseDate"] else prior.releaseDate
        if (releaseEdited && releaseDate == null) {
            // The regular scanner can still derive a date from recording or legacy year tags.
            releaseDate = readLocalId3Dates { context.contentResolver.openInputStream(uri) }?.release
        }
        if (genreEdited || (releaseEdited && releaseDate == null)) {
            try {
                readMedia(uri) { retriever ->
                    if (genreEdited) genre = readGenre(retriever) ?: genre
                    if (releaseEdited && releaseDate == null) {
                        releaseDate = localReleaseDate(retriever.extractMetadata(MediaMetadataRetriever.METADATA_KEY_YEAR))
                    }
                }
            } catch (denied: SecurityException) {
                throw denied
            } catch (_: RuntimeException) {
                // A successful write still provides the verified ID3 values.
            }
        }
        val values = prior.tagValues?.let { previousValues ->
            previousValues.copy(
                artists = if ("artist" in changedFields) emptyList() else previousValues.artists,
                albumArtists = if ("albumArtist" in changedFields) emptyList() else previousValues.albumArtists,
                genres = if (genreEdited) emptyList() else previousValues.genres,
            )
        }
        val metadata = prior.copy(
            title = tag("title", prior.title),
            genre = genre,
            genreRead = prior.genreRead || genreEdited,
            releaseDate = releaseDate,
            artist = tag("artist", prior.artist),
            album = localAlbumTag(tag("album", prior.album)),
            albumArtist = localAlbumTag(tag("albumArtist", prior.albumArtist)),
            trackNumber = if ("trackNumber" in changedFields || "trackTotal" in changedFields) {
                localAlbumPosition(edit.values["trackNumber"])
            } else prior.trackNumber,
            discNumber = if ("discNumber" in changedFields || "discTotal" in changedFields) {
                localAlbumPosition(edit.values["discNumber"])
            } else prior.discNumber,
            cover = cover,
            coverReadDeferred = prior.coverReadDeferred || (!loadCovers && artworkEdit != null),
            tagValues = values,
        )
        val updated = previous.copy(
            metadata = metadata,
            visibilityProof = providerProof,
            editedTagFileProof = edit.fileProof,
            // Wait for the provider to assign the edited tags to an album.
            mediaAlbumId = previous.mediaAlbumId.takeIf {
                prior.album == metadata.album && prior.albumArtist == metadata.albumArtist
            },
        ).retainsEditedFileVisibility(previous)
        index.write(key, snapshot.copy(tracks = snapshot.tracks + (updated.uri to updated)))
        retainTagVisibility(updated, edit.fileProof)
        return channelValue(updated, key)
    }

    private fun retainTagVisibility(row: LocalMusicRow, fileProof: String) {
        val key = row.visibilityKey ?: return
        val providerProof = row.visibilityProof ?: return
        try {
            visibilityArchive.retain(LocalMusicVisibilityAlias(key, providerProof, fileProof))
        } catch (_: IOException) {
            // The current selection still carries the verified key in its index.
        }
    }

    fun playlistLocations(source: Uri, signal: CancellationSignal): Map<String, Any> {
        val storage = M3uStorage(context)
        val roots = storage.volumeRoots()
        val system = source.toString() == SYSTEM_URI
        val locations = buildMap {
            for ((uri, row) in index.read(source.toString()).tracks) {
                signal.throwIfCanceled()
                storage.musicLocation(row, system, roots)?.let { put(uri, it) }
            }
        }
        return mapOf("roots" to roots, "locations" to locations)
    }

    fun matchDownloads(
        source: Uri, downloads: List<LocalMusicDownloadCandidate>, signal: CancellationSignal,
    ): Map<String, List<String>> {
        val matcher = LocalMusicDownloadMatcher(context, source, index.read(source.toString()).tracks, signal)
        return buildMap {
            for (download in downloads) {
                val matches = matcher.match(download)
                if (matches.isNotEmpty()) put(download.key, matches)
            }
        }
    }

    fun prepareRename(source: Uri, uri: Uri, name: String) {
        val key = source.toString()
        val snapshot = index.read(key)
        val row = snapshot.tracks[uri.toString()] ?: throw IOException()
        val pending = snapshot.pending.filterNot { it.previous.uri == row.uri }
        val equivalent = if (key == SYSTEM_URI) externalStorageDocument(uri)?.toString() else null
        // Compare the provider's current instance with the indexed one before
        // this journal authorizes transferring visibility to a changed URI.
        val verified = visibilityArchive.read().resolve(
            row.copy(visibilityProof = readVisibilityProof(source, uri)).inheritsVisibility(row),
        ) { descriptorVisibilityProof(uri) }
        val rename = PendingLocalMusicRename(UUID.randomUUID().toString(), verified, name, equivalent)
        index.write(key, snapshot.copy(pending = pending + rename))
    }

    fun cancelRename(source: Uri, uri: Uri) {
        val key = source.toString()
        val snapshot = index.read(key)
        val pending = snapshot.pending.filterNot { it.previous.uri == uri.toString() }
        if (pending.size != snapshot.pending.size) index.write(key, snapshot.copy(pending = pending))
    }

    fun renamedTrack(source: Uri, oldUri: Uri, newUri: Uri, name: String): Map<String, Any?> {
        val key = source.toString()
        val snapshot = index.read(key)
        val previous = snapshot.tracks[oldUri.toString()] ?: throw IOException()
        val recorded = snapshot.pending.firstOrNull { it.previous.uri == previous.uri }
        val updated = previous.copy(
            uri = newUri.toString(),
            fileName = name,
            visibilityProof = readVisibilityProof(source, newUri),
            editedTagFileProof = null,
        ).inheritsIdentity(previous).inheritsVisibility(
            recorded?.previous ?: previous, confirmedRename = recorded != null,
        )
        val tracks = snapshot.tracks.toMutableMap().apply {
            remove(previous.uri)
            put(updated.uri, updated)
        }
        val pending = snapshot.pending.filterNot { it.previous.uri == previous.uri }
        val rename = recorded
            ?: PendingLocalMusicRename(UUID.randomUUID().toString(), previous, name)
        val changes = snapshot.unacknowledged + uriChanges(rename, updated.uri)
        index.write(key, snapshot.copy(tracks = tracks, pending = pending, unacknowledged = changes,
            moves = if (recorded != null) snapshot.moves.verifiedRename(recorded.previous, updated) else snapshot.moves))
        if (recorded != null && (updated.visibilityProof != recorded.previous.visibilityProof || oldUri != newUri)) {
            val provider = updated.visibilityProof
            val visibility = updated.visibilityKey
            if (provider != null && visibility != null) {
                descriptorVisibilityProof(newUri)?.let { file ->
                    try {
                        visibilityArchive.retain(LocalMusicVisibilityAlias(visibility, provider, file))
                    } catch (_: IOException) {
                        // A visibility archive failure cannot roll back an actual rename.
                    }
                }
            }
        }
        return channelValue(updated, key)
    }

    private fun uriChanges(rename: PendingLocalMusicRename, newUri: String): List<LocalMusicUriChange> =
        buildList {
            if (rename.previous.uri != newUri) add(LocalMusicUriChange(rename.id, rename.previous.uri, newUri))
            val old = rename.equivalentDocument?.let(Uri::parse) ?: return@buildList
            val new = externalStorageDocument(Uri.parse(newUri)) ?: return@buildList
            if (old == new) return@buildList
            val oldId = DocumentsContract.getDocumentId(old)
            val newId = DocumentsContract.getDocumentId(new)
            for (grant in context.contentResolver.persistedUriPermissions) {
                val tree = grant.uri
                if (!grant.isReadPermission || tree.authority != EXTERNAL_STORAGE_PROVIDER ||
                    !DocumentsContract.isTreeUri(tree)) continue
                val treeId = DocumentsContract.getTreeDocumentId(tree)
                if (!containsDocument(treeId, oldId) || !containsDocument(treeId, newId)) continue
                val from = DocumentsContract.buildDocumentUriUsingTree(tree, oldId).toString()
                val to = DocumentsContract.buildDocumentUriUsingTree(tree, newId).toString()
                val id = UUID.nameUUIDFromBytes("${rename.id}:$from:$to".toByteArray()).toString()
                add(LocalMusicUriChange(id, from, to))
            }
        }

    private fun externalStorageDocument(mediaUri: Uri): Uri? {
        return try {
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
                MediaStore.getDocumentUri(context, mediaUri)?.takeIf {
                    it.authority == EXTERNAL_STORAGE_PROVIDER && DocumentsContract.isDocumentUri(context, it)
                }
            } else {
                legacyExternalStorageDocument(mediaUri)
            }
        } catch (_: Exception) {
            null
        }
    }

    @Suppress("DEPRECATION")
    private fun legacyExternalStorageDocument(mediaUri: Uri): Uri? {
        val resolver = context.contentResolver
        val trees = resolver.persistedUriPermissions.filter {
            it.isReadPermission && it.uri.authority == EXTERNAL_STORAGE_PROVIDER &&
                DocumentsContract.isTreeUri(it.uri)
        }
        if (trees.isEmpty()) return null
        val path = resolver.query(mediaUri, arrayOf(MediaStore.MediaColumns.DATA), null, null, null)?.use {
            if (it.moveToFirst()) it.getString(0) else null
        } ?: return null
        val primary = Environment.getExternalStorageDirectory().canonicalPath + File.separator
        val canonical = File(path).canonicalPath
        if (!canonical.startsWith(primary)) return null
        val documentId = "primary:${canonical.removePrefix(primary)}"
        val mediaStat = resolver.openFileDescriptor(mediaUri, "r")?.use { Os.fstat(it.fileDescriptor) }
            ?: return null
        for (grant in trees) {
            val tree = grant.uri
            if (!containsDocument(DocumentsContract.getTreeDocumentId(tree), documentId)) continue
            val candidate = DocumentsContract.buildDocumentUriUsingTree(tree, documentId)
            val documentStat = runCatching {
                resolver.openFileDescriptor(candidate, "r")?.use { Os.fstat(it.fileDescriptor) }
            }.getOrNull() ?: continue
            if (mediaStat.st_dev == documentStat.st_dev && mediaStat.st_ino == documentStat.st_ino) {
                return DocumentsContract.buildDocumentUri(EXTERNAL_STORAGE_PROVIDER, documentId)
            }
        }
        return null
    }

    fun pendingRenames(source: Uri): List<Map<String, String>> =
        index.read(source.toString()).unacknowledged.map {
            mapOf("id" to it.id, "oldUri" to it.oldUri, "newUri" to it.newUri)
        }

    fun acknowledgeRename(source: Uri, old: Uri, new: Uri, id: String? = null) {
        val key = source.toString()
        val snapshot = index.read(key)
        val remaining = snapshot.unacknowledged.toMutableList()
        val match = remaining.indexOfFirst {
            (id == null || it.id == id) && it.oldUri == old.toString() && it.newUri == new.toString()
        }
        if (match < 0) return
        remaining.removeAt(match)
        index.write(key, snapshot.copy(unacknowledged = remaining))
    }

    fun clearIndex() = index.clear()

    private data class ScannedFolder(val id: String, val locations: List<LocalMusicFolderLocation>)

    private fun scanFolder(
        tree: Uri, signal: CancellationSignal, notificationUris: MutableSet<Uri>,
        adjacentArtwork: LocalMusicAdjacentCovers?, cues: LocalMusicCueTracks?,
        isDocumentProvider: Boolean, report: LocalMusicScanReport?,
        collect: (LocalMusicRow) -> Unit,
    ): Boolean {
        val root = DocumentsContract.getTreeDocumentId(tree)
        val authority = requireNotNull(tree.authority)
        val source = tree.toString()
        val directories = ArrayDeque<ScannedFolder>()
        val seen = hashSetOf(root)
        val rootLabel = rootFolderName(tree, root, signal)
        directories.add(ScannedFolder(root, listOfNotNull(safMusicFolderLocation(source, root, rootLabel, null))))
        var incomplete = false
        while (directories.isNotEmpty()) {
            signal.throwIfCanceled()
            val folder = directories.removeFirst()
            val id = folder.id
            val children = DocumentsContract.buildChildDocumentsUriUsingTree(tree, id)
            if (id != root && notificationUris.size < LocalMusicScanWatcher.MAX_NOTIFICATION_URIS) {
                // A cross-process cursor may omit its notification URI.
                notificationUris.add(DocumentsContract.buildChildDocumentsUri(authority, id))
            }
            val covers = adjacentArtwork?.let { LocalMusicAdjacentCoverCandidates<LocalMusicCoverDocument>() }
            var containsAudio = false
            val complete = readFolderChildren(children, signal, id == root || isDocumentProvider) {
                if (notificationUris.size < LocalMusicScanWatcher.MAX_NOTIFICATION_URIS) {
                    folderNotificationUri(it, tree, authority, id)?.let(notificationUris::add)
                }
                if (it.extras.getBoolean(DocumentsContract.EXTRA_LOADING, false) ||
                    it.extras.containsKey(DocumentsContract.EXTRA_ERROR)) throw IOException()
                while (it.moveToNext()) {
                    signal.throwIfCanceled()
                    val child = it.getString(0)?.takeIf(String::isNotBlank)
                    if (child == null && report == null) continue
                    val name = it.getString(1)?.takeIf(String::isNotBlank)
                    if (name == null && report == null) continue
                    val mime = it.getString(2).orEmpty()
                    if (child == null || name == null) {
                        if (mime != Document.MIME_TYPE_DIR && report != null &&
                            audioKind(mime, name.orEmpty()) != AudioKind.OTHER) {
                            report.add(name, LocalMusicSkipReason.MISSING_DETAILS)
                        }
                        continue
                    }
                    if (!seen.add(child)) continue
                    if (mime == Document.MIME_TYPE_DIR) {
                        cues?.addDirectory(id, name, child)
                        val location = if (folder.locations.size in 1 until MAX_LOCAL_MUSIC_FOLDER_DEPTH &&
                            it.getType(1) == Cursor.FIELD_TYPE_STRING)
                            safMusicFolderLocation(source, child, name, folder.locations.last()) else null
                        directories.addLast(ScannedFolder(child,
                            location?.let { folder.locations + it } ?: emptyList()))
                    } else if (name.endsWith(".cue", ignoreCase = true)) {
                        cues?.addSheet(id, name, child)
                    } else {
                        val kind = audioKind(mime, name)
                        if (kind != AudioKind.AUDIO) {
                            if (kind != AudioKind.OTHER) report?.add(name, kind.rejection)
                            covers?.add(name, mime) {
                                LocalMusicCoverDocument(
                                    DocumentsContract.buildDocumentUriUsingTree(tree, child),
                                    it.numeric(Document.COLUMN_SIZE),
                                )
                            }
                            continue
                        }
                        val flags = it.numeric(Document.COLUMN_FLAGS) ?: 0L
                        if (isDocumentProvider && !providerOffersAudioStream(flags)) {
                            val reason = if (flags and Document.FLAG_PARTIAL.toLong() != 0L) {
                                LocalMusicSkipReason.MISSING_DETAILS
                            } else {
                                LocalMusicSkipReason.UNSUPPORTED_TYPE
                            }
                            report?.add(name, reason)
                            continue
                        }
                        containsAudio = true
                        val uri = DocumentsContract.buildDocumentUriUsingTree(tree, child).toString()
                        val modified = it.numeric(Document.COLUMN_LAST_MODIFIED)?.takeIf { value -> value > 0 }
                        val size = it.numeric(Document.COLUMN_SIZE)
                        collect(LocalMusicRow(
                            uri = uri,
                            fileName = name,
                            addedMs = 0,
                            modifiedMs = modified,
                            sizeBytes = size,
                            firstSeen = true,
                            canRename = !isDocumentProvider && flags and Document.FLAG_SUPPORTS_RENAME.toLong() != 0L,
                            canEditTags = !isDocumentProvider && tree.authority == EXTERNAL_STORAGE_PROVIDER && isMp3Name(name) &&
                                flags and Document.FLAG_SUPPORTS_WRITE.toLong() != 0L,
                            parentDocumentId = id,
                            parentKey = id,
                            visibilityProof = documentVisibilityProof(uri, modified, size),
                            folderLocations = folder.locations,
                        ))
                    }
                }
            }
            if (containsAudio && covers != null) adjacentArtwork?.addFolder(id, covers)
            if (!complete) incomplete = true
        }
        return incomplete
    }

    private inline fun readFolderChildren(
        children: Uri, signal: CancellationSignal, isRoot: Boolean, read: (Cursor) -> Unit,
    ): Boolean {
        try {
            val cursor = try {
                context.contentResolver.query(children, arrayOf(
                    Document.COLUMN_DOCUMENT_ID, Document.COLUMN_DISPLAY_NAME, Document.COLUMN_MIME_TYPE,
                    Document.COLUMN_LAST_MODIFIED, Document.COLUMN_SIZE, Document.COLUMN_FLAGS,
                ), null, null, null, signal) ?: throw IOException()
            } catch (missing: FileNotFoundException) {
                // A directory removed during traversal is a verified absence.
                if (isRoot) throw missing
                return true
            }
            cursor.use(read)
            return true
        } catch (cancelled: OperationCanceledException) {
            throw cancelled
        } catch (failure: Exception) {
            if (isRoot) throw failure
            return false
        }
    }

    private fun folderNotificationUri(cursor: Cursor, tree: Uri, authority: String, id: String): Uri? {
        val actual = try { cursor.notificationUri } catch (_: RuntimeException) { null } ?: return null
        return actual.takeIf {
            it == DocumentsContract.buildDocumentUri(authority, id) ||
                (it.scheme == tree.scheme && it.authority == authority &&
                    it.pathSegments.take(2) == tree.pathSegments)
        }
    }

    private fun rootFolderName(tree: Uri, root: String, signal: CancellationSignal): String? = try {
        val document = DocumentsContract.buildDocumentUriUsingTree(tree, root)
        context.contentResolver.query(document, arrayOf(Document.COLUMN_DISPLAY_NAME), null, null, null, signal)
            ?.use {
                if (it.extras.getBoolean(DocumentsContract.EXTRA_LOADING, false) ||
                    it.extras.containsKey(DocumentsContract.EXTRA_ERROR) ||
                    !it.moveToFirst() || it.getType(0) != Cursor.FIELD_TYPE_STRING) null
                else it.getString(0)
            }
    } catch (cancelled: OperationCanceledException) {
        throw cancelled
    } catch (_: Exception) {
        // The display label is optional, and discovering media does not depend on it.
        null
    }

    private fun scanMediaStore(
        source: Uri, signal: CancellationSignal, report: LocalMusicScanReport?,
        collect: (LocalMusicRow) -> Unit,
    ) {
        val columns = mutableListOf(
            Audio._ID, Audio.DISPLAY_NAME, Audio.MIME_TYPE, Audio.SIZE, Audio.DATE_ADDED,
            Audio.DATE_MODIFIED, Audio.TITLE, Audio.ARTIST, Audio.ALBUM, Audio.ALBUM_ID, Audio.DURATION,
            Audio.TRACK,
        )
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q) {
            columns.add(MediaStore.MediaColumns.VOLUME_NAME)
            columns.add(MediaStore.MediaColumns.RELATIVE_PATH)
        } else {
            @Suppress("DEPRECATION")
            columns.add(MediaStore.MediaColumns.DATA)
        }
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.R) {
            columns.add(MediaStore.MediaColumns.GENERATION_ADDED)
        }
        val versions = mutableMapOf<String, String?>()
        val locationsByVolume = mutableMapOf<String, MutableMap<String, List<LocalMusicFolderLocation>>>()
        val cursor = queryMediaStore(source, columns, signal)
        cursor.use {
            val recordingColumn =
                if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.S) it.getColumnIndex(Audio.IS_RECORDING) else -1
            val volumeColumn = it.getColumnIndex(MediaStore.MediaColumns.VOLUME_NAME)
            val pathColumn = it.getColumnIndex(MediaStore.MediaColumns.RELATIVE_PATH)
            while (it.moveToNext()) {
                signal.throwIfCanceled()
                val id = it.numeric(Audio._ID)
                if (id == null && report == null) continue
                val name = it.string(MediaStore.MediaColumns.DISPLAY_NAME)
                if (id == null || name == null) {
                    report?.add(name, LocalMusicSkipReason.MISSING_DETAILS)
                    continue
                }
                val kind = audioKind(it.string(MediaStore.MediaColumns.MIME_TYPE).orEmpty(), name)
                if (kind != AudioKind.AUDIO) {
                    report?.add(name, kind.rejection)
                    continue
                }
                val added = mediaStoreTime(it.numeric(MediaStore.MediaColumns.DATE_ADDED))
                val collection: Uri
                val parent: String?
                val volume: String
                val locations: List<LocalMusicFolderLocation>
                if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q) {
                    val reportedVolume = it.string(MediaStore.MediaColumns.VOLUME_NAME)
                    if (reportedVolume == null) {
                        report?.add(name, LocalMusicSkipReason.MISSING_DETAILS)
                        continue
                    }
                    volume = reportedVolume
                    collection = Audio.getContentUri(volume)
                    val relative = if (pathColumn >= 0 && volumeColumn >= 0 &&
                        it.getType(pathColumn) == Cursor.FIELD_TYPE_STRING &&
                        it.getType(volumeColumn) == Cursor.FIELD_TYPE_STRING) it.getString(pathColumn) else null
                    parent = relative?.let { "$volume:$it" }
                    locations = if (relative == null) emptyList() else
                        locationsByVolume.getOrPut(volume) { mutableMapOf() }.getOrPut(relative) {
                            mediaMusicFolderLocations(volume, relative)
                        }
                } else {
                    volume = "external"
                    collection = source
                    @Suppress("DEPRECATION")
                    parent = it.string(MediaStore.MediaColumns.DATA)?.let { path -> File(path).parent }
                    locations = emptyList()
                }
                if (!versions.containsKey(volume)) versions[volume] = mediaVersion(volume)
                val uri = ContentUris.withAppendedId(collection, id).toString()
                val modified = mediaStoreTime(it.numeric(Audio.DATE_MODIFIED))
                val size = it.numeric(Audio.SIZE)
                // Android encodes the disc and track as (disc * 1000) + track.
                val position = it.numeric(Audio.TRACK) ?: 0
                collect(LocalMusicRow(
                    uri = uri,
                    fileName = name,
                    addedMs = added ?: 0L,
                    modifiedMs = modified,
                    sizeBytes = size,
                    firstSeen = added == null,
                    canRename = true,
                    canEditTags = isMp3Name(name),
                    parentDocumentId = null,
                    parentKey = parent,
                    mediaAlbumId = it.numeric(Audio.ALBUM_ID),
                    visibilityProof = mediaVisibilityProof(uri, versions[volume],
                        it.numeric(MediaStore.MediaColumns.GENERATION_ADDED), added, modified, size),
                    isRecording = recordingColumn >= 0 && it.getType(recordingColumn).let { type ->
                        positiveRecordingFlag(type, if (type == Cursor.FIELD_TYPE_INTEGER) it.getLong(recordingColumn) else null)
                    },
                    folderLocations = locations,
                    metadata = LocalMusicMetadata(
                        title = it.string(Audio.TITLE)
                            ?.takeUnless { text -> text == fallbackTitle(name) || text == name },
                        artist = it.string(Audio.ARTIST),
                        album = it.string(Audio.ALBUM),
                        durationMs = it.numeric(Audio.DURATION) ?: 0L,
                        discNumber = (position / 1000).takeIf { number -> number in 1..0xffff }?.toInt(),
                        trackNumber = (position % 1000).takeIf { number -> number > 0 }?.toInt(),
                    ),
                ))
            }
        }
    }

    private fun queryMediaStore(source: Uri, columns: List<String>, signal: CancellationSignal): Cursor {
        val resolver = context.contentResolver
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.S) {
            // Some platform providers reject an optional column even on API 31+.
            val recordingCursor = try {
                resolver.query(source, (columns + Audio.IS_RECORDING).toTypedArray(), null, null, null, signal)
            } catch (cancelled: OperationCanceledException) {
                throw cancelled
            } catch (denied: SecurityException) {
                throw denied
            } catch (_: RuntimeException) {
                null
            }
            if (recordingCursor != null) return recordingCursor
        }
        return resolver.query(source, columns.toTypedArray(), null, null, null, signal) ?: throw IOException()
    }

    private fun mediaVersion(volume: String): String? = try {
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q) MediaStore.getVersion(context, volume)
        else MediaStore.getVersion(context)
    } catch (_: RuntimeException) {
        // A disconnected volume no longer provides identity.
        null
    }

    private fun readVisibilityProof(source: Uri, uri: Uri): String? = try {
        val resolver = context.contentResolver
        if (source.toString() == SYSTEM_URI) {
            val volume = uri.pathSegments.first()
            val version = mediaVersion(volume)
            val columns = mutableListOf(Audio.DATE_ADDED, Audio.DATE_MODIFIED, Audio.SIZE)
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.R) {
                columns.add(MediaStore.MediaColumns.GENERATION_ADDED)
            }
            resolver.query(uri, columns.toTypedArray(), null, null, null)?.use {
                if (!it.moveToFirst()) return@use null
                mediaVisibilityProof(uri.toString(), version, it.numeric(MediaStore.MediaColumns.GENERATION_ADDED),
                    mediaStoreTime(it.numeric(Audio.DATE_ADDED)), mediaStoreTime(it.numeric(Audio.DATE_MODIFIED)),
                    it.numeric(Audio.SIZE))
            }
        } else {
            val columns = arrayOf(Document.COLUMN_LAST_MODIFIED, Document.COLUMN_SIZE)
            resolver.query(uri, columns, null, null, null)?.use {
                if (!it.moveToFirst()) return@use null
                documentVisibilityProof(uri.toString(), it.numeric(Document.COLUMN_LAST_MODIFIED),
                    it.numeric(Document.COLUMN_SIZE))
            }
        }
    } catch (_: RuntimeException) {
        null
    }

    private fun descriptorVisibilityProof(uri: Uri, signal: CancellationSignal? = null): String? = try {
        context.contentResolver.openFileDescriptor(uri, "r", signal)?.use { descriptor ->
            val stat = Os.fstat(descriptor.fileDescriptor)
            if (!OsConstants.S_ISREG(stat.st_mode) || stat.st_ino == 0L ||
                stat.st_nlink == 0L || stat.st_size <= 0L || stat.st_ctime <= 0L) return@use null
            val changeNanos =
                if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O_MR1) stat.st_ctim.tv_nsec else 0L
            localMusicVisibilityFingerprint("rename-descriptor", stat.st_dev.toString(), stat.st_ino.toString(),
                stat.st_ctime.toString(), changeNanos.toString(), stat.st_size.toString())
        }
    } catch (cancelled: OperationCanceledException) {
        throw cancelled
    } catch (_: Exception) {
        null
    }

    private fun readContentAdvisory(uri: Uri, signal: CancellationSignal): LocalMusicAdvisory? = try {
        context.contentResolver.openAssetFileDescriptor(uri, "r", signal)?.use { asset ->
            val length = asset.length.takeIf { it >= 0 }
            asset.createInputStream().use { input ->
                readLocalMusicContentAdvisory(
                    input, length,
                    seekForward = { bytes ->
                        try {
                            Os.lseek(asset.fileDescriptor, bytes, OsConstants.SEEK_CUR)
                            true
                        } catch (failure: ErrnoException) {
                            if (failure.errno != OsConstants.ESPIPE) throw IOException(failure)
                            false
                        }
                    },
                    checkCanceled = signal::throwIfCanceled,
                )
            }
        }
    } catch (cancelled: OperationCanceledException) {
        throw cancelled
    } catch (_: IOException) {
        null
    } catch (_: RuntimeException) {
        // Providers can allow browsing even when an individual file is unreadable.
        null
    }

    private fun readMetadata(uri: Uri, summary: LocalMusicMetadata?, signal: CancellationSignal): LocalMusicMetadata? {
        var metadata: LocalMusicMetadata? = null
        try {
            readMedia(uri) { retriever ->
                fun tag(key: Int) = retriever.extractMetadata(key)?.trim()?.takeIf(String::isNotEmpty)?.take(1024)
                val mime = tag(MediaMetadataRetriever.METADATA_KEY_MIMETYPE)
                val id3 = if (mime == "audio/mpeg" || mime == "audio/mp3") {
                    readLocalId3Dates { context.contentResolver.openInputStream(uri) }
                } else null
                // MP4 DATE can be the container creation time. Its music date
                // tag (©day) is exposed as YEAR instead.
                val commentDate = when (mime) {
                    "audio/flac", "audio/ogg", "application/ogg" ->
                        localReleaseDate(tag(MediaMetadataRetriever.METADATA_KEY_DATE))
                    else -> null
                }
                metadata = LocalMusicMetadata(
                    title = tag(MediaMetadataRetriever.METADATA_KEY_TITLE),
                    artist = tag(MediaMetadataRetriever.METADATA_KEY_ARTIST) ?: summary?.artist,
                    album = localCollectionTag(retriever.extractMetadata(MediaMetadataRetriever.METADATA_KEY_ALBUM)
                        ?: summary?.album),
                    albumArtist = localCollectionTag(retriever.extractMetadata(MediaMetadataRetriever.METADATA_KEY_ALBUMARTIST)),
                    discNumber = localAlbumPosition(tag(MediaMetadataRetriever.METADATA_KEY_DISC_NUMBER)) ?: summary?.discNumber,
                    trackNumber = localAlbumPosition(tag(MediaMetadataRetriever.METADATA_KEY_CD_TRACK_NUMBER)) ?: summary?.trackNumber,
                    releaseDate = id3?.release ?: commentDate
                        ?: localReleaseDate(tag(MediaMetadataRetriever.METADATA_KEY_YEAR)),
                    originalReleaseDate = id3?.original,
                    durationMs = tag(MediaMetadataRetriever.METADATA_KEY_DURATION)?.toLongOrNull()
                        ?.coerceAtLeast(0L) ?: summary?.durationMs ?: 0L,
                    genre = readGenre(retriever),
                    genreRead = true,
                    albumTagsRead = true,
                    coverReadDeferred = !loadCovers,
                )
                if (loadCovers) {
                    signal.throwIfCanceled()
                    retriever.embeddedPicture?.let {
                        signal.throwIfCanceled()
                        metadata = metadata?.copy(cover = artwork.store(it))
                    }
                }
            }
        } catch (cancelled: OperationCanceledException) {
            throw cancelled
        } catch (denied: SecurityException) {
            throw denied
        } catch (_: RuntimeException) {
            // A file can disappear, deny access or have unreadable metadata.
        } catch (_: IOException) {
            // A cover-cache failure must not prevent audio playback.
        }
        val loaded = metadata ?: return null
        signal.throwIfCanceled()
        val tags = try {
            context.contentResolver.openAssetFileDescriptor(uri, "r", signal)?.use { document ->
                document.createInputStream().use(::readLocalMusicTags)
            }
        } catch (cancelled: OperationCanceledException) {
            throw cancelled
        } catch (_: IOException) {
            null
        } catch (_: RuntimeException) {
            // Providers can support metadata retrieval without a readable stream.
            null
        }
        val replayGain = try {
            context.contentResolver.openAssetFileDescriptor(uri, "r", signal)?.use { file ->
                file.createInputStream().use(LocalReplayGainReader::read)
            }
        } catch (_: SecurityException) {
            return null
        } catch (cancelled: OperationCanceledException) {
            throw cancelled
        } catch (_: RuntimeException) {
            null
        } catch (_: IOException) {
            null
        }
        return loaded.copy(
            sortTags = tags?.sortTags, tagValues = tags?.values,
            replayGain = replayGain, replayGainRead = true,
        )
    }

    private fun repairCover(uri: Uri, cover: String, signal: CancellationSignal) {
        try {
            readMedia(uri) { retriever ->
                signal.throwIfCanceled()
                retriever.embeddedPicture?.let {
                    signal.throwIfCanceled()
                    artwork.store(it, expectedName = cover)
                }
            }
        } catch (cancelled: OperationCanceledException) {
            throw cancelled
        } catch (_: RuntimeException) {
            // A missing thumbnail must not make the indexed song unavailable.
        } catch (_: IOException) { }
    }

    private fun readGenre(retriever: MediaMetadataRetriever): String? =
        localCollectionTag(retriever.extractMetadata(MediaMetadataRetriever.METADATA_KEY_GENRE))

    private inline fun readMedia(uri: Uri, read: (MediaMetadataRetriever) -> Unit) {
        val retriever = MediaMetadataRetriever()
        try {
            retriever.setDataSource(context, uri)
            read(retriever)
        } finally {
            try { retriever.release() } catch (_: IOException) { }
        }
    }

    private fun channelValue(row: LocalMusicRow, source: String): Map<String, Any?> =
        if (loadCovers) {
            row.channelValue(row.metadata?.cover?.let(artwork::path), source,
                row.adjacentCover?.let(artwork::adjacentPath), tagSeparators)
        } else {
            row.channelValue(source = source, tagSeparators = tagSeparators)
        }

    private fun Cursor.numeric(name: String): Long? {
        val index = getColumnIndex(name)
        return if (index < 0 || isNull(index)) null else getLong(index).takeIf { it >= 0 }
    }

    private fun Cursor.string(name: String): String? {
        val index = getColumnIndex(name)
        return if (index < 0) null else getString(index)?.takeIf { it.isNotBlank() && it != "<unknown>" }
    }

    private class TrackBatch(private val publish: (List<Map<String, Any?>>) -> Unit) {
        private val rows = mutableListOf<Map<String, Any?>>()
        private var first = true

        fun add(row: Map<String, Any?>) {
            rows.add(row)
            if (first || rows.size == 16) flush()
        }

        fun flush() {
            if (rows.isEmpty()) return
            first = false
            publish(rows.toList())
            rows.clear()
        }
    }

    companion object {
        internal fun providerOffersAudioStream(flags: Long): Boolean =
            flags and (Document.FLAG_PARTIAL or Document.FLAG_VIRTUAL_DOCUMENT).toLong() == 0L

        const val SYSTEM_URI = "content://media/external/audio/media"
        private const val EXTERNAL_STORAGE_PROVIDER = "com.android.externalstorage.documents"

        private fun isMp3Name(name: String): Boolean = name.endsWith(".mp3", ignoreCase = true)

        internal fun containsDocument(treeId: String, documentId: String): Boolean {
            val treeVolume = treeId.substringBefore(':', "")
            val documentVolume = documentId.substringBefore(':', "")
            if (treeVolume.isEmpty() || treeVolume != documentVolume) return false
            val root = treeId.substringAfter(':').trimEnd('/')
            val path = documentId.substringAfter(':')
            if (path.split('/').any { it.isEmpty() || it == "." || it == ".." }) return false
            return root.isEmpty() || path.startsWith("$root/")
        }

        internal fun mediaStoreTime(seconds: Long?): Long? =
            seconds?.takeIf { it in 1..(Long.MAX_VALUE / 1000) }?.times(1000)

        // Some SAF providers use paths as document IDs. Require provider
        // revision and size as well as the selected tree's document ID.
        internal fun documentVisibilityProof(uri: String, modified: Long?, size: Long?): String? =
            if (modified != null && modified > 0 && size != null && size > 0)
                localMusicVisibilityFingerprint("document", uri, modified.toString(), size.toString())
            else null

        internal fun mediaVisibilityProof(
            uri: String, version: String?, generation: Long?, added: Long?, modified: Long?, size: Long?,
        ): String? {
            if (version.isNullOrBlank()) return null
            // A generation is meaningful only within the same database version and volume.
            if (generation != null && generation > 0) {
                return localMusicVisibilityFingerprint("media-generation", uri, version, generation.toString(),
                    modified.orEmpty(), size.orEmpty())
            }
            if (added == null || added <= 0 || modified == null || modified <= 0 || size == null || size <= 0) {
                return null
            }
            return localMusicVisibilityFingerprint("media-legacy", uri, version, added.toString(), modified.toString(),
                size.toString())
        }

        private fun Long?.orEmpty() = this?.toString().orEmpty()

        private fun newIdentityKey(): String =
            MessageDigest.getInstance("SHA-256").digest(UUID.randomUUID().toString().toByteArray())
                .joinToString("") { "%02x".format(Locale.ROOT, it) }

        private val audioExtensions = setOf("mp3", "m4a", "m4b", "aac", "flac", "ogg", "oga", "opus",
            "wav", "aif", "aiff", "amr", "wma", "mka", "mid", "midi", "caf", "alac")
        private val playlistExtensions = setOf("m3u", "m3u8", "mpd", "pls", "xspf", "asx", "ism", "sdp")
        internal fun audioKind(mime: String, name: String): AudioKind {
            val type = mime.substringBefore(';').trim().lowercase(Locale.ROOT)
            val extension = name.substringAfterLast('.', "").lowercase(Locale.ROOT)
            if (extension in playlistExtensions || type.contains("mpegurl") || type == "audio/x-scpls") {
                return AudioKind.PLAYLIST
            }
            if (type.startsWith("audio/") || ((type.isEmpty() || type == "application/octet-stream" ||
                type == "application/ogg") && extension in audioExtensions)) return AudioKind.AUDIO
            return if (extension in audioExtensions) AudioKind.UNRECOGNIZED_AUDIO else AudioKind.OTHER
        }
        internal fun isAudio(mime: String, name: String): Boolean = audioKind(mime, name) == AudioKind.AUDIO
        internal fun fallbackTitle(name: String): String =
            name.substringBeforeLast('.').takeIf { it.isNotBlank() } ?: name
    }

    internal enum class AudioKind {
        AUDIO, PLAYLIST, UNRECOGNIZED_AUDIO, OTHER;

        val rejection: LocalMusicSkipReason
            get() = when (this) {
                PLAYLIST -> LocalMusicSkipReason.PLAYLIST
                UNRECOGNIZED_AUDIO, OTHER -> LocalMusicSkipReason.UNSUPPORTED_TYPE
                AUDIO -> error("Recognized audio is not a skipped file")
            }
    }
}

/** Repairs a few distinct, previously cached thumbnails after publishing playable rows. */
internal class LocalMusicCoverRepairs {
    private val missing = linkedMapOf<String, String>()
    val candidates: Map<String, String> get() = missing

    fun consider(row: LocalMusicRow, hasCoverFile: Boolean) {
        val cover = row.metadata?.cover ?: return
        if (!hasCoverFile && missing.size < 4) missing.putIfAbsent(cover, row.uri)
    }
}

/** Repeated album covers share one thumbnail. The current library's cache is bounded even during a scan. */
private class LocalMusicCovers(private val folder: File) {
    private val unused = folder.listFiles().orEmpty().filter { it.isFile }.sortedBy { it.lastModified() }.toMutableSet()
    private var cacheBytes = unused.sumOf { it.length() }

    fun path(name: String): String? = if (name.matches(NAME_PATTERN)) cachedPath(name) else null

    fun adjacentPath(name: String): String? =
        if (name.startsWith(ADJACENT_PREFIX) && name.removePrefix(ADJACENT_PREFIX).matches(NAME_PATTERN))
            cachedPath(name) else null

    private fun cachedPath(name: String): String? {
        val file = File(folder, name)
        if (!file.isFile) return null
        unused.remove(file)
        return file.absolutePath
    }

    fun store(bytes: ByteArray, expectedName: String? = null): String? =
        store(bytes, expectedName, adjacent = false)

    fun storeAdjacent(bytes: ByteArray): String? = store(bytes, null, adjacent = true)

    private fun store(bytes: ByteArray, expectedName: String?, adjacent: Boolean): String? {
        if (bytes.isEmpty() || bytes.size > LOCAL_MUSIC_COVER_MAX_BYTES) return null
        val digest = MessageDigest.getInstance("SHA-256").digest(bytes)
        val prefix = if (adjacent) ADJACENT_PREFIX else ""
        val file = File(folder, prefix +
            Base64.encodeToString(digest, Base64.NO_WRAP or Base64.NO_PADDING or Base64.URL_SAFE) + ".jpg")
        if (expectedName != null && file.name != expectedName) return null
        if (file.isFile) {
            unused.remove(file)
            return file.name
        }
        val options = BitmapFactory.Options().apply { inJustDecodeBounds = true }
        BitmapFactory.decodeByteArray(bytes, 0, bytes.size, options)
        if (options.outWidth <= 0 || options.outHeight <= 0) return null
        if (adjacent && (options.outMimeType !in localMusicAdjacentImageTypes ||
                maxOf(options.outWidth, options.outHeight) > 16_384 ||
                options.outWidth.toLong() * options.outHeight > 24_000_000L)) return null
        options.inJustDecodeBounds = false
        options.inSampleSize = 1
        val longestEdge = maxOf(options.outWidth, options.outHeight)
        if (adjacent) {
            // Sample to a bounded intermediate before scaling. Sampling straight
            // to the output cap would halve a cover just above that cap.
            while ((longestEdge - 1) / options.inSampleSize >= ADJACENT_MAX_EDGE * 2) {
                options.inSampleSize *= 2
            }
        } else {
            while (longestEdge / options.inSampleSize > 512) options.inSampleSize *= 2
        }
        val bitmap = BitmapFactory.decodeByteArray(bytes, 0, bytes.size, options) ?: return null
        val thumbnail = ByteArrayOutputStream()
        var picture = bitmap
        try {
            val decodedEdge = maxOf(bitmap.width, bitmap.height)
            if (adjacent && decodedEdge > ADJACENT_MAX_EDGE) {
                picture = Bitmap.createScaledBitmap(bitmap,
                    (bitmap.width * ADJACENT_MAX_EDGE / decodedEdge).coerceAtLeast(1),
                    (bitmap.height * ADJACENT_MAX_EDGE / decodedEdge).coerceAtLeast(1),
                    true)
            }
            if (!picture.compress(Bitmap.CompressFormat.JPEG, 85, thumbnail)) return null
        } finally {
            if (picture !== bitmap) picture.recycle()
            bitmap.recycle()
        }
        val old = unused.iterator()
        while (cacheBytes + thumbnail.size() > LocalMusicArtworkStorage.LIMIT_BYTES && old.hasNext()) {
            val stale = old.next()
            val size = stale.length()
            if (stale.delete()) cacheBytes -= size
            old.remove()
        }
        if (cacheBytes + thumbnail.size() > LocalMusicArtworkStorage.LIMIT_BYTES ||
            (!folder.isDirectory && !folder.mkdirs())) return null
        val temporary = File.createTempFile("cover-", ".tmp", folder)
        try {
            temporary.outputStream().use { thumbnail.writeTo(it) }
            if (!temporary.renameTo(file)) return null
            cacheBytes += thumbnail.size()
            return file.name
        } finally {
            temporary.delete()
        }
    }

    fun removeUnused() = unused.forEach { it.delete() }

    private companion object {
        const val ADJACENT_PREFIX = "adjacent-"
        const val ADJACENT_MAX_EDGE = 1024
        val NAME_PATTERN = Regex("[A-Za-z0-9_-]{43}\\.jpg")
    }
}
