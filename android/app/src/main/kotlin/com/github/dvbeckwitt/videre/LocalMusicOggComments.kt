package com.github.dvbeckwitt.videre

import java.io.ByteArrayOutputStream
import java.io.DataInputStream
import java.nio.ByteBuffer
import java.nio.ByteOrder

internal enum class VorbisCommentEnd { Exact, FramingBit, Padding }

internal data class LocalOggCommentPacket(
    val bytes: ByteArray,
    val prefixLength: Int,
    val end: VorbisCommentEnd,
)

private enum class OggMusicCodec(val head: String, val tags: String, val end: VorbisCommentEnd) {
    Vorbis("\u0001vorbis", "\u0003vorbis", VorbisCommentEnd.FramingBit),
    Opus("OpusHead", "OpusTags", VorbisCommentEnd.Padding),
}

private const val OGG_CAPTURE = 0x4f676753
private const val MAX_OGG_TAG_SCAN_BYTES = 4 * 1024 * 1024

/** Reads the comment packet of the first logical Ogg stream, after the initial capture bytes. */
internal fun readLocalOggComments(input: DataInputStream): LocalOggCommentPacket? {
    val header = ByteBuffer.allocate(23).order(ByteOrder.LITTLE_ENDIAN)
    val lacing = ByteArray(255)
    val segment = ByteArray(255)
    val packet = ByteArrayOutputStream()
    var remaining = MAX_OGG_TAG_SCAN_BYTES
    var streamSerial: Int? = null
    var expectedSequence = 0
    var continued = false
    var codec: OggMusicCodec? = null

    do {
        if (remaining < 27) return null
        input.readFully(header.array())
        if (header[0].toInt() != 0) return null
        val flags = header[1].toInt()
        val serial = header.getInt(10)
        val sequence = header.getInt(14)
        val segmentCount = header[22].toInt() and 0xff
        remaining -= 27 + segmentCount
        if (remaining < 0) return null
        input.readFully(lacing, 0, segmentCount)
        if (streamSerial == null) {
            if (flags and 2 == 0) return null
            streamSerial = serial
        }
        val currentStream = streamSerial == serial
        if (currentStream && (sequence != expectedSequence++ || (flags and 1 != 0) != continued)) return null

        for (index in 0 until segmentCount) {
            val length = lacing[index].toInt() and 0xff
            remaining -= length
            if (remaining < 0) return null
            input.readFully(segment, 0, length)
            if (!currentStream) continue

            packet.write(segment, 0, length)
            continued = length == 255
            if (continued) continue
            val bytes = packet.toByteArray()
            val identified = codec
            if (identified != null) {
                if (!bytes.startsWithAscii(identified.tags)) return null
                return LocalOggCommentPacket(bytes, identified.tags.length, identified.end)
            }
            codec = OggMusicCodec.entries.firstOrNull { bytes.startsWithAscii(it.head) } ?: return null
            packet.reset()
        }
        if (currentStream && flags and 4 != 0) return null
    } while (input.readInt() == OGG_CAPTURE)
    return null
}

private fun ByteArray.startsWithAscii(prefix: String): Boolean =
    size >= prefix.length && prefix.indices.all { this[it] == prefix[it].code.toByte() }
