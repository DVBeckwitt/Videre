package com.github.dvbeckwitt.videre

import java.io.File
import java.io.RandomAccessFile
import java.nio.file.Files
import org.junit.Assert.assertArrayEquals
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertSame
import org.junit.Assert.assertThrows
import org.junit.Assert.assertTrue
import org.junit.Test

class LocalMusicId3Test {
    @Test
    fun replacesOnlyTheMatchingPlainLyricsFrame() {
        val title = textFrame("TIT2", "Title")
        val spanish = lyricsFrame("spa", "Studio", "Letra previa")
        val live = lyricsFrame("eng", "Live", "Live lyrics")
        val studio = lyricsFrame("eng", "Studio", "Old studio lyrics")
        val timed = frame("SYLT", byteArrayOf(3) + ascii("eng") + byteArrayOf(2, 1, 0) +
            ascii("Timed line") + byteArrayOf(0, 0, 0, 0, 50))
        val original = tag(4, 256, title, spanish, studio, live, timed)
        val audio = byteArrayOf(0xff.toByte(), 0xfb.toByte(), 0x90.toByte(), 0x64)
        val originalFile = original + audio
        val text = "夏 ♪\nSecond line"

        val edited = LocalMusicId3.edit(original, emptyMap(), LocalMusicUslt.Edit("eng", "Studio", text))
        val editedFile = originalFile.copyOf().apply { edited.copyInto(this) }
        val expected = title + spanish + lyricsFrame("eng", "Studio", text) + live + timed

        assertEquals(original.size, edited.size)
        assertArrayEquals(expected, edited.copyOfRange(10, 10 + expected.size))
        assertArrayEquals(audio, editedFile.copyOfRange(original.size, editedFile.size))
    }

    @Test
    fun replacesId3v23Utf16LyricsAndPreservesAnEmptyDescriptor() {
        val title = textFrame("TIT2", "Title", version = 3)
        val prefix = byteArrayOf(1) + ascii("eng")
        val terminator = byteArrayOf(0, 0)
        val littleEndianBom = byteArrayOf(0xff.toByte(), 0xfe.toByte())
        val old = frame("USLT", prefix + littleEndianBom + terminator + littleEndianBom +
            "Old lyrics".toByteArray(Charsets.UTF_16LE), version = 3)
        val original = tag(3, 256, title, old)
        val text = "東京\n第二行"

        val edited = LocalMusicId3.edit(original, emptyMap(), LocalMusicUslt.Edit("eng", "", text))
        val bigEndianBom = byteArrayOf(0xfe.toByte(), 0xff.toByte())
        val expected = title + frame("USLT", prefix + terminator + bigEndianBom +
            text.toByteArray(Charsets.UTF_16BE), version = 3)

        assertEquals(original.size, edited.size)
        assertArrayEquals(expected, edited.copyOfRange(10, 10 + expected.size))
        assertEquals(0.toByte(), edited[10 + expected.size])
    }

    @Test
    fun refusesPlainLyricsWithoutPaddingForANewFrame() {
        val other = lyricsFrame("spa", "Studio", "Letra previa")
        val original = tag(4, 0, other)
        val before = original.copyOf()

        assertThrows(LocalMusicId3.NoSpace::class.java) {
            LocalMusicId3.edit(original, emptyMap(), LocalMusicUslt.Edit("eng", "Studio", "New lyrics"))
        }
        assertArrayEquals(before, original)
    }

    @Test
    fun editsTextWithinTheOriginalRangeAndKeepsOtherFramesByteForByte() {
        val oldTitle = textFrame("TIT2", "Old title")
        val artist = frame("TPE1", byteArrayOf(1, 0xff.toByte(), 0xfe.toByte(), 0x41, 0, 0, 0))
        val picture = frame("APIC", byteArrayOf(0) + ascii("image/png") + byteArrayOf(0, 3, 0, 0xcf.toByte()))
        val opaque = frame("XABC", ByteArray(176) { it.toByte() }, status = 0x30)
        val comment = frame("COMM", byteArrayOf(3) + ascii("eng") + byteArrayOf(0) + ascii("Studio take"))
        val album = textFrame("TALB", "Old album")
        val original = tag(4, 500, oldTitle, picture, artist, opaque, album, comment)
        val audioAndTrailingTag = byteArrayOf(0xff.toByte(), 0xfb.toByte(), 0x90.toByte(), 0x64) + ascii("TAG")
        val originalFile = original + audioAndTrailingTag

        val changed = LocalMusicId3.edit(original, mapOf("title" to "夏 ♪", "artist" to "A", "albumArtist" to "Band"))
        val replaced = originalFile.copyOf().apply { changed.copyInto(this) }

        assertEquals(original.size, LocalMusicId3.tagSize(changed.copyOf(10)))
        assertEquals(original.size, changed.size)
        assertEquals(
            mapOf(
                "title" to "夏 ♪", "artist" to "A", "album" to "Old album", "albumArtist" to "Band",
                "trackNumber" to null, "trackTotal" to null, "discNumber" to null, "discTotal" to null,
                "genre" to null, "releaseDate" to null,
            ),
            LocalMusicId3.inspect(changed),
        )
        val expectedFrames = textFrame("TIT2", "夏 ♪") + picture + artist + opaque + album + comment +
            textFrame("TPE2", "Band")
        assertArrayEquals(expectedFrames, changed.copyOfRange(10, 10 + expectedFrames.size))
        assertArrayEquals(audioAndTrailingTag, replaced.copyOfRange(original.size, replaced.size))
    }

    @Test
    fun usesVersionThreeFrameSizesAndUnicodeAndCanRemoveOneField() {
        val custom = frame("XABC", ByteArray(235) { 42 }, version = 3)
        val original = tag(3, 128, textFrame("TIT2", "Old", version = 3), custom,
            textFrame("TALB", "Album", version = 3))

        val output = LocalMusicId3.edit(original, mapOf("title" to "東京", "album" to null))

        assertEquals("東京", LocalMusicId3.inspect(output)["title"])
        assertNull(LocalMusicId3.inspect(output)["album"])
        assertArrayEquals(byteArrayOf(0, 0, 0, 7, 0, 0, 1, 0xfe.toByte(), 0xff.toByte()),
            output.copyOfRange(14, 23))
        assertArrayEquals(custom, output.copyOfRange(27, 27 + custom.size))
    }

    @Test
    fun unchangedValuesRetainTheirOriginalEncodingAndPadding() {
        val title = frame("TIT2", byteArrayOf(0) + ascii(" Original ") + byteArrayOf(0))
        val original = tag(4, 40, title)

        assertSame(original, LocalMusicId3.edit(original, mapOf("title" to " Original ", "album" to null)))
        assertEquals(" Original ", LocalMusicId3.inspect(original)["title"])
    }

    @Test
    fun editsOnePositionComponentAndKeepsOtherFramesInBothVersions() {
        for (version in 3..4) {
            val title = textFrame("TIT2", "Title", version)
            val picture = frame("APIC", byteArrayOf(0) + ascii("image/png") + byteArrayOf(0, 3, 0, 42), version)
            val disc = frame("TPOS", byteArrayOf(0) + ascii("01/002") + byteArrayOf(0), version)
            val untouched = title + picture + disc
            val original = tag(version, 32, title, picture, disc, textFrame("TRCK", "03/012", version))

            assertEquals("03", LocalMusicId3.inspect(original)["trackNumber"])
            assertSame(original, LocalMusicId3.edit(original, mapOf("trackNumber" to "03", "trackTotal" to "012")))

            val changed = LocalMusicId3.edit(original, mapOf("trackNumber" to "4"))
            val values = LocalMusicId3.inspect(changed)

            assertEquals(original.size, changed.size)
            assertArrayEquals(untouched, changed.copyOfRange(10, 10 + untouched.size))
            assertEquals("4", values["trackNumber"])
            assertEquals("012", values["trackTotal"])
            assertEquals("01", values["discNumber"])
            assertEquals("002", values["discTotal"])
        }
    }

    @Test
    fun updatesAndClearsTotalsAndCanAddOrRemoveAWholePosition() {
        val title = textFrame("TIT2", "Title")
        val original = tag(4, 48, title, textFrame("TRCK", "3/12"))

        val changed = LocalMusicId3.edit(original, mapOf(
            "trackTotal" to "16", "discNumber" to "2", "discTotal" to "2",
        ))
        val values = LocalMusicId3.inspect(changed)
        assertEquals("3", values["trackNumber"])
        assertEquals("16", values["trackTotal"])
        assertEquals("2", values["discNumber"])
        assertEquals("2", values["discTotal"])

        val cleared = LocalMusicId3.edit(changed, mapOf(
            "trackTotal" to null, "discNumber" to null, "discTotal" to null,
        ))
        val remaining = LocalMusicId3.inspect(cleared)
        assertEquals(original.size, cleared.size)
        assertEquals("3", remaining["trackNumber"])
        assertNull(remaining["trackTotal"])
        assertNull(remaining["discNumber"])
        assertNull(remaining["discTotal"])
        assertArrayEquals(title, cleared.copyOfRange(10, 10 + title.size))
        assertFalse("TPOS" in cleared.toString(Charsets.ISO_8859_1))
    }

    @Test
    fun fitsAnInPlaceFileWriteWithoutMovingAudioOrTrailingTags() {
        val original = tag(4, 64, textFrame("TIT2", "Title"), textFrame("TRCK", "3/12"))
        val mpegFrame = ByteArray(417) { 0x25 }.apply {
            byteArrayOf(0xff.toByte(), 0xfb.toByte(), 0x90.toByte(), 0x64).copyInto(this)
        }
        val audioAndTrailingTag = mpegFrame + mpegFrame + ascii("TAG") + ByteArray(125)
        val file = File.createTempFile("videre-id3-test-", ".mp3")
        try {
            file.writeBytes(original + audioAndTrailingTag)
            RandomAccessFile(file, "r").use { observer ->
                val before = ByteArray(original.size).also(observer::readFully)
                val edited = LocalMusicId3.edit(before, mapOf("trackNumber" to "10", "discNumber" to "2"))
                assertEquals(original.size, edited.size)
                RandomAccessFile(file, "rw").use { writer -> writer.write(edited) }

                assertEquals((original.size + audioAndTrailingTag.size).toLong(), observer.length())
                observer.seek(0)
                val prefix = ByteArray(original.size).also(observer::readFully)
                val suffix = ByteArray(audioAndTrailingTag.size).also(observer::readFully)
                assertEquals("10", LocalMusicId3.inspect(prefix)["trackNumber"])
                assertEquals("2", LocalMusicId3.inspect(prefix)["discNumber"])
                assertArrayEquals(audioAndTrailingTag, suffix)
            }
        } finally {
            Files.deleteIfExists(file.toPath())
        }
    }

    @Test
    fun rejectsInvalidPositionEditsWithoutMutatingInput() {
        val original = tag(4, 48, textFrame("TRCK", "3/12"))
        val before = original.copyOf()
        val invalid = listOf(
            mapOf("trackNumber" to "0"),
            mapOf("trackNumber" to "13"),
            mapOf("trackNumber" to null),
            mapOf("trackTotal" to "2"),
            mapOf("trackTotal" to " 12"),
            mapOf("discTotal" to "4"),
            mapOf("discNumber" to "+1"),
            mapOf("discNumber" to "١"),
            mapOf("discNumber" to "1/2"),
            mapOf("discNumber" to "65536"),
            mapOf("discNumber" to "000001"),
            mapOf("discNumber" to ""),
        )
        for (changes in invalid) {
            assertThrows(changes.toString(), LocalMusicId3.InvalidNumber::class.java) {
                LocalMusicId3.edit(original, changes)
            }
            assertArrayEquals(before, original)
        }
        val maximum = LocalMusicId3.edit(original, mapOf("discNumber" to "65535", "discTotal" to "65535"))
        assertEquals("65535", LocalMusicId3.inspect(maximum)["discTotal"])
    }

    @Test
    fun ambiguousPositionsStayOpaqueWhenEditingOtherFields() {
        val title = textFrame("TIT2", "Title")
        val track = textFrame("TRCK", "3/12")
        val opaquePositions = listOf(
            listOf(track, textFrame("TRCK", "4/12")),
            listOf(frame("TRCK", byteArrayOf(3) + ascii("3/12"), status = 0x10)),
            listOf(frame("TRCK", byteArrayOf(3) + ascii("3/12"), format = 0x02)),
            listOf(frame("TRCK", byteArrayOf(3, 0xc3.toByte(), 0x28))),
            listOf(frame("LINK", ascii("TRCKexample.com") + byteArrayOf(0))),
        )
        for (opaque in opaquePositions) {
            val original = tag(4, 48, *(opaque + title).toTypedArray())
            val expected = opaque.fold(byteArrayOf(), ByteArray::plus)
            val editableFields = LocalMusicId3.inspectEditable(original).editableFields
            assertFalse("trackNumber" in editableFields)
            assertFalse("trackTotal" in editableFields)
            assertTrue("discNumber" in editableFields)

            assertThrows(LocalMusicId3.Unsupported::class.java) {
                LocalMusicId3.edit(original, mapOf("trackNumber" to "5"))
            }
            val changed = LocalMusicId3.edit(original, mapOf("title" to "Edited", "discNumber" to "2"))
            val values = LocalMusicId3.inspect(changed)
            assertArrayEquals(expected, changed.copyOfRange(10, 10 + expected.size))
            assertEquals("Edited", values["title"])
            assertEquals("2", values["discNumber"])
        }
    }

    @Test
    fun retainsANonstandardPositionAndAllowsAnExplicitRepair() {
        val track = textFrame("TRCK", "0/12")
        val original = tag(4, 32, track, textFrame("TIT2", "Title"))

        val changed = LocalMusicId3.edit(original, mapOf("discNumber" to "2", "title" to "Edited"))

        assertArrayEquals(track, changed.copyOfRange(10, 10 + track.size))
        assertEquals("2", LocalMusicId3.inspect(changed)["discNumber"])
        val repair = LocalMusicId3.edit(changed, mapOf("trackNumber" to "3"))
        val values = LocalMusicId3.inspect(repair)
        assertEquals("3", values["trackNumber"])
        assertEquals("12", values["trackTotal"])
    }

    @Test
    fun rejectsAnEditThatExceedsExistingPaddingWithoutMutatingInput() {
        val original = tag(4, 0, textFrame("TIT2", "Short"))
        val before = original.copyOf()

        assertThrows(LocalMusicId3.NoSpace::class.java) {
            LocalMusicId3.edit(original, mapOf("title" to "Longer"))
        }
        assertThrows(LocalMusicId3.NoSpace::class.java) {
            LocalMusicId3.edit(original, mapOf("trackNumber" to "3", "trackTotal" to "12"))
        }
        assertThrows(LocalMusicId3.Unsupported::class.java) {
            LocalMusicId3.edit(original, mapOf("title" to null))
        }
        assertArrayEquals(before, original)
    }

    @Test
    fun rejectsAmbiguousAndMalformedTagsBeforeEditing() {
        val title = textFrame("TIT2", "Title")
        val malformed = listOf(
            tag(4, 8, title).copyOf(16),
            tag(4, 8, title).apply { this[5] = 0x40 },
            tag(4, 8, title).apply { this[6] = 0x80.toByte() },
            tag(4, 8, title).apply { this[lastIndex] = 1 },
            tag(4, 8, title).apply { this[17] = 0x7f },
            tag(4, 8, title, title),
            tag(4, 8, frame("TIT2", byteArrayOf(3, 0x41, 0, 0x42))),
            tag(4, 8, frame("TIT2", byteArrayOf(1, 0, 0x41))),
            tag(4, 8, frame("TIT2", byteArrayOf(3, 0xc3.toByte(), 0x28))),
            tag(4, 8, frame("TIT2", byteArrayOf(3, 0x41), status = 0x10)),
            tag(4, 8, frame("TIT2", byteArrayOf(3, 0x41), format = 0x02)),
            tag(4, 8, title, frame("XABC", byteArrayOf(0xff.toByte()), status = 0x40)),
            tag(4, 8, title, frame("LINK", ascii("TALBexample.com") + byteArrayOf(0))),
            tag(4, 8, title, frame("SEEK", byteArrayOf(0, 0, 0, 0))),
        )

        for (input in malformed) {
            val before = input.copyOf()
            assertThrows(LocalMusicId3.Unsupported::class.java) {
                LocalMusicId3.edit(input, mapOf("title" to "New"))
            }
            assertArrayEquals(before, input)
        }
    }

    @Test
    fun rejectsOutOfContractChangesAndAnOversizedTag() {
        val original = tag(4, 1024, textFrame("TIT2", "Title"))
        for (changes in listOf(mapOf("composer" to "Composer"), mapOf("title" to "One\u0000Two"),
            mapOf("title" to "\uD800"), mapOf("title" to "x".repeat(1025)))) {
            assertThrows(LocalMusicId3.Unsupported::class.java) { LocalMusicId3.edit(original, changes) }
        }
        val oversizedHeader = ascii("ID3") + byteArrayOf(4, 0, 0) + sized(8 * 1024 * 1024, 7)
        assertThrows(LocalMusicId3.Unsupported::class.java) { LocalMusicId3.tagSize(oversizedHeader) }
    }

    @Test
    fun writesLegacyReleaseYearAndDayMonthWithoutInventingADay() {
        val title = textFrame("TIT2", "Title", version = 3)
        val originalDate = textFrame("TORY", "1982", version = 3)
        val original = tag(3, 100, title, originalDate)
        val edited = LocalMusicId3.edit(original, mapOf("genre" to "Jazz", "releaseDate" to "2024-02-29"))
        val expected = title + originalDate + textFrame("TCON", "Jazz", 3) +
            textFrame("TYER", "2024", 3) + textFrame("TDAT", "2902", 3)
        assertArrayEquals(expected, edited.copyOfRange(10, 10 + expected.size))
        assertEquals("2024-02-29", LocalMusicId3.inspect(edited)["releaseDate"])

        val shortened = LocalMusicId3.edit(edited, mapOf("releaseDate" to "2025"))
        assertEquals("2025", LocalMusicId3.inspect(shortened)["releaseDate"])
        assertFalse("TDAT" in shortened.toString(Charsets.ISO_8859_1))
        for (invalid in listOf("2023-02-29", "2024-02", "0000", "2024-04-31")) {
            assertThrows(LocalMusicId3.InvalidReleaseDate::class.java) {
                LocalMusicId3.edit(edited, mapOf("releaseDate" to invalid))
            }
        }
    }

    @Test
    fun writesPartialReleaseDateAndPreservesRecordingAndOriginalDates() {
        val preserved = textFrame("TIT2", "Title") + textFrame("TDRC", "2020-03-25") +
            textFrame("TDOR", "1982")
        val original = tag(4, 64, preserved)
        val edited = LocalMusicId3.edit(original, mapOf("genre" to "Jazz", "releaseDate" to "2024-02"))
        val frames = preserved + textFrame("TCON", "Jazz") + textFrame("TDRL", "2024-02")
        assertArrayEquals(frames, edited.copyOfRange(10, 10 + frames.size))
        assertEquals("2024-02", LocalMusicId3.inspect(edited)["releaseDate"])

        val cleared = LocalMusicId3.edit(edited, mapOf("genre" to null, "releaseDate" to null))
        assertArrayEquals(original, cleared)
    }

    @Test
    fun preservesMultiValueGenreOnAnUnrelatedEdit() {
        val genre = textFrame("TCON", "Jazz\u0000Blues")
        val original = tag(4, 64, genre, textFrame("TIT2", "Title"))
        assertFalse("genre" in LocalMusicId3.inspectEditable(original).editableFields)
        val edited = LocalMusicId3.edit(original, mapOf("title" to "New title"))
        assertArrayEquals(genre, edited.copyOfRange(10, 10 + genre.size))
        assertThrows(LocalMusicId3.Unsupported::class.java) {
            LocalMusicId3.edit(original, mapOf("genre" to "Pop"))
        }
    }

    private fun tag(version: Int, padding: Int, vararg frames: ByteArray): ByteArray {
        val body = frames.fold(byteArrayOf(), ByteArray::plus) + ByteArray(padding)
        return ascii("ID3") + byteArrayOf(version.toByte(), 0, 0) + sized(body.size, 7) + body
    }

    private fun textFrame(id: String, value: String, version: Int = 4): ByteArray =
        frame(id, byteArrayOf(if (version == 3) 0 else 3) + value.toByteArray(), version)

    private fun lyricsFrame(language: String, descriptor: String, text: String): ByteArray =
        frame("USLT", byteArrayOf(3) + ascii(language) + descriptor.toByteArray() + byteArrayOf(0) +
            text.toByteArray())

    private fun frame(id: String, value: ByteArray, version: Int = 4, status: Int = 0, format: Int = 0): ByteArray =
        ascii(id) + sized(value.size, if (version == 4) 7 else 8) + byteArrayOf(status.toByte(), format.toByte()) + value

    private fun sized(value: Int, bits: Int): ByteArray =
        ByteArray(4) { ((value shr ((3 - it) * bits)) and ((1 shl bits) - 1)).toByte() }

    private fun ascii(value: String) = value.toByteArray(Charsets.US_ASCII)
}
