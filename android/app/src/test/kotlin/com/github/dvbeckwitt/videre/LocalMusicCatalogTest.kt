package com.github.dvbeckwitt.videre

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

class LocalMusicCatalogTest {
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
