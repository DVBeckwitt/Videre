package com.github.dvbeckwitt.videre

import org.junit.Assert.assertEquals
import org.junit.Test
import java.io.ByteArrayInputStream
import java.io.IOException
import java.io.InputStream
import java.nio.ByteBuffer
import java.nio.ByteOrder

class LocalMusicSortTagsTest {
    @Test fun readsOnlyExplicitId3v24SortFrames() {
        val tag = id3(4, frame(4, "TIT2", byteArrayOf(3) + "Actual title".toByteArray()),
            frame(4, "APIC", ByteArray(191)),
            frame(4, "TSOT", byteArrayOf(3) + " Élégie 02\u0000".toByteArray(), status = 0x20),
            frame(4, "TSOP", byteArrayOf(2) + "水野".toByteArray(Charsets.UTF_16BE)),
            frame(4, "TSOA", byteArrayOf(0) + "Les années".toByteArray(Charsets.ISO_8859_1)),
            frame(4, "TSO2", utf16LittleEndian("邦楽")),
            frame(4, "TSST", byteArrayOf(3) + " Rarities ".toByteArray()), ByteArray(13))
        val stream = ByteArrayInputStream(tag + byteArrayOf(1, 2, 3))

        assertEquals(LocalMusicSortTags("Élégie 02", "水野", "Les années", "邦楽", discSubtitle = "Rarities"),
            readSortTags(stream))
        assertEquals(3, stream.available())
    }

    @Test fun readsId3v23FramesFromStreamsThatCannotSeek() {
        val tag = id3(3, frame(3, "APIC", ByteArray(191)),
            frame(3, "TSOT", byteArrayOf(0) + "Track 009".toByteArray()),
            frame(3, "TSOP", utf16LittleEndian("Björk")),
            frame(3, "TSO2", byteArrayOf(0) + "Various artists".toByteArray()),
            frame(3, "TSST", utf16LittleEndian("Éditions")))
        val stream = object : ByteArrayInputStream(tag) {
            override fun skip(n: Long): Long = 0
            override fun close() = throw IOException("The caller owns the input")
        }

        assertEquals(LocalMusicSortTags(title = "Track 009", artist = "Björk", albumArtist = "Various artists",
            discSubtitle = "Éditions"),
            readSortTags(stream))
    }

    @Test fun ignoresId3UnsupportedFramesAndRejectsAmbiguousOrInvalidText() {
        val tag = id3(4,
            frame(4, "TSOT", byteArrayOf(3) + "First".toByteArray()),
            frame(4, "TSOT", byteArrayOf(3) + "Second".toByteArray()),
            frame(4, "TSOP", byteArrayOf(3) + "Unsynchronised".toByteArray(), format = 2),
            frame(4, "TSOA", byteArrayOf(3, 0xc3.toByte(), 0x28)),
            frame(4, "TSO2", byteArrayOf(3) + " Credited artist ".toByteArray()))

        assertEquals(LocalMusicSortTags(albumArtist = "Credited artist"), readSortTags(tag.inputStream()))

        val invalid = id3(4, frame(4, "TSOT", byteArrayOf(3) + "<UNKNOWN>".toByteArray()),
            frame(4, "TSOP", byteArrayOf(3) + "\nArtist".toByteArray()),
            frame(4, "TSOA", byteArrayOf(1) + "Missing BOM".toByteArray(Charsets.UTF_16BE)),
            frame(4, "TSO2", byteArrayOf(3) + "A\u0000B".toByteArray()))
        assertEquals(LocalMusicSortTags(), readSortTags(invalid.inputStream()))
    }

    @Test fun readsPicardReleaseTypeFromId3v23AndId3v24() {
        val legacy = id3(3, frame(3, "TXXX", utf16LittleEndian("MusicBrainz Album Type\u0000album; Live")))
        val modern = id3(4, frame(4, "TXXX", byteArrayOf(3) + "MusicBrainz Album Type\u0000EP".toByteArray()))
        val multivalue = id3(4, frame(4, "TXXX",
            byteArrayOf(3) + "MusicBrainz Album Type\u0000album\u0000live\u0000".toByteArray()))

        assertEquals(LocalMusicReleaseKind.LIVE, readSortTags(legacy.inputStream()).releaseKind)
        assertEquals(LocalMusicReleaseKind.EP, readSortTags(modern.inputStream()).releaseKind)
        assertEquals(LocalMusicReleaseKind.LIVE, readSortTags(multivalue.inputStream()).releaseKind)
    }

    @Test fun ignoresUnrelatedUnknownOrConflictingId3ReleaseTypesWithoutLosingSortTags() {
        fun textFrame(name: String, text: String) = frame(4, name, byteArrayOf(3) + text.toByteArray())
        val sort = textFrame("TSOA", "Sorted title")
        val ep = textFrame("TXXX", "MusicBrainz Album Type\u0000EP")
        for (tag in listOf(
            id3(4, sort, textFrame("TALB", "An EP Recorded Live"), textFrame("TCON", "Live"),
                textFrame("TXXX", "MusicBrainz Album Status\u0000live")),
            id3(4, sort, textFrame("TXXX", "MusicBrainz Album Type\u0000live recording")),
            id3(4, sort, textFrame("TXXX", "MusicBrainz Album Type\u0000ep; single")),
            id3(4, sort, ep, textFrame("TXXX", "MusicBrainz Album Type\u0000album")),
        )) {
            assertEquals(LocalMusicSortTags(album = "Sorted title"), readSortTags(tag.inputStream()))
        }
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
        assertEquals(LocalMusicSortTags(), readSortTags(fakeSeek))
        assertEquals(LocalMusicSortTags(), readSortTags(id3(4, explicit,
            byteArrayOf(0), explicit).inputStream()))

        for (flags in listOf(0x80, 0x40, 0x10, 0x01)) {
            val tag = id3(4, explicit).apply { this[5] = flags.toByte() }
            assertEquals(LocalMusicSortTags(), readSortTags(tag.inputStream()))
        }
        val large = (id3Header(4, 64 * 1024 * 1024) + explicit).inputStream()
        assertEquals(LocalMusicSortTags(), readSortTags(large))
        assertEquals(explicit.size, large.available())
        val invalidSize = id3(4, explicit).apply { this[6] = 0x80.toByte() }
        assertEquals(LocalMusicSortTags(), readSortTags(invalidSize.inputStream()))
    }

    @Test fun readsWellFormedFlacVorbisCommentsWithoutReadingAudio() {
        val comments = vorbis("TITLE=Actual title", "tItLeSoRt=水の歌", "ARTISTSORT=Artist 10",
            "ALBUMSORT=Collection = Vol. 2", "albumartistsort=Artist, The", "discSubtitle=  Live = 1989 ",
            "DISCSUBTITLE=Live = 1989")
        val file = flac(block(1, ByteArray(500)), block(4, comments, last = true))
        val stream = (file + byteArrayOf(1, 2, 3)).inputStream()

        assertEquals(LocalMusicSortTags("水の歌", "Artist 10", "Collection = Vol. 2", "Artist, The", discSubtitle = "Live = 1989"),
            readSortTags(stream))
        assertEquals(3, stream.available())
    }

    @Test fun doesNotGuessFlacSortNamesFromUnrelatedOrRepeatedFields() {
        val comments = vorbis("TITLE=Title", "title_sort=Other", "TitlESORT=First", "titlesort=Second",
            "ARTIST=Artist", "ALBUMSORT=<unknown>", "ALBUMARTISTSORT= The Album Artist ",
            "DISCSUBTITLE=First", "discsubtitle=Second")

        assertEquals(LocalMusicSortTags(albumArtist = "The Album Artist"),
            readSortTags(flac(block(4, comments, last = true)).inputStream()))
    }

    @Test fun readsRepeatedFlacReleaseTypesFromTheExplicitVorbisField() {
        val comments = vorbis("ALBUM=Other", "ALBUMSORT=Sort name",
            "ReleaseType= LIVE ", "RELEASETYPE=album")
        val file = flac(block(4, comments, last = true))

        assertEquals(LocalMusicSortTags(album = "Sort name", releaseKind = LocalMusicReleaseKind.LIVE),
            readSortTags(file.inputStream()))

        val single = flac(block(4, vorbis("RELEASETYPE=single"), last = true))
        assertEquals(LocalMusicReleaseKind.SINGLE, readSortTags(single.inputStream()).releaseKind)
        val mixtape = flac(block(4, vorbis("RELEASETYPE=mixtape/street"), last = true))
        assertEquals(LocalMusicReleaseKind.MIXTAPE, readSortTags(mixtape.inputStream()).releaseKind)
        val unrelated = flac(block(4, vorbis("ALBUM=Live", "GENRE=EP", "XRELEASETYPE=ep",
            "RELEASETYPE=talk show"), last = true))
        assertEquals(null, readSortTags(unrelated.inputStream()).releaseKind)
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
            assertEquals(LocalMusicSortTags(), readSortTags(file.inputStream()))
        }
        val large = flac(byteArrayOf(0x81.toByte(), 0x40, 0, 0), explicit).inputStream()
        assertEquals(LocalMusicSortTags(), readSortTags(large))
        assertEquals(explicit.size, large.available())
    }

    @Test fun leavesUnsupportedAudioFormatsAlone() {
        val audio = ("RIFF".toByteArray() + vorbis("TITLESORT=Fake")).inputStream()
        val originalSize = audio.available()

        assertEquals(LocalMusicReadTags(), readLocalMusicTags(audio))
        assertEquals(originalSize - 4, audio.available())
    }

    @Test fun readsId3NativeListsAndRepeatedFramesInSourceOrder() {
        val tag = id3(4,
            frame(4, "TPE1", byteArrayOf(3) + "AC/DC\u0000Björk; Friends".toByteArray()),
            frame(4, "TPE1", byteArrayOf(3) + "Third".toByteArray()),
            frame(4, "TPE2", byteArrayOf(3) + "Band".toByteArray()),
            frame(4, "TCON", byteArrayOf(3) + "17\u0000Folk".toByteArray()))

        assertEquals(LocalMusicTagValues(
            listOf("AC/DC", "Björk; Friends", "Third"), listOf("Band"), listOf("Rock", "Folk")),
            readLocalMusicTags(tag.inputStream()).values)
    }

    @Test fun boundsNativeId3ValuesBeforeReturningThemToTheIndex() {
        val artists = List(1025) { "Artist $it" }
        val tag = id3(4, frame(4, "TPE1", byteArrayOf(3) + artists.joinToString("\u0000").toByteArray()))

        assertEquals(artists.take(1024), readLocalMusicTags(tag.inputStream()).values.artists)
    }

    @Test fun readsRepeatedFlacCommentsAndKeepsSingleTagPunctuation() {
        val tag = flac(block(4, vorbis(
            "ARTIST=AC/DC", "artist=Björk; Friends", "ALBUM ARTIST=Band", "ALBUMARTIST=Guest",
            "GENRE=Noise\\; Rock; Funk", "genre=Fusion", "ARTISTSORT=Sort This",
            "DISCSUBTITLE=Bonus", "RELEASETYPE=album", "RELEASETYPE=compilation",
        ), last = true))

        assertEquals(LocalMusicReadTags(
            LocalMusicSortTags(
                artist = "Sort This", discSubtitle = "Bonus",
                releaseKind = LocalMusicReleaseKind.COMPILATION,
            ),
            LocalMusicTagValues(listOf("AC/DC", "Björk; Friends"), listOf("Band", "Guest"),
                listOf("Noise\\; Rock; Funk", "Fusion")),
        ), readLocalMusicTags(tag.inputStream()))
    }

    @Test fun readsContinuedOggVorbisAndOpusCommentPackets() {
        val comments = vorbis("ARTIST=AC/DC", "artist=Björk", "GENRE=Rock", "genre=Pop",
            "COMMENT=${"x".repeat(220)}")
        for ((head, tag, suffix) in listOf(
            Triple("\u0001vorbis", "\u0003vorbis", byteArrayOf(1)),
            Triple("OpusHead", "OpusTags", byteArrayOf(0, 0, 0)),
        )) {
            val audio = head.toByteArray()
            val packet = tag.toByteArray() + comments + suffix
            val first = oggPage(0, 2, audio, audio.size)
            val second = oggPage(1, 0, packet.copyOf(255), 255)
            val last = packet.copyOfRange(255, packet.size)
            val third = oggPage(2, 1, last, last.size)
            assertEquals(LocalMusicTagValues(artists = listOf("AC/DC", "Björk"), genres = listOf("Rock", "Pop")),
                readLocalMusicTags((first + second + third).inputStream()).values)

            val broken = oggPage(2, 0, last, last.size)
            assertEquals(LocalMusicReadTags(), readLocalMusicTags((first + second + broken).inputStream()))
        }
    }

    private fun readSortTags(input: InputStream) = readLocalMusicTags(input).sortTags

    private fun oggPage(sequence: Int, flags: Int, body: ByteArray, vararg lacing: Int): ByteArray =
        ByteBuffer.allocate(27 + lacing.size + body.size).order(ByteOrder.LITTLE_ENDIAN)
            .put("OggS".toByteArray()).put(0).put(flags.toByte()).putLong(0)
            .putInt(17).putInt(sequence).putInt(0).put(lacing.size.toByte())
            .put(lacing.map(Int::toByte).toByteArray()).put(body).array()

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
