package com.github.dvbeckwitt.videre

import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Test

class LocalReplayGainTest {
    @Test fun mp3ReadsId3UserTextAndAppliesTheFirstValidValueForADuplicate() {
        val frames = frame("replaygain_track_gain", "bad") +
            frame("replaygain_track_gain", "-7.25 dB") +
            frame("REPLAYGAIN_TRACK_GAIN", "+5 dB") +
            frame("ReplayGain_Album_Gain", "+2.5 dB", encoding = 1) +
            frame("REPLAYGAIN_TRACK_PEAK", "0.825") +
            frame("REPLAYGAIN_ALBUM_PEAK", "1.02")
        val song = bytes("ID3") + byteArrayOf(4, 0, 0) + syncSafe(frames.size) + frames
        assertEquals(LocalReplayGain(-7.25, 2.5, 0.825, 1.02), read(song))
    }

    @Test fun flacReadsVorbisCommentsBeforeAudioFrames() {
        val comments = comments(
            "replaygain_track_gain=-3.0 dB",
            "replaygain_track_peak=0.65",
            "REPLAYGAIN_ALBUM_PEAK=0",
            "REPLAYGAIN_ALBUM_GAIN=Infinity",
            "R128_TRACK_GAIN=-512",
        )
        val flac = bytes("fLaC") + block(0, ByteArray(34)) + block(0x84, comments)
        assertEquals(LocalReplayGain(-3.0, null, 0.65, null), read(flac))
    }

    @Test fun oggReadsOpusAndVorbisCommentsEvenAcrossPages() {
        val comments = comments("DESCRIPTION=${"x".repeat(265)}", "REPLAYGAIN_ALBUM_GAIN=-2.5 dB")
        for ((header, prefix) in listOf("OpusHead" to "OpusTags", "\u0001vorbis" to "\u0003vorbis")) {
            val identification = bytes(header) + ByteArray(12)
            val packet = bytes(prefix) + comments
            val ogg = page(flags = 2, laces = listOf(identification.size), payload = identification) +
                page(flags = 0, laces = listOf(255), payload = packet.copyOfRange(0, 255)) +
                page(flags = 1, laces = listOf(packet.size - 255), payload = packet.copyOfRange(255, packet.size))
            assertEquals(LocalReplayGain(null, -2.5, null, null), read(ogg))
        }
    }

    @Test fun untaggedAndTruncatedFilesRemainUsableAndHaveNoGain() {
        assertNull(read(bytes("ordinary media")))
        assertNull(read(bytes("fLaC") + block(0x84, comments("REPLAYGAIN_TRACK_PEAK=-1"))))
        assertNull(read(bytes("fLaC") + block(0x84, comments("REPLAYGAIN_TRACK_GAIN=4 dB")).dropLast(1).toByteArray()))
        assertNull(read(bytes("ID3") + byteArrayOf(4, 0, 0) + syncSafe(40) + byteArrayOf(1)))
    }

    private fun read(song: ByteArray) = LocalReplayGainReader.read(song.inputStream())

    private fun bytes(value: String) = value.toByteArray(Charsets.UTF_8)

    private fun frame(name: String, value: String, encoding: Int = 3): ByteArray {
        val charset = if (encoding == 1) Charsets.UTF_16 else Charsets.UTF_8
        val payload = byteArrayOf(encoding.toByte()) + "$name\u0000$value".toByteArray(charset)
        return bytes("TXXX") + syncSafe(payload.size) + byteArrayOf(0, 0) + payload
    }

    private fun syncSafe(value: Int) = ByteArray(4) { (value shr (7 * (3 - it)) and 0x7F).toByte() }

    private fun comments(vararg fields: String): ByteArray {
        val vendor = bytes("Videre test")
        return littleEndian(vendor.size) + vendor + littleEndian(fields.size) +
            fields.fold(ByteArray(0)) { result, field ->
                val fieldBytes = bytes(field)
                result + littleEndian(fieldBytes.size) + fieldBytes
            }
    }

    private fun littleEndian(value: Int) = ByteArray(4) { (value shr (8 * it)).toByte() }

    private fun block(type: Int, payload: ByteArray) = byteArrayOf(
        type.toByte(), (payload.size shr 16).toByte(), (payload.size shr 8).toByte(), payload.size.toByte(),
    ) + payload

    private fun page(flags: Int, laces: List<Int>, payload: ByteArray): ByteArray {
        val header = ByteArray(27)
        bytes("OggS").copyInto(header)
        header[5] = flags.toByte()
        header[14] = 1
        header[26] = laces.size.toByte()
        return header + laces.map(Int::toByte).toByteArray() + payload
    }
}
