package com.github.dvbeckwitt.videre

import org.junit.Assert.assertEquals
import org.junit.Test
import java.io.ByteArrayInputStream
import java.io.IOException
import java.nio.ByteBuffer
import java.nio.ByteOrder

class LocalMusicSortTagsTest {
    @Test fun readsOnlyExplicitId3v24SortFrames() {
        val tag = id3(4, frame(4, "TIT2", byteArrayOf(3) + "Actual title".toByteArray()),
            frame(4, "APIC", ByteArray(191)),
            frame(4, "TSOT", byteArrayOf(3) + " Élégie 02\u0000".toByteArray(), status = 0x20),
            frame(4, "TSOP", byteArrayOf(2) + "水野".toByteArray(Charsets.UTF_16BE)),
            frame(4, "TSOA", byteArrayOf(0) + "Les années".toByteArray(Charsets.ISO_8859_1)),
            frame(4, "TSO2", utf16LittleEndian("邦楽")), ByteArray(13))
        val stream = ByteArrayInputStream(tag + byteArrayOf(1, 2, 3))

        assertEquals(LocalMusicSortTags("Élégie 02", "水野", "Les années", "邦楽"),
            readLocalMusicSortTags(stream))
        assertEquals(3, stream.available())
    }

    @Test fun readsId3v23FramesFromStreamsThatCannotSeek() {
        val tag = id3(3, frame(3, "APIC", ByteArray(191)),
            frame(3, "TSOT", byteArrayOf(0) + "Track 009".toByteArray()),
            frame(3, "TSOP", utf16LittleEndian("Björk")),
            frame(3, "TSO2", byteArrayOf(0) + "Various artists".toByteArray()))
        val stream = object : ByteArrayInputStream(tag) {
            override fun skip(n: Long): Long = 0
            override fun close() = throw IOException("The caller owns the input")
        }

        assertEquals(LocalMusicSortTags(title = "Track 009", artist = "Björk", albumArtist = "Various artists"),
            readLocalMusicSortTags(stream))
    }

    @Test fun ignoresId3UnsupportedFramesAndRejectsAmbiguousOrInvalidText() {
        val tag = id3(4,
            frame(4, "TSOT", byteArrayOf(3) + "First".toByteArray()),
            frame(4, "TSOT", byteArrayOf(3) + "Second".toByteArray()),
            frame(4, "TSOP", byteArrayOf(3) + "Unsynchronised".toByteArray(), format = 2),
            frame(4, "TSOA", byteArrayOf(3, 0xc3.toByte(), 0x28)),
            frame(4, "TSO2", byteArrayOf(3) + " Credited artist ".toByteArray()))

        assertEquals(LocalMusicSortTags(albumArtist = "Credited artist"), readLocalMusicSortTags(tag.inputStream()))

        val invalid = id3(4, frame(4, "TSOT", byteArrayOf(3) + "<UNKNOWN>".toByteArray()),
            frame(4, "TSOP", byteArrayOf(3) + "\nArtist".toByteArray()),
            frame(4, "TSOA", byteArrayOf(1) + "Missing BOM".toByteArray(Charsets.UTF_16BE)),
            frame(4, "TSO2", byteArrayOf(3) + "A\u0000B".toByteArray()))
        assertEquals(LocalMusicSortTags(), readLocalMusicSortTags(invalid.inputStream()))
    }

    @Test fun rejectsId3HeadersThatCannotBeTraversedSafely() {
        val explicit = frame(4, "TSOT", byteArrayOf(3) + "Trusted".toByteArray())
        val truncated = id3(4, explicit, frame(4, "APIC", ByteArray(20))).dropLast(1).toByteArray()
        val fakeSeek = object : ByteArrayInputStream(truncated) {
            override fun skip(n: Long): Long {
                super.skip(n)
                return n
            }
        }
        assertEquals(LocalMusicSortTags(), readLocalMusicSortTags(fakeSeek))
        assertEquals(LocalMusicSortTags(), readLocalMusicSortTags(id3(4, explicit,
            byteArrayOf(0), explicit).inputStream()))

        for (flags in listOf(0x80, 0x40, 0x10, 0x01)) {
            val tag = id3(4, explicit).apply { this[5] = flags.toByte() }
            assertEquals(LocalMusicSortTags(), readLocalMusicSortTags(tag.inputStream()))
        }
        val large = (id3Header(4, 64 * 1024 * 1024) + explicit).inputStream()
        assertEquals(LocalMusicSortTags(), readLocalMusicSortTags(large))
        assertEquals(explicit.size, large.available())
        val invalidSize = id3(4, explicit).apply { this[6] = 0x80.toByte() }
        assertEquals(LocalMusicSortTags(), readLocalMusicSortTags(invalidSize.inputStream()))
    }

    @Test fun readsWellFormedFlacVorbisCommentsWithoutReadingAudio() {
        val comments = vorbis("TITLE=Actual title", "tItLeSoRt=水の歌", "ARTISTSORT=Artist 10",
            "ALBUMSORT=Collection = Vol. 2", "albumartistsort=Artist, The")
        val file = flac(block(1, ByteArray(500)), block(4, comments, last = true))
        val stream = (file + byteArrayOf(1, 2, 3)).inputStream()

        assertEquals(LocalMusicSortTags("水の歌", "Artist 10", "Collection = Vol. 2", "Artist, The"),
            readLocalMusicSortTags(stream))
        assertEquals(3, stream.available())
    }

    @Test fun doesNotGuessFlacSortNamesFromUnrelatedOrRepeatedFields() {
        val comments = vorbis("TITLE=Title", "title_sort=Other", "TitlESORT=First", "titlesort=Second",
            "ARTIST=Artist", "ALBUMSORT=<unknown>", "ALBUMARTISTSORT= The Album Artist ")

        assertEquals(LocalMusicSortTags(albumArtist = "The Album Artist"),
            readLocalMusicSortTags(flac(block(4, comments, last = true)).inputStream()))
    }

    @Test fun rejectsMalformedOrUnreasonablyLargeFlacMetadata() {
        val explicit = vorbis("TITLESORT=Verified")
        val truncated = flac(block(4, explicit, last = true)).dropLast(1).toByteArray()
        val malformed = flac(block(4, explicit + byteArrayOf(0), last = true))
        val badCount = flac(block(4, lengthAndText("test".toByteArray()) + littleEndian(Int.MAX_VALUE), last = true))
        val badUtf8 = flac(block(4, vorbis("TITLESORT=Verified", "COMMENT=A").apply {
            this[lastIndex] = 0xff.toByte()
        }, last = true))
        val badKey = flac(block(4, vorbis("TITLESORT=Verified", "Co\nmment=A"), last = true))
        val duplicateBlocks = flac(block(4, explicit), block(4, explicit, last = true))
        val noStreamInfo = "fLaC".toByteArray() + block(4, explicit, last = true)

        for (file in listOf(truncated, malformed, badCount, badUtf8, badKey, duplicateBlocks, noStreamInfo)) {
            assertEquals(LocalMusicSortTags(), readLocalMusicSortTags(file.inputStream()))
        }
        val large = flac(byteArrayOf(0x81.toByte(), 0x40, 0, 0), explicit).inputStream()
        assertEquals(LocalMusicSortTags(), readLocalMusicSortTags(large))
        assertEquals(explicit.size, large.available())
    }

    @Test fun leavesUnsupportedAudioFormatsAlone() {
        val audio = ("OggS".toByteArray() + vorbis("TITLESORT=Fake")).inputStream()
        val originalSize = audio.available()

        assertEquals(LocalMusicSortTags(), readLocalMusicSortTags(audio))
        assertEquals(originalSize - 4, audio.available())
    }

    private fun utf16LittleEndian(text: String) = byteArrayOf(1, 0xff.toByte(), 0xfe.toByte()) +
        text.toByteArray(Charsets.UTF_16LE)

    private fun id3(version: Int, vararg chunks: ByteArray): ByteArray {
        val payload = chunks.reduce(ByteArray::plus)
        return id3Header(version, payload.size) + payload
    }

    private fun id3Header(version: Int, size: Int) = byteArrayOf(0x49, 0x44, 0x33, version.toByte(), 0, 0) +
        synchsafe(size)

    private fun frame(version: Int, name: String, payload: ByteArray, status: Int = 0, format: Int = 0): ByteArray {
        val size = if (version == 4) synchsafe(payload.size) else ByteBuffer.allocate(4).putInt(payload.size).array()
        return name.toByteArray() + size + byteArrayOf(status.toByte(), format.toByte()) + payload
    }

    private fun synchsafe(size: Int) = byteArrayOf((size ushr 21 and 127).toByte(),
        (size ushr 14 and 127).toByte(), (size ushr 7 and 127).toByte(), (size and 127).toByte())

    private fun flac(vararg blocks: ByteArray) = "fLaC".toByteArray() + block(0, ByteArray(34)) +
        blocks.reduce(ByteArray::plus)

    private fun block(type: Int, payload: ByteArray, last: Boolean = false): ByteArray {
        val header = (type shl 24) or payload.size or (if (last) Int.MIN_VALUE else 0)
        return ByteBuffer.allocate(4).putInt(header).array() + payload
    }

    private fun vorbis(vararg values: String): ByteArray {
        val prefix = lengthAndText("test".toByteArray()) + littleEndian(values.size)
        return values.fold(prefix) { data, text -> data + lengthAndText(text.toByteArray()) }
    }

    private fun lengthAndText(bytes: ByteArray) = littleEndian(bytes.size) + bytes

    private fun littleEndian(value: Int) = ByteBuffer.allocate(4).order(ByteOrder.LITTLE_ENDIAN).putInt(value).array()
}
