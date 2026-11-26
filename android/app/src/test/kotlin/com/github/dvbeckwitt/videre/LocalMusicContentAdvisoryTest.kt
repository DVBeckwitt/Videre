package com.github.dvbeckwitt.videre

import java.nio.ByteBuffer
import org.junit.Assert.assertEquals
import org.junit.Test

class LocalMusicContentAdvisoryTest {
    @Test fun readsOnlySupportedRatingsFromTheMp4Metadata() {
        val title = atom("©nam", atom("data", int(1) + int(0) + "Same Song (Explicit)".toByteArray()))
        for ((value, expected) in listOf(
            1 to LocalMusicAdvisory.EXPLICIT,
            4 to LocalMusicAdvisory.EXPLICIT,
            2 to LocalMusicAdvisory.CLEAN,
            0 to LocalMusicAdvisory.UNKNOWN,
            3 to LocalMusicAdvisory.UNKNOWN,
        )) {
            assertEquals(expected, read(mp4(title + rating(value))))
        }
        assertEquals(LocalMusicAdvisory.EXPLICIT, read(mp4(rating(1, dataType = 0))))
        assertEquals(LocalMusicAdvisory.UNKNOWN, read(mp4(title)))
    }

    @Test fun leavesIrrelevantMalformedAndConflictingTagsUnknown() {
        val explicit = mp4(rating(1))
        for (file in listOf(
            "ID3 ITUNESADVISORY 1".toByteArray(),
            mp4(atom("free", rating(1))),
            mp4(rating(1, dataType = 1)),
            mp4(rating(1) + rating(2)),
            explicit.copyOf(explicit.size - 1),
        )) {
            assertEquals(LocalMusicAdvisory.UNKNOWN, read(file))
        }
    }

    @Test fun seeksPastLargeAudioDataAndBoundsUnseekableReads() {
        val file = fileType + atom("mdat", ByteArray(5 * 1024 * 1024)) + movie(rating(1))
        assertEquals(LocalMusicAdvisory.UNKNOWN, read(file))
        val stream = file.inputStream()
        assertEquals(LocalMusicAdvisory.EXPLICIT, readLocalMusicContentAdvisory(
            stream, file.size.toLong(), seekForward = { stream.skip(it) == it },
        ))
    }

    private fun read(file: ByteArray) =
        readLocalMusicContentAdvisory(file.inputStream(), file.size.toLong())

    private fun mp4(items: ByteArray) = fileType + movie(items)
    private fun movie(items: ByteArray) = atom("moov", atom("udta", atom("meta", int(0) + atom("ilst", items))))
    private fun rating(value: Int, dataType: Int = 21) =
        atom("rtng", atom("data", int(dataType) + int(0) + byteArrayOf(value.toByte())))
    private fun atom(type: String, payload: ByteArray) =
        int(payload.size + 8) + type.toByteArray(Charsets.ISO_8859_1) + payload
    private fun int(value: Int) = ByteBuffer.allocate(4).putInt(value).array()

    private val fileType = atom("ftyp", "M4A ".toByteArray() + int(0))
}
