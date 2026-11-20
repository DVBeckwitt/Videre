package com.github.dvbeckwitt.videre

import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

class LocalMusicRenameTest {
    @Test
    fun preservesTheSourceExtension() {
        assertTrue(LocalMusicRename.validName("take.01.MP3", "Track 02.MP3"))
        assertTrue(LocalMusicRename.validName("Recording", "New recording"))
        assertFalse(LocalMusicRename.validName("take.01.MP3", "Track 02.mp3"))
        assertFalse(LocalMusicRename.validName("take.01.MP3", "Track 02.flac"))
    }

    @Test
    fun rejectsPathsAndInvalidFilenames() {
        assertFalse(LocalMusicRename.validName("song.mp3", "../song.mp3"))
        assertFalse(LocalMusicRename.validName("song.mp3", "..\\song.mp3"))
        assertFalse(LocalMusicRename.validName("song.mp3", "song\n.mp3"))
        assertFalse(LocalMusicRename.validName("song.mp3", ".mp3"))
        assertFalse(LocalMusicRename.validName("song", " New song"))
        assertFalse(LocalMusicRename.validName("song", "Playlist.m3u"))
        assertFalse(LocalMusicRename.validName("song.mp3", "é".repeat(126) + ".mp3"))
    }
}
