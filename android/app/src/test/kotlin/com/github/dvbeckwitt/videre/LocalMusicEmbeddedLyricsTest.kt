package com.github.dvbeckwitt.videre

import java.io.ByteArrayInputStream
import java.io.ByteArrayOutputStream
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Test

class LocalMusicEmbeddedLyricsTest {
    @Test fun readsLegacyAndUnicodeId3Lyrics() {
        val legacy = frame("ULT", bytes(0) + ascii("eng\u0000Café"), 2)
        assertEquals("Café", read(id3(2, legacy)))

        val littleEndian = bytes(1) + ascii("eng") + bytes(0xff, 0xfe) +
            "Description\u0000日本語".toByteArray(Charsets.UTF_16LE)
        val unrelated = frame("APIC", ByteArray(240), 3)
        assertEquals("日本語", read(id3(3, unrelated + frame("USLT", littleEndian, 3))))

        val lrc = "[offset:+125]\n[00:02.00]One line"
        assertEquals(lrc, read(id3(4, frame("USLT", plainId3(lrc), 4))))
    }

    @Test fun readsExplicitUserDefinedLyricsWhenStandardId3LyricsAreAbsent() {
        val unrelated = frame("TXXX", bytes(3) + ascii("NOTES\u0000Metadata value"), 4)
        val custom = frame("TXXX", bytes(3) + ascii("USLT\u0000Lyrics from an older FFmpeg"), 4)
        val standard = frame("USLT", plainId3("Standard lyrics"), 4)
        assertNull(read(id3(4, unrelated)))
        assertEquals("Lyrics from an older FFmpeg", read(id3(4, unrelated + custom)))
        assertEquals("Standard lyrics", read(id3(4, unrelated + custom + standard)))
    }

    @Test fun prefersMillisecondLyricsAndGroupsExplicitLines() {
        val synced = bytes(3) + ascii("eng") + bytes(2, 1, 0) +
            cue("First", 125) + cue(" line", 410) + cue("\nSecond", 60456) + cue(" line", 61302)
        val plain = frame("USLT", plainId3("Fallback"), 4)
        assertEquals("[00:00.125]First line\n[01:00.456]Second line",
            read(id3(4, plain + frame("SYLT", synced, 4))))

        val textTranscription = synced.copyOf().also { it[5] = 2 }
        val frameClock = synced.copyOf().also { it[4] = 1 }
        val truncated = synced.copyOf(synced.size - 1)
        for (invalid in listOf(textTranscription, frameClock, truncated)) {
            assertEquals("Fallback", read(id3(4, frame("SYLT", invalid, 4) + plain)))
        }
    }

    @Test fun reversesId3UnsynchronisationAndSkipsUnsupportedFrames() {
        val escaped = bytes(0) + ascii("eng\u0000A") + bytes(0xff, 0, 0xe1) + ascii("B")
        assertEquals("AÿáB", read(id3(4, frame("USLT", escaped, 4, 0x02))))

        // In ID3v2.3 the frame size precedes tag-level unsynchronisation.
        val tagFrame = frame("USLT", bytes(0) + ascii("eng\u0000AÿáB"), 3)
        val unsynchronised = tagFrame.copyOfRange(0, tagFrame.size - 9) + escaped
        assertEquals("AÿáB", read(id3(3, unsynchronised, 0x80)))

        val encrypted = frame("USLT", plainId3("Ignore"), 4, 0x04)
        val extendedHeader = synchsafe(6) + bytes(1, 0)
        assertEquals("Readable", read(id3(4, extendedHeader + encrypted +
            frame("USLT", plainId3("Readable"), 4), 0x40)))
    }

    @Test fun readsLyricsFromNativeFlacVorbisComments() {
        val comment = comments("TITLE=Wrong field", "lYrIcS=[offset:-125]\n[00:03]Actual lyrics")
        val streamInfo = bytes(0) + big(34, 3) + ByteArray(34)
        assertEquals("[offset:-125]\n[00:03]Actual lyrics",
            read(ascii("fLaC") + streamInfo + bytes(0x84) + big(comment.size, 3) + comment))
    }

    @Test fun readsVorbisOpusAndFlacCommentPacketsFromOgg() {
        val lyrics = "A line\nAnother line"
        val comment = comments("UNSYNCED LYRICS=$lyrics")
        val oggFlacComment = bytes(0x84) + big(comment.size, 3) + comment
        val pairs = listOf(
            ascii("\u0001vorbis") to (ascii("\u0003vorbis") + comment + bytes(1)),
            ascii("OpusHead") to (ascii("OpusTags") + comment),
            ascii("\u007FFLAC\u0001\u0000") to oggFlacComment,
        )
        for ((identification, tags) in pairs) {
            val first = oggPage(2, 11, 0, bytes(identification.size), identification)
            val second = oggPage(0, 11, 1, bytes(tags.size), tags)
            assertEquals(lyrics, read(first + second))
        }
    }

    @Test fun reassemblesOggPacketsOnlyWithinTheSameLogicalStream() {
        val lyric = "x".repeat(300)
        val identification = ascii("OpusHead")
        val tags = ascii("OpusTags") + comments("LYRICS=$lyric")
        val first = oggPage(2, 71, 0, bytes(identification.size), identification)
        val second = oggPage(0, 71, 1, bytes(255), tags.copyOfRange(0, 255))
        val other = oggPage(1, 72, 0, bytes(tags.size - 255), tags.copyOfRange(255, tags.size))
        val last = oggPage(1, 71, 2, bytes(tags.size - 255), tags.copyOfRange(255, tags.size))
        assertNull(read(first + second + other))
        assertEquals(lyric, read(first + second + other + last))
    }

    @Test fun readsShortVorbisLyricsAfterLargeCoverArtAndSkipsAnOversizedValue() {
        val comment = comments("METADATA_BLOCK_PICTURE=${"A".repeat(600_000)}",
            "LYRICS=${"A".repeat(600_000)}", "LYRICS=Small lyrics")
        val identification = ascii("OpusHead")
        val ogg = oggPage(2, 11, 0, bytes(identification.size), identification) +
            oggCommentPages(ascii("OpusTags") + comment)
        assertEquals("Small lyrics", read(ogg))
        val flac = ascii("fLaC") + bytes(0x84) + big(comment.size, 3) + comment
        assertEquals("Small lyrics", read(flac))
    }

    @Test fun readsItunesLyricAtomAfterMediaData() {
        val text = "日本語 lyrics"
        for ((type, encoding) in listOf(1 to Charsets.UTF_8, 2 to Charsets.UTF_16BE)) {
            val data = atom("data", big(type) + big(0) + text.toByteArray(encoding))
            val meta = atom("meta", big(0) + atom("ilst", atom("©lyr", data)))
            val file = atom("ftyp", ascii("M4A ") + big(0)) + atom("mdat", ByteArray(512)) +
                atom("moov", atom("udta", meta))
            assertEquals(text, read(file))
            val nonSeekableStream = object : ByteArrayInputStream(file) {
                override fun skip(count: Long): Long = 0
            }
            assertEquals(text, LocalMusicEmbeddedLyrics.read(nonSeekableStream))
        }
    }

    @Test fun malformedAndOversizedMetadataAreUnavailableAndLeaveInputOpen() {
        val badVorbisLength = big(-1) + big(0)
        val oversized = ascii("ID3") + bytes(4, 0, 0) + synchsafe(100 * 1024 * 1024)
        val truncated = id3(4, frame("USLT", plainId3("Lyrics"), 4)).dropLast(1).toByteArray()
        val invalidUtf8 = id3(4, frame("USLT", bytes(3) + ascii("eng\u0000") + bytes(0xff), 4))
        val targets = listOf(ascii("unknown"), oversized, truncated, invalidUtf8,
            ascii("fLaC") + bytes(0x84) + big(badVorbisLength.size, 3) + badVorbisLength,
            ascii("fLaC") + bytes(0x84) + big(5 * 1024 * 1024, 3))
        for (target in targets) {
            var closed = false
            val stream = object : ByteArrayInputStream(target) {
                override fun close() { closed = true }
            }
            assertNull(LocalMusicEmbeddedLyrics.read(stream))
            assertFalse(closed)
        }
    }

    private fun read(data: ByteArray): String? = LocalMusicEmbeddedLyrics.read(ByteArrayInputStream(data))

    private fun id3(version: Int, body: ByteArray, flags: Int = 0): ByteArray =
        ascii("ID3") + bytes(version, 0, flags) + synchsafe(body.size) + body

    private fun frame(id: String, data: ByteArray, version: Int, flags: Int = 0): ByteArray {
        val header = when (version) {
            2 -> big(data.size, 3)
            3 -> big(data.size) + bytes(0, flags)
            else -> synchsafe(data.size) + bytes(0, flags)
        }
        return ascii(id) + header + data
    }

    private fun plainId3(text: String): ByteArray = bytes(3) + ascii("eng\u0000") + text.toByteArray()

    private fun cue(text: String, millis: Int): ByteArray = text.toByteArray() + bytes(0) + big(millis)

    private fun comments(vararg comments: String): ByteArray {
        val vendor = ascii("Fixture")
        return little(vendor.size) + vendor + little(comments.size) +
            comments.fold(ByteArray(0)) { previous, comment ->
                val utf8 = comment.toByteArray()
                previous + little(utf8.size) + utf8
            }
    }

    private fun oggPage(flags: Int, serial: Int, sequence: Int, lacing: ByteArray, body: ByteArray): ByteArray =
        ascii("OggS") + bytes(0, flags) + ByteArray(8) + little(serial) + little(sequence) +
            ByteArray(4) + bytes(lacing.size) + lacing + body

    private fun oggCommentPages(packet: ByteArray): ByteArray {
        val pages = ByteArrayOutputStream()
        val maxPageSize = 255 * 255
        var position = 0
        var sequence = 1
        while (packet.size - position >= maxPageSize) {
            val lacing = ByteArray(255) { 255.toByte() }
            pages.write(oggPage(if (sequence == 1) 0 else 1, 11, sequence++, lacing,
                packet.copyOfRange(position, position + maxPageSize)))
            position += maxPageSize
        }
        val tail = packet.size - position
        val lacing = ByteArray(tail / 255) { 255.toByte() } + (tail % 255).toByte()
        pages.write(oggPage(if (sequence == 1) 0 else 1, 11, sequence, lacing, packet.copyOfRange(position, packet.size)))
        return pages.toByteArray()
    }

    private fun atom(type: String, data: ByteArray): ByteArray = big(data.size + 8) + ascii(type) + data

    private fun ascii(value: String): ByteArray = value.toByteArray(Charsets.ISO_8859_1)
    private fun bytes(vararg value: Int): ByteArray = ByteArray(value.size) { value[it].toByte() }
    private fun big(value: Int, size: Int = 4): ByteArray = ByteArray(size) { (value ushr ((size - 1 - it) * 8)).toByte() }
    private fun little(value: Int): ByteArray = big(value).reversedArray()
    private fun synchsafe(value: Int): ByteArray = ByteArray(4) { ((value ushr ((3 - it) * 7)) and 0x7F).toByte() }
}
