package com.github.dvbeckwitt.videre

import com.github.dvbeckwitt.videre.LocalMusicSidecarLyrics.Sibling
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Test

class LocalMusicSidecarLyricsTest {
    private val audio = Sibling("recording", "Song.mp3", audio = true)
    private val exact = Sibling("exact", "Song.mp3.LRC", audio = false)
    private val stem = Sibling("stem", "Song.lrc", audio = false)

    @Test fun `uses the exact filename first and then the same stem`() {
        assertEquals(listOf("exact", "stem"), candidates(
            stem, Sibling("case mismatch", "song.mp3.lrc", audio = false), audio, exact,
        ))
        assertEquals(listOf("stem"), candidates(audio, stem))
    }

    @Test fun `requires the same live audio document in the indexed directory`() {
        assertEquals(emptyList<String>(), candidates(audio.copy(id = "replacement"), stem, exact))
        assertEquals(emptyList<String>(), candidates(audio.copy(fileName = "New name.mp3"), exact))
        assertEquals(emptyList<String>(), candidates(audio, audio.copy(id = "duplicate name"), exact))
    }

    @Test fun `rejects an ambiguous stem and a duplicate sidecar independently`() {
        val otherFormat = Sibling("other format", "Song.flac", audio = true)
        assertEquals(listOf("exact"), candidates(audio, exact, stem, otherFormat))
        assertEquals(emptyList<String>(), candidates(audio, stem, otherFormat))
        assertEquals(listOf("stem"), candidates(
            audio, exact, exact.copy(id = "duplicate", fileName = "Song.mp3.lrc"), stem,
        ))
    }

    @Test fun `reserves a sidecar for the recording with the matching full filename`() {
        val longerName = Sibling("second", "Song.mp3.flac", audio = true)
        assertEquals(emptyList<LocalMusicSidecarLyrics.Candidate>(), LocalMusicSidecarLyrics.candidates(
            longerName.id, longerName.fileName, sequenceOf(audio, longerName, exact),
        ))
    }

    @Test fun `decodes UTF-8 and BOM-marked UTF-16 and preserves plain or timed text`() {
        val timed = "[offset:-350]\r\n[00:04.2]Ça va"
        assertEquals(timed, read(timed.toByteArray(Charsets.UTF_8)))
        assertEquals(timed, read(byteArrayOf(-17, -69, -65) + timed.toByteArray(Charsets.UTF_8)))
        val plain = "歌詞\n🌙"
        assertEquals(plain, read(byteArrayOf(-1, -2) + plain.toByteArray(Charsets.UTF_16LE)))
        assertEquals(plain, read(byteArrayOf(-2, -1) + plain.toByteArray(Charsets.UTF_16BE)))
    }

    @Test fun `rejects empty corrupt binary and oversized content`() {
        assertNull(read(byteArrayOf()))
        assertNull(read(" \n\t".toByteArray()))
        assertNull(read(byteArrayOf(-61, 40)))
        assertNull(read(byteArrayOf(-1, -2, 65)))
        assertNull(read(byteArrayOf(65, 0, 66)))
        assertNull(read(ByteArray(LocalMusicSidecarLyrics.MAX_BYTES + 1) { 65 }))
        assertNull(read("x".repeat(128 * 1024 + 1).toByteArray()))
        assertEquals(128 * 1024, read("歌".repeat(128 * 1024).toByteArray())?.length)
    }

    @Test fun `orders formats within each filename and isolates ambiguous extensions`() {
        val timedText = Sibling("full TTML", "Song.mp3.TTML", false)
        val subtitle = Sibling("full SRT", "Song.mp3.srt", false)
        val stemTimedText = Sibling("stem TTML", "Song.ttml", false)
        assertEquals(
            listOf("full TTML", "full SRT", "exact", "stem TTML", "stem"),
            candidates(stemTimedText, exact, stem, subtitle, audio, timedText),
        )
        assertEquals(
            listOf("full SRT", "exact"),
            candidates(audio, timedText, timedText.copy(id = "duplicate", fileName = "Song.mp3.ttml"),
                stemTimedText, subtitle, exact, audio.copy(id = "other", fileName = "Song.flac")),
        )
    }

    @Test fun `skips an invalid TTML and returns a bilingual SRT with the legacy LRC field`() {
        val available = mapOf(
            "ttml" to "<tt>unfinished",
            "srt" to "1\r\n00:00:01,250 --> 00:00:03,000\r\n<i>- Good night</i>\r\n- Bonne nuit",
            "stem" to "[00:01.25]Legacy line",
        )
        val siblings = sequenceOf(
            stem, audio, Sibling("srt", "Song.mp3.SRT", false), Sibling("ttml", "Song.mp3.ttml", false),
        )
        val resolved = LocalMusicSidecarLyrics.readCandidates(
            LocalMusicSidecarLyrics.candidates(audio.id, audio.fileName, siblings),
        ) { available[it]?.byteInputStream() }
        assertEquals(
            mapOf(
                "sidecar" to available["stem"],
                "timedSidecar" to listOf(
                    mapOf("startMs" to 1250L, "endMs" to 3000L, "text" to "- Good night\n- Bonne nuit"),
                ),
            ),
            resolved,
        )
    }

    @Test fun `rejects invalid SubRip intervals and skips a malformed file`() {
        val subtitle = Sibling("srt", "Song.mp3.srt", false)
        val candidates = LocalMusicSidecarLyrics.candidates(audio.id, audio.fileName, sequenceOf(audio, subtitle, stem))
        for (malformed in listOf(
            "1\n00:18:42,999 --> 00:18:42,998\nReverse interval",
            "1\n00:16:60,000 --> 00:18:42,000\nInvalid seconds",
            "1\n00:00:01,000 --> 00:00:02,000\n<b></b>",
        )) {
            val resolved = LocalMusicSidecarLyrics.readCandidates(candidates) {
                (if (it == subtitle.id) malformed else "Fallback line").byteInputStream()
            }
            assertEquals(mapOf("sidecar" to "Fallback line"), resolved)
        }
    }

    private fun candidates(vararg siblings: Sibling) =
        LocalMusicSidecarLyrics.candidates(audio.id, audio.fileName, siblings.asSequence()).map { it.id }

    private fun read(bytes: ByteArray): String? = LocalMusicSidecarLyrics.read(bytes.inputStream())
}
