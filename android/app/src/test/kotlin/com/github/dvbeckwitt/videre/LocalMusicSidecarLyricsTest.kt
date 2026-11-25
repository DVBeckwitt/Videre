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
        assertEquals(emptyList<String>(), LocalMusicSidecarLyrics.candidates(
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

    private fun candidates(vararg siblings: Sibling) =
        LocalMusicSidecarLyrics.candidates(audio.id, audio.fileName, siblings.asSequence())

    private fun read(bytes: ByteArray): String? = LocalMusicSidecarLyrics.read(bytes.inputStream())
}
