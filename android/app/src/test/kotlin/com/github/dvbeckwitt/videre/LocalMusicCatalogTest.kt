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
}
