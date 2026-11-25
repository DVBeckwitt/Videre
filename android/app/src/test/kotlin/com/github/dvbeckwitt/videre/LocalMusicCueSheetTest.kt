package com.github.dvbeckwitt.videre

import java.nio.charset.Charset
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Test

class LocalMusicCueSheetTest {
    @Test fun readsAlbumAndTrackTagsWithOffsetsRelativeToEachFile() {
        val sheet = parse(
            """
            REM GENRE Rock
            TITLE "Concert album"
            PERFORMER "House Band"
            file "Disc One\concert.flac" WAVE
              track 01 audio
                TITLE "Opening"
                INDEX 00 00:00:00
                INDEX 01 00:00:01
              TRACK 02 AUDIO
                TITLE Next Song
                PERFORMER "Guest"
                INDEX 00 00:01:60
                INDEX 01 00:01:74
            FILE encore.mp3 MP3
              TRACK 03 AUDIO
                INDEX 01 00:00:00
            """,
        )!!
        assertEquals("Concert album", sheet.title)
        assertEquals("House Band", sheet.performer)
        assertEquals(
            listOf(
                LocalMusicCueFile(
                    listOf("Disc One", "concert.flac"),
                    listOf(
                        LocalMusicCueTrack(1, "Opening", null, 13_333, 1_986_666),
                        LocalMusicCueTrack(2, "Next Song", "Guest", 1_986_666, null),
                    ),
                ),
                LocalMusicCueFile(listOf("encore.mp3"), listOf(LocalMusicCueTrack(3, null, null, 0, null))),
            ),
            sheet.files,
        )
    }

    @Test fun stopsBeforeDataAndSkipsRawDiscImages() {
        val parsed = parse(
            """
            FILE first.wav WAVE
              TRACK 01 AUDIO
                INDEX 01 00:00:00
              TRACK 02 MODE1/2352
                INDEX 00 01:20:00
                INDEX 01 01:22:00
              TRACK 03 AUDIO
                INDEX 01 02:00:00
            FILE raw.bin BINARY
              TRACK 04 AUDIO
                INDEX 01 00:00:00
            """,
        )!!
        assertEquals(
            listOf(
                LocalMusicCueTrack(1, null, null, 0, 80_000_000),
                LocalMusicCueTrack(3, null, null, 120_000_000, null),
            ),
            parsed.files.single().tracks,
        )
    }

    @Test fun rejectsMalformedFileRangesWhileKeepingSeparateValidFiles() {
        for (indexes in listOf(
            "INDEX 00 00:00:20",
            "INDEX 01 00:00:75",
            "INDEX 01 00:60:00",
            "INDEX 01 00:00:09",
            "INDEX 01 00:00:10",
            "INDEX 01 00:02:00\nINDEX 01 00:03:00",
        )) {
            val sheet = parse(
                """
                FILE invalid.wav WAVE
                  TRACK 01 AUDIO
                    INDEX 01 00:00:10
                  TRACK 02 AUDIO
                    ${indexes.replace("\n", "\n                    ")}
                FILE valid.wav WAVE
                  TRACK 03 AUDIO
                    INDEX 01 00:00:15
                """,
            )!!
            assertEquals(listOf("valid.wav"), sheet.files.single().relativePath)
            assertEquals(200_000L, sheet.files.single().tracks.single().startUs)
        }
        assertNull(parse("""
            FILE one.wav WAVE
              TRACK 01 AUDIO
                INDEX 01 00:00:00
              TRACK 01 AUDIO
                INDEX 01 00:01:00
        """))
    }

    @Test fun rejectsUnsafeAndAmbiguousFilePaths() {
        for (path in listOf(
            "../album.flac", "disc/../album.flac", "./album.flac", "disc//album.flac",
            "C:\\Music\\album.flac", "/Music/album.flac", "\\server\\album.flac",
            "https://example.invalid/song.flac", "content://provider/song.flac",
        )) {
            assertNull(path, parse("FILE \"$path\" WAVE\nTRACK 01 AUDIO\nINDEX 01 00:00:00"))
        }
        assertNull(parse("""
            FILE "disc/album.flac" WAVE
              TRACK 01 AUDIO
                INDEX 01 00:00:00
            FILE "disc\album.flac" WAVE
              TRACK 02 AUDIO
                INDEX 01 00:01:00
        """))
    }

    @Test fun decodesBomAndLegacyTextAndBoundsInput() {
        val text = "TITLE \"Café\"\r\nFILE \"Café.wav\" WAVE\r\nTRACK 01 AUDIO\r\nINDEX 01 00:00:00"
        for (encoded in listOf(
            ("\uFEFF" + text).toByteArray(Charsets.UTF_8),
            text.toByteArray(Charsets.UTF_16),
            text.toByteArray(Charset.forName("windows-1252")),
        )) {
            val sheet = LocalMusicCueSheet.parse(encoded.inputStream())!!
            assertEquals("Café", sheet.title)
            assertEquals(listOf("Café.wav"), sheet.files.single().relativePath)
        }
        assertNull(parse(text + ("\nREM PADDING".repeat(25_000))))
        assertNull(parse(text + "\nREM " + "a".repeat(4096)))
    }

    private fun parse(text: String): LocalMusicCueSheet? =
        LocalMusicCueSheet.parse(text.trimIndent().toByteArray().inputStream())
}
