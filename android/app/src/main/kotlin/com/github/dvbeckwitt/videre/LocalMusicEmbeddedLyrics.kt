package com.github.dvbeckwitt.videre

import java.io.ByteArrayOutputStream
import java.io.InputStream
import java.nio.ByteBuffer
import java.nio.charset.CharacterCodingException
import java.nio.charset.Charset
import java.util.Locale

private const val MAX_SCAN_BYTES = 8 * 1024 * 1024
private const val MAX_COMMENT_BYTES = 4 * 1024 * 1024
private const val MAX_LYRICS_CHARACTERS = 128 * 1024
private const val MAX_LYRICS_BYTES = 4 * MAX_LYRICS_CHARACTERS
private const val MAX_CUES = 3000

/** Reads lyrics from the authorized audio stream. The caller owns the stream. */
internal object LocalMusicEmbeddedLyrics {
    fun read(input: InputStream): String? {
        val metadata = LyricsMetadataInput(input)
        val signature = metadata.read(4) ?: return null
        return when {
            signature.ascii(0, 3) == "ID3" -> readId3(metadata, signature)
            signature.ascii(0, 4) == "fLaC" -> readFlac(metadata)
            signature.ascii(0, 4) == "OggS" -> readOgg(metadata, signature)
            else -> readMp4(metadata, signature)
        }
    }

    // ID3v2.2/2.3/2.4 use different frame lengths and unsynchronisation scopes.
    private fun readId3(input: LyricsMetadataInput, signature: ByteArray): String? {
        val version = signature.u8(3)
        if (version !in 2..4) return null
        val header = input.read(6) ?: return null
        val flags = header.u8(1)
        if (version == 2 && flags and 0x40 != 0) return null // Compressed tag.
        val size = header.synchsafe(2) ?: return null
        val body = input.read(size) ?: return null
        val tag = if (version < 4 && flags and 0x80 != 0) body.removeUnsynchronisation() else body
        var position = 0
        if (version > 2 && flags and 0x40 != 0) {
            if (tag.size < 4) return null
            position = if (version == 3) {
                val extendedSize = tag.bigInt(0, 4)
                if (extendedSize !in 6..(tag.size - 4)) return null
                extendedSize + 4
            } else {
                val extendedSize = tag.synchsafe(0) ?: return null
                if (extendedSize !in 6..tag.size) return null
                extendedSize
            }
        }

        val idSize = if (version == 2) 3 else 4
        val headerSize = if (version == 2) 6 else 10
        var plain: String? = null
        var userText: String? = null
        while (position <= tag.size - headerSize && tag.u8(position) != 0) {
            val id = tag.ascii(position, idSize)
            val frameSize = when (version) {
                2 -> tag.bigInt(position + idSize, 3)
                3 -> tag.bigInt(position + idSize, 4)
                else -> tag.synchsafe(position + idSize) ?: break
            }
            val frameFlags = if (version == 2) 0 else tag.u8(position + 9)
            position += headerSize
            if (frameSize !in 1..(tag.size - position)) break
            val start = position
            position += frameSize
            if (id !in lyricFrameIds || frameSize > MAX_LYRICS_BYTES) continue
            if (version == 3 && frameFlags and 0xC0 != 0) continue // Compression or encryption.
            if (version == 4 && frameFlags and 0x0C != 0) continue

            val rawFrame = tag.copyOfRange(start, position)
            val frame = if (version == 4 && (flags and 0x80 != 0 || frameFlags and 0x02 != 0)) {
                rawFrame.removeUnsynchronisation()
            } else rawFrame
            var data = 0
            if (version == 3 && frameFlags and 0x20 != 0) data += 1 // Group identifier.
            if (version == 4 && frameFlags and 0x40 != 0) data += 1
            if (version == 4 && frameFlags and 0x01 != 0) data += 4 // Data length indicator.
            when (id) {
                "SYLT", "SLT" -> readSyncedId3(frame, data)?.let { return it }
                "USLT", "ULT" -> if (plain == null) plain = readPlainId3(frame, data, userDefined = false)
                "TXXX", "TXX" -> if (userText == null) userText = readPlainId3(frame, data, userDefined = true)
            }
        }
        return plain ?: userText
    }

    private fun readPlainId3(frame: ByteArray, data: Int, userDefined: Boolean): String? {
        // USLT starts with encoding and a three-byte language, TXXX has no language.
        val description = data + if (userDefined) 1 else 4
        if (description >= frame.size) return null
        val encoding = Id3LyricsEncoding.from(frame.u8(data)) ?: return null
        val descriptionEnd = encoding.terminator(frame, description) ?: return null
        if (userDefined) {
            val key = encoding.decode(frame, description, descriptionEnd)?.uppercase(Locale.ROOT)
            if (key != "USLT" && key !in lyricKeys) return null
        } else {
            encoding.consumeBom(frame, description)
        }
        val start = descriptionEnd + encoding.terminatorSize
        val end = encoding.terminator(frame, start) ?: frame.size
        return encoding.decode(frame, start, end)?.asLyrics()
    }

    private fun readSyncedId3(frame: ByteArray, data: Int): String? {
        // Only millisecond timestamps and lyrics content are usable here.
        if (frame.size - data < 7 || frame.u8(data + 4) != 2 || frame.u8(data + 5) != 1) return null
        val encoding = Id3LyricsEncoding.from(frame.u8(data)) ?: return null
        val description = data + 6
        val descriptionEnd = encoding.terminator(frame, description) ?: return null
        encoding.consumeBom(frame, description)
        var position = descriptionEnd + encoding.terminatorSize
        val entries = mutableListOf<Pair<Int, String>>()
        while (position < frame.size) {
            val end = encoding.terminator(frame, position) ?: return null
            val timestampPosition = end + encoding.terminatorSize
            if (timestampPosition > frame.size - 4 || entries.size >= MAX_LYRICS_CHARACTERS) return null
            val timestamp = frame.bigInt(timestampPosition, 4)
            if (timestamp !in 0 until 60_000_000) return null // LRC minutes must fit three digits.
            val text = encoding.decode(frame, position, end) ?: return null
            entries.add(timestamp to text.replace("\r\n", "\n").replace('\r', '\n'))
            position = timestampPosition + 4
        }

        val lyrics = StringBuilder()
        var count = 0
        fun addLine(timestamp: Int, text: String): Boolean {
            val line = text.trim()
            if (line.isEmpty()) return true
            if (++count > MAX_CUES || lyrics.length + line.length + 13 > MAX_LYRICS_CHARACTERS) return false
            lyrics.append('[').append((timestamp / 60_000).toString().padStart(2, '0'))
                .append(':').append((timestamp / 1000 % 60).toString().padStart(2, '0'))
                .append('.').append((timestamp % 1000).toString().padStart(3, '0'))
                .append(']').append(line).append('\n')
            return true
        }
        // SYLT can mark syllables inside a line. Respect explicit line boundaries when present.
        if (entries.any { '\n' in it.second }) {
            val line = StringBuilder()
            var start = 0
            for ((timestamp, text) in entries) {
                for ((index, word) in text.split('\n').withIndex()) {
                    if (index > 0) {
                        if (!addLine(start, line.toString())) return null
                        line.clear()
                    }
                    if (line.isEmpty()) start = timestamp
                    line.append(word)
                }
            }
            if (!addLine(start, line.toString())) return null
        } else {
            for ((timestamp, text) in entries) if (!addLine(timestamp, text)) return null
        }
        return lyrics.toString().asLyrics()
    }

    private fun readFlac(input: LyricsMetadataInput): String? {
        while (true) {
            val header = input.read(4) ?: return null
            val flags = header.u8(0)
            val length = header.bigInt(1, 3)
            if (flags and 0x7F == 4) {
                if (length > MAX_COMMENT_BYTES) return null
                val comments = input.read(length) ?: return null
                return readVorbisComments(comments, 0)
            }
            if (flags and 0x80 != 0 || !input.skip(length)) return null
        }
    }

    private fun readOgg(input: LyricsMetadataInput, signature: ByteArray): String? {
        val packet = ByteArrayOutputStream()
        var capture = signature
        var serial: Int? = null
        var sequence = 0
        var codec: String? = null
        var continued = false
        while (capture.ascii(0, 4) == "OggS") {
            val header = input.read(23) ?: return null
            if (header.u8(0) != 0) return null
            val pageFlags = header.u8(1)
            val pageSerial = header.bigInt(10, 4)
            val pageSequence = header.littleInt(14)
            val segments = input.read(header.u8(22)) ?: return null
            if (serial == null) {
                if (pageFlags and 0x02 == 0 || pageSequence != 0) return null
                serial = pageSerial
            }
            if (serial != pageSerial) {
                if (!input.skip(segments.sumOf { it.toInt() and 0xFF })) return null
            } else {
                if (pageSequence != sequence++ || (pageFlags and 0x01 != 0) != continued) return null
                for (segment in segments) {
                    val length = segment.toInt() and 0xFF
                    // The comment packet can include cover art in addition to short lyrics.
                    if (packet.size() + length > MAX_COMMENT_BYTES) return null
                    packet.write(input.read(length) ?: return null)
                    continued = length == 255
                    if (continued) continue

                    val bytes = packet.toByteArray()
                    when (codec) {
                        "vorbis" -> return if (bytes.startsWith("\u0003vorbis")) readVorbisComments(bytes, 7) else null
                        "opus" -> return if (bytes.startsWith("OpusTags")) readVorbisComments(bytes, 8) else null
                        "flac" -> return if (bytes.size >= 4 && bytes.u8(0) and 0x7F == 4 &&
                            bytes.bigInt(1, 3) == bytes.size - 4) readVorbisComments(bytes, 4) else null
                    }
                    codec = when {
                        bytes.startsWith("\u0001vorbis") -> "vorbis"
                        bytes.startsWith("OpusHead") -> "opus"
                        bytes.startsWith("\u007FFLAC\u0001\u0000") -> "flac"
                        else -> return null
                    }
                    packet.reset()
                }
            }
            capture = input.read(4) ?: return null
        }
        return null
    }

    private fun readVorbisComments(bytes: ByteArray, start: Int): String? {
        var position = start
        fun nextLength(): Int? {
            if (position > bytes.size - 4) return null
            val length = bytes.littleInt(position)
            position += 4
            return length.takeIf { it in 0..(bytes.size - position) }
        }
        val vendorLength = nextLength() ?: return null
        position += vendorLength
        val count = nextLength() ?: return null
        if (count > (bytes.size - position) / 4) return null
        repeat(count) {
            val length = nextLength() ?: return null
            val end = position + length
            val equals = (position until minOf(end, position + 20)).firstOrNull { bytes[it] == '='.code.toByte() }
            if (equals != null && end - equals - 1 <= MAX_LYRICS_BYTES &&
                bytes.ascii(position, equals - position).uppercase(Locale.ROOT) in lyricKeys) {
                decodeText(bytes, equals + 1, end, Charsets.UTF_8)?.asLyrics()?.let { return it }
            }
            position = end
        }
        return null
    }

    private fun readMp4(input: LyricsMetadataInput, firstSize: ByteArray): String? {
        val type = input.read(4)?.ascii(0, 4) ?: return null
        if (type != "ftyp") return null
        val size = firstSize.bigInt(0, 4)
        if (size < 16 || !input.skip(size - 8)) return null
        return readMp4Children(input, MAX_SCAN_BYTES, "")
    }

    // Movie-level iTunes metadata: moov/[udta/]meta/ilst/©lyr/data.
    private fun readMp4Children(input: LyricsMetadataInput, parentEnd: Int, parent: String): String? {
        while (input.position <= parentEnd - 8) {
            val start = input.position
            val header = input.read(8) ?: return null
            val size = header.bigInt(0, 4)
            val type = header.ascii(4, 4)
            val atomSize = if (size == 1) {
                if (parentEnd - input.position < 8) return null
                val extended = input.read(8) ?: return null
                if (extended.bigInt(0, 4) != 0) return null
                extended.bigInt(4, 4)
            } else size
            if (atomSize !in (input.position - start)..(parentEnd - start)) return null
            val end = start + atomSize
            val lyric = when {
                parent == "" && type == "moov" ||
                    parent == "moov" && type == "udta" ||
                    parent == "meta" && type == "ilst" ||
                    parent == "ilst" && type == "©lyr" -> readMp4Children(input, end, type)
                (parent == "moov" || parent == "udta") && type == "meta" -> {
                    // Skip the version and flags in the full box header.
                    if (end - input.position >= 4 && input.skip(4)) readMp4Children(input, end, type) else null
                }
                parent == "©lyr" && type == "data" -> readMp4Text(input, end - input.position)
                else -> null
            }
            if (lyric != null) return lyric
            if (!input.skip(end - input.position)) return null
        }
        return null
    }

    private fun readMp4Text(input: LyricsMetadataInput, length: Int): String? {
        if (length !in 9..(MAX_LYRICS_BYTES + 8)) return null
        val data = input.read(length) ?: return null
        val encoding = when (data.bigInt(0, 4)) {
            1 -> Charsets.UTF_8
            2 -> Charsets.UTF_16BE
            else -> return null
        }
        return decodeText(data, 8, data.size, encoding)?.asLyrics()
    }

    private val lyricFrameIds = setOf("USLT", "ULT", "SYLT", "SLT", "TXXX", "TXX")
    private val lyricKeys = setOf("LYRICS", "UNSYNCEDLYRICS", "UNSYNCED LYRICS", "SYNCEDLYRICS", "SYNCED LYRICS")
}

private class LyricsMetadataInput(private val input: InputStream) {
    private val skipBuffer by lazy { ByteArray(8192) }

    var position = 0
        private set

    fun read(length: Int): ByteArray? {
        if (length !in 0..(MAX_SCAN_BYTES - position)) return null
        val bytes = ByteArray(length)
        var offset = 0
        while (offset < length) {
            val count = input.read(bytes, offset, length - offset)
            if (count <= 0) return null
            offset += count
            position += count
        }
        return bytes
    }

    fun skip(length: Int): Boolean {
        if (length !in 0..(MAX_SCAN_BYTES - position)) return false
        val end = position + length
        while (position < end) {
            val remaining = end - position
            val skipped = input.skip(remaining.toLong()).toInt()
            val count = if (skipped > 0) skipped else input.read(skipBuffer, 0, minOf(remaining, skipBuffer.size))
            if (count <= 0) return false
            position += count
        }
        return true
    }
}

private class Id3LyricsEncoding(private var charset: Charset, val terminatorSize: Int, private val hasBom: Boolean) {
    fun terminator(bytes: ByteArray, start: Int): Int? =
        (start..(bytes.size - terminatorSize) step terminatorSize).firstOrNull { offset ->
            bytes.u8(offset) == 0 && (terminatorSize == 1 || bytes.u8(offset + 1) == 0)
        }

    fun consumeBom(bytes: ByteArray, start: Int): Int {
        if (!hasBom || start > bytes.size - 2) return start
        charset = when (bytes.bigInt(start, 2)) {
            0xFEFF -> Charsets.UTF_16BE
            0xFFFE -> Charsets.UTF_16LE
            else -> return start
        }
        return start + 2
    }

    fun decode(bytes: ByteArray, start: Int, end: Int): String? =
        decodeText(bytes, consumeBom(bytes, start), end, charset)

    companion object {
        fun from(encoding: Int): Id3LyricsEncoding? = when (encoding) {
            0 -> Id3LyricsEncoding(Charsets.ISO_8859_1, 1, false)
            1 -> Id3LyricsEncoding(Charsets.UTF_16BE, 2, true)
            2 -> Id3LyricsEncoding(Charsets.UTF_16BE, 2, false)
            3 -> Id3LyricsEncoding(Charsets.UTF_8, 1, false)
            else -> null
        }
    }
}

private fun decodeText(bytes: ByteArray, start: Int, end: Int, charset: Charset): String? {
    if (start > end) return null
    return try {
        charset.newDecoder().decode(ByteBuffer.wrap(bytes, start, end - start)).toString()
    } catch (_: CharacterCodingException) {
        null
    }
}

private fun String.asLyrics(): String? = trim { it.isWhitespace() || it == '\u0000' || it == '\uFEFF' }
    .takeIf { it.isNotEmpty() && it.length <= MAX_LYRICS_CHARACTERS }

private fun ByteArray.u8(index: Int): Int = this[index].toInt() and 0xFF
private fun ByteArray.ascii(start: Int, length: Int): String = String(this, start, length, Charsets.ISO_8859_1)
private fun ByteArray.startsWith(value: String): Boolean = size >= value.length && ascii(0, value.length) == value

private fun ByteArray.bigInt(start: Int, length: Int): Int =
    (start until start + length).fold(0) { value, offset -> (value shl 8) or u8(offset) }

private fun ByteArray.littleInt(start: Int): Int =
    (start + 3 downTo start).fold(0) { value, offset -> (value shl 8) or u8(offset) }

private fun ByteArray.synchsafe(start: Int): Int? {
    var value = 0
    for (offset in start until start + 4) {
        val byte = u8(offset)
        if (byte >= 0x80) return null
        value = (value shl 7) or byte
    }
    return value
}

private fun ByteArray.removeUnsynchronisation(): ByteArray {
    val result = ByteArray(size)
    var written = 0
    var position = 0
    while (position < size) {
        val byte = u8(position++)
        result[written++] = byte.toByte()
        if (byte == 0xFF && position < size && u8(position) == 0) position++
    }
    return if (written == size) this else result.copyOf(written)
}
