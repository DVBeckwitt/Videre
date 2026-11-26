package com.github.dvbeckwitt.videre

import com.github.dvbeckwitt.videre.LocalMusicCatalog.AudioKind
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

class LocalMusicScanReportTest {
    @Test fun classificationDistinguishesPlaylistAndRejectedAudioFromUnrelatedDocuments() {
        assertEquals(AudioKind.AUDIO, LocalMusicCatalog.audioKind("application/octet-stream", "demo.FLAC"))
        assertEquals(AudioKind.PLAYLIST, LocalMusicCatalog.audioKind("audio/mpeg", "mix.m3u8"))
        assertEquals(AudioKind.PLAYLIST, LocalMusicCatalog.audioKind("application/x-mpegurl", "mix.txt"))
        assertEquals(AudioKind.UNRECOGNIZED_AUDIO, LocalMusicCatalog.audioKind("text/plain", "demo.flac"))
        assertEquals(AudioKind.OTHER, LocalMusicCatalog.audioKind("image/jpeg", "cover.jpg"))
    }

    @Test fun reportCapsNamedRowsWhileCountingEachSkip() {
        val report = LocalMusicScanReport()
        repeat(102) { report.add("mix.m3u", LocalMusicSkipReason.PLAYLIST) }

        val tracks = listOf(mapOf("fileName" to "song.flac"))
        val data = report.channelResult(tracks)
        val files = data.getValue("skippedFiles") as List<*>
        assertEquals(tracks, data.getValue("tracks"))
        assertEquals(102L, data.getValue("skippedCount"))
        assertEquals(100, files.size)
        assertTrue(files.all { it == mapOf("name" to "mix.m3u", "reason" to "playlist") })
        assertEquals(0L, LocalMusicScanReport().channelResult(emptyList()).getValue("skippedCount"))
    }

    @Test fun namesOmitPathsAndInvalidLabelsAndKeepCompleteCharacters() {
        val report = LocalMusicScanReport()
        val privateLabels = listOf(
            "content://provider/private/demo.mp3", "content:account", "a\\b.mp3", "/Music/demo.mp3", ".", "\u0000",
        )
        for (label in privateLabels) report.add(label, LocalMusicSkipReason.MISSING_DETAILS)
        val prefix = "a".repeat(159)
        report.add(prefix + "\uD83C\uDFB5.flac", LocalMusicSkipReason.UNSUPPORTED_TYPE)

        val files = report.channelResult(emptyList()).getValue("skippedFiles") as List<*>
        assertTrue(files.take(privateLabels.size).all {
            it == mapOf("name" to null, "reason" to "missingDetails")
        })
        assertEquals(mapOf("name" to prefix, "reason" to "unsupportedType"), files.last())
        assertFalse(files.toString().contains("private"))
    }
}
