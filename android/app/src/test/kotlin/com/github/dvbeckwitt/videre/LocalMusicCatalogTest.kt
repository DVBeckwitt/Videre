package com.github.dvbeckwitt.videre

import android.database.Cursor
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

class LocalMusicCatalogTest {
    @Test fun onlyPositiveIntegerMediaStoreRecordingMetadataIsActionable() {
        assertTrue(positiveRecordingFlag(Cursor.FIELD_TYPE_INTEGER, 1L))
        assertTrue(positiveRecordingFlag(Cursor.FIELD_TYPE_INTEGER, 2L))
        assertFalse(positiveRecordingFlag(Cursor.FIELD_TYPE_INTEGER, null))
        assertFalse(positiveRecordingFlag(Cursor.FIELD_TYPE_INTEGER, 0L))
        assertFalse(positiveRecordingFlag(Cursor.FIELD_TYPE_INTEGER, -1L))
        assertFalse(positiveRecordingFlag(Cursor.FIELD_TYPE_STRING, 1L))
        assertFalse(positiveRecordingFlag(Cursor.FIELD_TYPE_FLOAT, 1L))
        assertFalse(positiveRecordingFlag(Cursor.FIELD_TYPE_NULL, null))
    }

    @Test fun mediaStoreFolderLocationsUseWholeSegmentsWithinTheReportedVolume() {
        val volume = "external_primary"
        val nested = mediaMusicFolderLocations(volume, "Music/Live/Jazz/")
        assertEquals(listOf("Internal storage / Music", "Internal storage / Music / Live",
            "Internal storage / Music / Live / Jazz"), nested.map { it.label })
        assertEquals(nested.take(2), mediaMusicFolderLocations(volume, "Music/Live/"))
        assertEquals(nested, mediaMusicFolderLocations(volume, "Music/Live/Jazz"))
        assertFalse(nested[1].key == mediaMusicFolderLocations(volume, "Music/Live2/").last().key)
        assertFalse(nested.last().key == mediaMusicFolderLocations("abcd-1234", "Music/Live/Jazz/").last().key)
        assertFalse(nested.last().key == mediaMusicFolderLocations(volume, "Music/Studio/Jazz/").last().key)
        assertTrue(nested.all { it.key.matches(Regex("[a-f0-9]{64}")) })
    }

    @Test fun malformedOrUnavailableStorageFolderMetadataHasNoExclusionKey() {
        for (path in listOf(null, "", "/", "/Music", "Music/../Jazz", "Music/./Jazz", "Music//Jazz",
            "Music/Jazz//", "Music\\Jazz", "Music/Hidden\n", "Music/<unknown>")) {
            assertTrue(mediaMusicFolderLocations("external_primary", path).isEmpty())
        }
        assertTrue(mediaMusicFolderLocations("external", "Music/").isEmpty())
        assertTrue(mediaMusicFolderLocations("internal", "Music/").isEmpty())
        assertTrue(mediaMusicFolderLocations("bad/volume", "Music/").isEmpty())
    }

    @Test fun safFolderChoicesFollowTraversalAndTreatTheDocumentIdAsOpaque() {
        val tree = "content://provider/tree/grant"
        val root = safMusicFolderLocation(tree, "grant", "Selected folder", null)!!
        val parents = listOf("opaque:left" to "Music", "opaque:right" to "Recordings").map { (id, label) ->
            safMusicFolderLocation(tree, id, label, root)!!
        }
        val first = safMusicFolderLocation(tree, "doc:one/path", "Jazz", parents[0])!!
        val second = safMusicFolderLocation(tree, "doc:two/path", "Jazz", parents[1])!!
        assertEquals("Selected folder / Music / Jazz", first.label)
        assertEquals("Selected folder / Recordings / Jazz", second.label)
        assertFalse(first.key == second.key)
        assertFalse(first.key == safMusicFolderLocation("$tree-other", "doc:one/path", "Jazz", parents[0])!!.key)
        assertEquals(first.key, safMusicFolderLocation(tree, "doc:one/path", "New label", parents[0])!!.key)
        assertEquals(null, safMusicFolderLocation(tree, "doc:bad", "Some/Folder", root))
        assertEquals(null, safMusicFolderLocation(tree, "doc:bad", null, root))
    }

    @Test fun documentAlbumsRequireTheSameTreeParentAndActualAlbumArtist() {
        val tree = "content://documents/tree/library"
        val metadata = LocalMusicMetadata("One", "Guest", "Greatest Hits", 12, albumArtist = "Ensemble")
        val first = track().copy(metadata = metadata)
        val key = first.albumKey(tree)!!
        assertTrue(key.matches(Regex("[0-9a-f]{64}")))
        assertEquals(key, first.copy(metadata = metadata.copy(artist = "Another guest")).albumKey(tree))
        assertFalse(key == first.copy(metadata = metadata.copy(albumArtist = "Solo")).albumKey(tree))
        assertFalse(key == first.copy(metadata = metadata.copy(album = "Other release")).albumKey(tree))
        assertFalse(key == first.copy(parentDocumentId = "edition two").albumKey(tree))
        assertFalse(key == first.albumKey("content://documents/tree/elsewhere"))
        assertEquals(null, first.copy(metadata = metadata.copy(albumArtist = null)).albumKey(tree))
        assertEquals(null, first.copy(metadata = metadata.copy(album = "<unknown>")).albumKey(tree))
        assertEquals(null, first.copy(parentDocumentId = null).albumKey(tree))
    }

    @Test fun systemAlbumsUseTheMediaStoreIdWithinItsVolume() {
        val source = LocalMusicCatalog.SYSTEM_URI
        val first = track().copy(uri = "content://media/vol_a/audio/media/7", mediaAlbumId = 5,
            metadata = LocalMusicMetadata("Song", "Solo", "Collection", 12))
        val key = first.albumKey(source)!!
        assertEquals(key, first.copy(uri = "content://media/vol_a/audio/media/19").albumKey(source))
        assertFalse(key == first.copy(uri = "content://media/vol_b/audio/media/7").albumKey(source))
        assertFalse(key == first.copy(mediaAlbumId = 12).albumKey(source))
        assertEquals(null, first.copy(mediaAlbumId = null).albumKey(source))
        assertEquals(null, first.copy(mediaAlbumId = 0).albumKey(source))
    }

    @Test fun legacyTagRecordsRefreshOnceEvenWhenTheNewAlbumTagsAreAbsent() {
        val tags = LocalMusicMetadata("Title", "Artist", "Album", 12, albumTagsRead = true)
        val row = track().copy(metadata = tags)
        assertTrue(row.needsTagRead(row.copy(metadata = tags.copy(albumTagsRead = false))))
        assertFalse(row.needsTagRead(row))
        assertTrue(row.copy(sizeBytes = 50L).needsTagRead(row))
        assertTrue(row.copy(identityKey = "replacement").needsTagRead(row))
    }

    @Test fun onlyAnUninterruptedFolderSelectionRetainsItsSessions() {
        fun choose(previous: String?, same: Boolean = true, readable: Boolean = true, lost: Boolean = false) =
            LocalMusicPlugin.selectionIdForPick(previous, same, readable, lost)
        assertEquals(null, choose(null)) // continuous legacy grant
        assertEquals("existing", choose("existing"))
        val fresh = listOf(choose(null, same = false), choose("existing", same = false),
            choose("existing", readable = false), choose("existing", lost = true))
        assertTrue(fresh.all { it != null && it != "existing" })
        assertEquals(fresh.size, fresh.toSet().size)
    }

    @Test fun recognizesAudioWithIncompleteProviderMetadata() {
        assertTrue(LocalMusicCatalog.isAudio("audio/mpeg", "Recording"))
        assertTrue(LocalMusicCatalog.isAudio("application/octet-stream", "Song.FLAC"))
        assertTrue(LocalMusicCatalog.isAudio("application/ogg", "Song.opus"))
        assertFalse(LocalMusicCatalog.isAudio("image/jpeg", "Song.mp3"))
        assertFalse(LocalMusicCatalog.isAudio("", "cover.jpg"))
    }

    @Test fun playlistsWithExternalReferencesAreNotLocalTracks() {
        assertFalse(LocalMusicCatalog.isAudio("audio/x-mpegurl", "Playlist"))
        assertFalse(LocalMusicCatalog.isAudio("audio/x-scpls", "Radio"))
        assertFalse(LocalMusicCatalog.isAudio("audio/mpeg", "radio.M3U8"))
        assertFalse(LocalMusicCatalog.isAudio("audio/mp4", "radio.mpd"))
    }

    @Test fun missingTagsFallBackToFilename() {
        assertEquals("01. First Song", LocalMusicCatalog.fallbackTitle("01. First Song.flac"))
        assertEquals("Recording", LocalMusicCatalog.fallbackTitle("Recording"))
        assertEquals(".mp3", LocalMusicCatalog.fallbackTitle(".mp3"))
    }

    @Test fun timestampAndSizeIdentifyAReusableMetadataEntry() {
        val row = track()
        assertTrue(row.matchesRevision(row))
        assertFalse(row.matchesRevision(row.copy(modifiedMs = 20L)))
        assertFalse(row.matchesRevision(row.copy(sizeBytes = 30L)))
        assertFalse(row.copy(modifiedMs = null).matchesRevision(row.copy(modifiedMs = null)))
        assertEquals(2000L, LocalMusicCatalog.mediaStoreTime(2L))
        assertEquals(null, LocalMusicCatalog.mediaStoreTime(0L))
    }

    @Test fun documentVisibilityRequiresAnAuthorizedRevision() {
        fun proof(uri: String = "content://documents/tree/source/document/one",
            modified: Long? = 123L, length: Long? = 12L) =
            LocalMusicCatalog.documentVisibilityProof(uri, modified, length)
        val initial = proof()!!
        assertTrue(initial.matches(Regex("[0-9a-f]{64}")))
        assertEquals(initial, proof())
        assertFalse(initial == proof(uri = "content://documents/tree/source/document/two"))
        assertFalse(initial == proof(uri = "content://documents/tree/other/document/one"))
        assertFalse(initial == proof(modified = 124L))
        assertFalse(initial == proof(length = 13L))
        assertEquals(null, proof(modified = 0L))
        assertEquals(null, proof(length = null))
    }

    @Test fun mediaVisibilityIncludesTheStoreVersionVolumeAndInsertion() {
        fun proof(uri: String = "content://media/volume_a/audio/media/7", version: String? = "store",
            generation: Long? = 3L, added: Long? = 100L, modified: Long? = 200L, size: Long? = 30L) =
            LocalMusicCatalog.mediaVisibilityProof(uri, version, generation, added, modified, size)
        val initial = proof()!!
        assertTrue(initial.matches(Regex("[0-9a-f]{64}")))
        assertEquals(initial, proof())
        assertFalse(initial == proof(uri = "content://media/volume_b/audio/media/7"))
        assertFalse(initial == proof(uri = "content://media/volume_a/audio/media/8"))
        assertFalse(initial == proof(version = "replacement-store"))
        assertFalse(initial == proof(generation = 7L))
        assertFalse(initial == proof(modified = 201L))
        assertEquals(null, proof(version = null))
        val legacy = proof(generation = null)!!
        assertFalse(legacy == proof(generation = null, added = 102L))
        assertEquals(null, proof(generation = null, added = null))
        assertEquals(null, proof(generation = null, modified = null))
    }

    @Test fun onlyAnUnchangedProofOrVerifiedRenameKeepsTheHiddenAlias() {
        val original = track().copy(visibilityProof = "old-provider-proof")
        val destination = track().copy(uri = "destination", visibilityProof = "destination-provider-proof")
        assertEquals("old-provider-proof", original.visibilityKey)
        assertEquals("destination-provider-proof", destination.inheritsVisibility(original).visibilityKey)

        val renamed = destination.inheritsVisibility(original, confirmedRename = true)
        assertEquals("old-provider-proof", renamed.visibilityKey)
        assertEquals("old-provider-proof", destination.inheritsVisibility(renamed).visibilityKey)
        assertEquals("replacement-proof",
            destination.copy(visibilityProof = "replacement-proof").inheritsVisibility(renamed).visibilityKey)
        assertEquals(null, destination.copy(visibilityProof = null)
            .inheritsVisibility(renamed, confirmedRename = true).visibilityKey)
    }

    @Test fun reapprovalChecksOnlyArchivedProofsAndRejectsReusedFiles() {
        val renamed = LocalMusicVisibilityAlias("original-proof", "renamed-proof", "same-file")
        val archive = LocalMusicVisibilityAliases(listOf(renamed))
        val unrelated = track().copy(visibilityProof = "unrelated-proof")
        assertEquals("unrelated-proof", archive.resolve(unrelated) { error("Unexpected descriptor") }.visibilityKey)

        val target = track().copy(visibilityProof = renamed.providerProof)
        assertEquals(renamed.key, archive.resolve(target) { renamed.fileProof }.visibilityKey)
        assertEquals(null, archive.resolve(target) { null }.visibilityKey)
        val replacement = archive.resolve(target.copy(visibilityAlias = renamed.key)) { "replacement-file" }
        assertFalse(replacement.visibilityKey == renamed.key)
        assertEquals(replacement.visibilityKey, archive.resolve(target) { "replacement-file" }.visibilityKey)

        val reusedOldUri = track().copy(visibilityProof = renamed.key)
        assertEquals(null, archive.resolve(reusedOldUri) { null }.visibilityKey)
        val otherFile = archive.resolve(reusedOldUri) { "another-file" }.visibilityKey
        assertFalse(renamed.key == otherFile)
        assertFalse(replacement.visibilityKey == otherFile)
    }

    @Test fun chainedRenameArchivesOnlyTheLatestTargetIncludingBackToItsOriginalUri() {
        val first = LocalMusicVisibilityAlias("original-proof", "first-target", "first-ctime")
        val journal = LocalMusicVisibilityAliases(listOf(first))
        val second = first.copy(providerProof = "second-target", fileProof = "second-ctime")
        val afterSecond = LocalMusicVisibilityAliases(journal.replacing(second))
        val dismissed = track().copy(visibilityProof = first.providerProof)
        assertEquals(first.providerProof, afterSecond.resolve(dismissed) { error("Old target still archived") }.visibilityKey)
        val latest = track().copy(visibilityProof = second.providerProof)
        assertEquals(second.key, afterSecond.resolve(latest) { second.fileProof }.visibilityKey)

        val returned = second.copy(providerProof = second.key, fileProof = "third-ctime")
        val afterReturn = LocalMusicVisibilityAliases(afterSecond.replacing(returned))
        val original = track().copy(visibilityProof = returned.providerProof)
        assertEquals(returned.key, afterReturn.resolve(original) { returned.fileProof }.visibilityKey)
        assertFalse(returned.key == afterReturn.resolve(original) { "replacement-file" }.visibilityKey)
    }

    @Test fun chainedRenamesPreserveTheOriginalQueueIdentity() {
        val original = track()
        val firstRename = original.copy(uri = "second", fileName = "second.flac")
            .inheritsIdentity(original)
        val secondRename = firstRename.copy(uri = "third", fileName = "third.flac")
            .inheritsIdentity(firstRename)
        assertEquals(original.uri, secondRename.identityUri)
        assertEquals(null, secondRename.copy(uri = original.uri).inheritsIdentity(secondRename).identityUri)
        assertEquals("salted", secondRename.inheritsIdentity(original.copy(identityKey = "salted")).identityKey)
    }

    @Test fun interruptedRenameCannotAdoptAFileFromAnotherDirectoryOrWithDifferentBytes() {
        val original = track()
        val pending = PendingLocalMusicRename("change", original, "renamed.flac")
        val renamed = original.copy(uri = "renamed", fileName = "renamed.flac")
        assertTrue(pending.matches(renamed))
        assertFalse(pending.matches(renamed.copy(parentKey = "elsewhere")))
        assertFalse(pending.matches(renamed.copy(sizeBytes = 40L)))
        assertFalse(pending.matches(renamed.copy(modifiedMs = null)))
        assertFalse(pending.matches(original))
        assertTrue(pending.replacedAtOldPath(original.copy(sizeBytes = 40L)))
        assertFalse(pending.replacedAtOldPath(renamed))
    }

    @Test fun interruptedRenameDistinguishesSameSizeReplacementAndDeclinesAmbiguousFiles() {
        val original = track()
        val pending = PendingLocalMusicRename("change", original, "renamed.flac")
        val renamed = original.copy(uri = "renamed", fileName = "renamed.flac")
        val replacement = original.copy(modifiedMs = 40L)
        assertTrue(pending.replacedAtOldPath(replacement))
        assertEquals(renamed, pending.recover(replacement, sequenceOf(renamed)))
        assertEquals(null, pending.recover(original, sequenceOf(renamed)))
        assertFalse(pending.originalStillAtOldPath(original, hasTarget = true))
        assertTrue(pending.originalStillAtOldPath(original, hasTarget = false))
        assertEquals(null, pending.recover(null, sequenceOf(renamed, renamed.copy(uri = "other"))))
    }

    @Test fun coverRecoveryReadsAtMostFourMissingDigestsAndSharesArtwork() {
        val repairs = LocalMusicCoverRepairs()
        repairs.consider(track(), hasCoverFile = false)
        fun consider(uri: String, cover: String, hasCover: Boolean = false) {
            repairs.consider(track().copy(uri = uri, metadata = LocalMusicMetadata(null, null, null, 0, cover)),
                hasCoverFile = hasCover)
        }
        consider("cached", "already-available", hasCover = true)
        consider("first", "shared")
        consider("duplicate", "shared")
        for (index in 1..8) consider("song-$index", "cover-$index")
        assertEquals(mapOf("shared" to "first", "cover-1" to "song-1", "cover-2" to "song-2",
            "cover-3" to "song-3"), repairs.candidates)
    }

    @Test fun providerRenameAliasesOnlyUseTheSameAuthorizedTree() {
        assertTrue(LocalMusicCatalog.containsDocument("primary:Music", "primary:Music/Videre/song.flac"))
        assertTrue(LocalMusicCatalog.containsDocument("primary:", "primary:Music/song.flac"))
        assertFalse(LocalMusicCatalog.containsDocument("primary:Music", "secondary:Music/song.flac"))
        assertFalse(LocalMusicCatalog.containsDocument("primary:Music", "primary:Music2/song.flac"))
        assertFalse(LocalMusicCatalog.containsDocument("primary:Music", "primary:Music/../song.flac"))
        assertFalse(LocalMusicCatalog.containsDocument("primary:Music", "primary:Music"))
    }

    private fun track() = LocalMusicRow(
        uri = "original",
        fileName = "original.flac",
        addedMs = 1L,
        modifiedMs = 2L,
        sizeBytes = 3L,
        firstSeen = true,
        canRename = true,
        parentDocumentId = "folder",
        parentKey = "folder",
    )
}
