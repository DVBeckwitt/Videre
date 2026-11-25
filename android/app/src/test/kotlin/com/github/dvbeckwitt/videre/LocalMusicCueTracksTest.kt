package com.github.dvbeckwitt.videre

import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Test

class LocalMusicCueTracksTest {
    @Test fun resolvesOnlyUnambiguousAudioBelowTheSheetDirectory() {
        val directories = mapOf(
            ("sheet folder" to "Disc") to listOf("opaque child"),
            ("sheet folder" to "Duplicate") to listOf("first child", "second child"),
        )
        val audio = mapOf<Pair<String?, String>, List<String>>(
            ("opaque child" to "album.wav") to listOf("granted album"),
            ("different folder" to "album.wav") to listOf("another album"),
            ("sheet folder" to "ambiguous.wav") to listOf("first album", "second album"),
            ("first child" to "album.wav") to listOf("ambiguous directory album"),
        )
        assertEquals("granted album", resolveCueAudio("sheet folder", listOf("Disc", "album.wav"), directories, audio))
        assertNull(resolveCueAudio("sheet folder", listOf("album.wav"), directories, audio))
        assertNull(resolveCueAudio("sheet folder", listOf("ambiguous.wav"), directories, audio))
        assertNull(resolveCueAudio("sheet folder", listOf("Duplicate", "album.wav"), directories, audio))
        assertNull(resolveCueAudio("sheet folder", listOf("Disc", "missing.wav"), directories, audio))
    }

    @Test fun boundsTracksAgainstTheActualMediaDuration() {
        val bounded = LocalMusicCueTrack(1, null, null, 13_333L, 1_026_666L)
        assertEquals(1_013_333L, cuePlaybackDurationUs(bounded, 1_500_000L))
        assertEquals(473_334L, cuePlaybackDurationUs(bounded.copy(startUs = 1_026_666L, endUs = null), 1_500_000L))
        assertNull(cuePlaybackDurationUs(bounded, 900_000L))
        assertNull(cuePlaybackDurationUs(bounded.copy(startUs = 1_500_000L, endUs = null), 1_500_000L))
    }
}
