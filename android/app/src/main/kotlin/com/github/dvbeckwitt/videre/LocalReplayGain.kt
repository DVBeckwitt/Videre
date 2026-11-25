package com.github.dvbeckwitt.videre

import java.io.BufferedInputStream
import java.io.ByteArrayOutputStream
import java.io.DataInputStream
import java.io.EOFException
import java.io.InputStream
import java.util.Locale

internal data class LocalReplayGain(
    val trackGainDb: Double?,
    val albumGainDb: Double?,
    val trackPeak: Double?,
    val albumPeak: Double?,
) {
    fun channelValue(): Map<String, Double?> = mapOf(
        "trackGainDb" to trackGainDb,
        "albumGainDb" to albumGainDb,
        "trackPeak" to trackPeak,
        "albumPeak" to albumPeak,
    )

    companion object {
        fun fromValues(trackGainDb: Double?, albumGainDb: Double?, trackPeak: Double?, albumPeak: Double?) =
            LocalReplayGain(
                trackGainDb?.takeIf(Double::isFinite),
                albumGainDb?.takeIf(Double::isFinite),
                trackPeak?.takeIf { it.isFinite() && it > 0 },
                albumPeak?.takeIf { it.isFinite() && it > 0 },
            ).takeUnless { it.trackGainDb == null && it.albumGainDb == null && it.trackPeak == null && it.albumPeak == null }
    }
}

/** Reads local, container-level ReplayGain metadata without decoding audio. */
internal object LocalReplayGainReader {
    private const val MAX_TAG_BYTES = 4 * 1024 * 1024
    private const val MAX_TEXT_BYTES = 512
    private val gainNumber = Regex("""[+-]?(?:[0-9]+(?:\.[0-9]*)?|\.[0-9]+)(?:\s*dB)?""", RegexOption.IGNORE_CASE)
    private val peakNumber = Regex("""[+]?(?:[0-9]+(?:\.[0-9]*)?|\.[0-9]+)""")
    private val replayGainKeys = setOf(
        "REPLAYGAIN_TRACK_GAIN", "REPLAYGAIN_ALBUM_GAIN", "REPLAYGAIN_TRACK_PEAK", "REPLAYGAIN_ALBUM_PEAK",
    )

    fun read(stream: InputStream): LocalReplayGain? {
        val input = DataInputStream(BufferedInputStream(stream))
        return try {
            val tags = when (val signature = input.bytes(4).ascii()) {
                "fLaC" -> readFlac(input)
                "OggS" -> readOgg(input)
                else -> if (signature.startsWith("ID3")) readId3(input, signature[3].code) else null
            } ?: return null
            LocalReplayGain.fromValues(
                tags["REPLAYGAIN_TRACK_GAIN"],
                tags["REPLAYGAIN_ALBUM_GAIN"],
                tags["REPLAYGAIN_TRACK_PEAK"],
                tags["REPLAYGAIN_ALBUM_PEAK"],
            )
        } catch (_: EOFException) {
            null
        }
    }

    private fun readFlac(input: DataInputStream): Map<String, Double>? {
        var remaining = MAX_TAG_BYTES
        while (remaining >= 4) {
            val flags = input.readUnsignedByte()
            val length = input.bytes(3).bigEndian(0, 3)
            remaining -= 4 + length
            if (remaining < 0) return null
            if (flags and 0x7F == 4) return readComments(input.bytes(length), 0)
            if (flags and 0x80 != 0) return null
            input.skipFully(length)
        }
        return null
    }

    private fun readOgg(input: DataInputStream): Map<String, Double>? {
        val packet = ByteArrayOutputStream()
        var serial: Int? = null
        var packetCount = 0
        var opus = false
        repeat(64) { page ->
            if (page > 0 && input.bytes(4).ascii() != "OggS") return null
            val header = input.bytes(23)
            val pageSerial = header.bigEndian(10, 4)
            val headerType = header.unsigned(1)
            if (header.unsigned(0) != 0 || (serial != null && serial != pageSerial) ||
                (headerType and 1 != 0) != (packet.size() > 0) ||
                (page == 0 && headerType and 2 == 0)) return null
            serial = pageSerial
            val laces = input.bytes(header.unsigned(22))
            for (lace in laces) {
                val length = lace.toInt() and 0xFF
                if (packet.size() + length > MAX_TAG_BYTES) return null
                packet.write(input.bytes(length))
                if (length == 255) continue
                val payload = packet.toByteArray()
                if (packetCount == 0) {
                    opus = payload.startsWith("OpusHead")
                    if (!opus && !payload.startsWith("\u0001vorbis")) return null
                } else {
                    val prefix = if (opus) "OpusTags" else "\u0003vorbis"
                    return if (payload.startsWith(prefix)) readComments(payload, prefix.length) else null
                }
                ++packetCount
                packet.reset()
            }
        }
        return null
    }

    private fun readComments(bytes: ByteArray, start: Int): Map<String, Double>? {
        var cursor = start
        fun readSize(): Int? {
            if (bytes.size - cursor < 4) return null
            val length = bytes.littleEndian(cursor)
            cursor += 4
            return length.takeIf { it in 0..(bytes.size - cursor) }
        }
        val vendorLength = readSize() ?: return null
        cursor += vendorLength
        val count = readSize() ?: return null
        if (count > (bytes.size - cursor) / 4) return null
        val tags = mutableMapOf<String, Double>()
        repeat(count) {
            val length = readSize() ?: return null
            if (length in 1..MAX_TEXT_BYTES) {
                val text = bytes.decodeToString(cursor, cursor + length)
                val divider = text.indexOf('=')
                if (divider > 0) tags.add(text.substring(0, divider), text.substring(divider + 1))
            }
            cursor += length
        }
        return tags
    }

    private fun readId3(input: DataInputStream, version: Int): Map<String, Double>? {
        if (version !in 2..4) return null
        val header = input.bytes(6)
        val flags = header.unsigned(1)
        if (version == 2 && flags and 0x40 != 0) return null
        val size = header.syncSafe(2)
        if (size !in 1..MAX_TAG_BYTES) return null
        var body = input.bytes(size)
        if (version < 4 && flags and 0x80 != 0) body = body.removeUnsynchronisation()
        var cursor = 0
        if (version >= 3 && flags and 0x40 != 0) {
            if (body.size < 4) return null
            val extendedSize = if (version == 4) body.syncSafe(0) else body.bigEndian(0, 4)
            if (extendedSize !in 4..body.size) return null
            cursor = extendedSize + if (version == 3) 4 else 0
            if (cursor > body.size) return null
        }
        val tags = mutableMapOf<String, Double>()
        val idSize = if (version == 2) 3 else 4
        val frameHeaderSize = if (version == 2) 6 else 10
        val textFrameId = if (version == 2) "TXX" else "TXXX"
        while (body.size - cursor >= frameHeaderSize && body[cursor] != 0.toByte()) {
            val frameId = body.ascii(cursor, idSize)
            val frameSize = when (version) {
                2 -> body.bigEndian(cursor + idSize, 3)
                3 -> body.bigEndian(cursor + idSize, 4)
                else -> body.syncSafe(cursor + idSize)
            }
            val frameFlags = if (version == 2) 0 else body.unsigned(cursor + 9)
            cursor += frameHeaderSize
            if (frameSize !in 0..(body.size - cursor)) return null
            if (frameId == textFrameId && frameSize in 2..MAX_TEXT_BYTES) {
                val frame = body.copyOfRange(cursor, cursor + frameSize)
                val text = readId3Text(frame, version, frameFlags, flags)
                if (text != null) tags.add(text.first, text.second)
            }
            cursor += frameSize
        }
        return tags
    }

    private fun readId3Text(
        frame: ByteArray,
        version: Int,
        frameFlags: Int,
        tagFlags: Int,
    ): Pair<String, String>? {
        if ((version == 3 && frameFlags and 0xC0 != 0) ||
            (version == 4 && frameFlags and 0x0C != 0)) return null
        val data = if (version == 4 && (frameFlags and 0x02 != 0 || tagFlags and 0x80 != 0)) {
            frame.removeUnsynchronisation()
        } else frame
        var offset = 0
        if ((version == 3 && frameFlags and 0x20 != 0) ||
            (version == 4 && frameFlags and 0x40 != 0)) ++offset
        if (version == 4 && frameFlags and 0x01 != 0) offset += 4
        if (data.size - offset < 2) return null
        val charset = when (data.unsigned(offset)) {
            0 -> Charsets.ISO_8859_1
            1 -> Charsets.UTF_16
            2 -> Charsets.UTF_16BE
            3 -> Charsets.UTF_8
            else -> return null
        }
        val text = String(data, offset + 1, data.size - offset - 1, charset)
        val divider = text.indexOf('\u0000')
        if (divider <= 0) return null
        return text.substring(0, divider) to text.substring(divider + 1).trimStart('\uFEFF').trimEnd('\u0000')
    }

    private fun MutableMap<String, Double>.add(name: String, value: String) {
        val key = name.uppercase(Locale.ROOT)
        if (key !in replayGainKeys) return
        val text = value.trim()
        val gain = key.endsWith("_GAIN")
        if (!(if (gain) gainNumber else peakNumber).matches(text)) return
        val number = (if (gain) text.replace(Regex("""\s*[dD][bB]$"""), "") else text).toDoubleOrNull()
        if (number == null || !number.isFinite() || (!gain && number <= 0)) return
        putIfAbsent(key, number)
    }

    private fun DataInputStream.bytes(size: Int): ByteArray = ByteArray(size).also(::readFully)

    private fun DataInputStream.skipFully(size: Int) {
        var remaining = size
        while (remaining > 0) {
            val skipped = skipBytes(remaining)
            if (skipped == 0) {
                readByte()
                --remaining
            } else remaining -= skipped
        }
    }

    private fun ByteArray.unsigned(index: Int): Int = this[index].toInt() and 0xFF

    private fun ByteArray.littleEndian(offset: Int): Int =
        (0..3).fold(0) { value, index -> value or (unsigned(offset + index) shl (index * 8)) }

    private fun ByteArray.bigEndian(offset: Int, count: Int): Int =
        (offset until offset + count).fold(0) { value, index -> (value shl 8) or unsigned(index) }

    private fun ByteArray.syncSafe(offset: Int): Int {
        var value = 0
        for (index in offset until offset + 4) {
            val byte = unsigned(index)
            if (byte >= 0x80) return -1
            value = (value shl 7) or byte
        }
        return value
    }

    private fun ByteArray.ascii(offset: Int = 0, count: Int = size): String =
        String(this, offset, count, Charsets.ISO_8859_1)

    private fun ByteArray.startsWith(prefix: String): Boolean =
        size >= prefix.length && ascii(0, prefix.length) == prefix

    private fun ByteArray.removeUnsynchronisation(): ByteArray {
        val output = ByteArray(size)
        var read = 0
        var written = 0
        while (read < size) {
            val byte = this[read++]
            output[written++] = byte
            if (byte.toInt() == -1 && read < size && this[read] == 0.toByte()) ++read
        }
        return output.copyOf(written)
    }
}
