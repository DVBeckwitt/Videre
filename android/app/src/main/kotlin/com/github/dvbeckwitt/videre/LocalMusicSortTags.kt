package com.github.dvbeckwitt.videre

import java.io.DataInputStream
import java.io.EOFException
import java.io.InputStream
import java.nio.ByteBuffer
import java.nio.ByteOrder
import java.nio.charset.CharacterCodingException
import java.nio.charset.Charset

internal data class LocalMusicSortTags(
    val title: String? = null,
    val artist: String? = null,
    val album: String? = null,
    val albumArtist: String? = null,
)

private const val MAX_METADATA_BYTES = 4 * 1024 * 1024
private const val MAX_COMMENT_BYTES = 512 * 1024
private const val MAX_SORT_TEXT_BYTES = 4 * 1024 + 4
private const val ID3_HEADER_BYTES = 10

private enum class SortField(val id3: String, val vorbis: String) {
    TITLE("TSOT", "TITLESORT"),
    ARTIST("TSOP", "ARTISTSORT"),
    ALBUM("TSOA", "ALBUMSORT"),
    ALBUM_ARTIST("TSO2", "ALBUMARTISTSORT"),
}

/** Reads explicit sort keys from a leading ID3v2.3/v2.4 tag or native FLAC metadata. */
internal fun readLocalMusicSortTags(input: InputStream): LocalMusicSortTags {
    val data = DataInputStream(input)
    val tags = try {
        val prefix = data.readInt()
        when {
            prefix ushr 8 == 0x494433 -> readId3(data, prefix and 0xff)
            prefix == 0x664c6143 -> readFlac(data)
            else -> null
        }
    } catch (_: EOFException) {
        null
    }
    return tags ?: LocalMusicSortTags()
}

private fun readId3(data: DataInputStream, version: Int): LocalMusicSortTags? {
    if (version != 3 && version != 4) return null
    // Whole-tag unsynchronisation and extended headers can change frame offsets.
    if (data.readUnsignedByte() != 0 || data.readUnsignedByte() != 0) return null
    var remaining = synchsafeSize(data.readInt()) ?: return null
    if (remaining > MAX_METADATA_BYTES - ID3_HEADER_BYTES) return null

    val values = mutableMapOf<SortField, String?>()
    val header = ByteArray(ID3_HEADER_BYTES)
    var frames = 0
    while (remaining >= header.size) {
        if (++frames > 4096) return null
        data.readFully(header)
        remaining -= header.size
        if (header[0] == 0.toByte()) {
            if (header.any { it != 0.toByte() }) return null
            break
        }

        val id = String(header, 0, 4, Charsets.US_ASCII)
        if (!id.all { it in 'A'..'Z' || it in '0'..'9' }) return null
        val rawSize = ByteBuffer.wrap(header, 4, 4).int
        val size = (if (version == 4) synchsafeSize(rawSize) else rawSize) ?: return null
        if (size <= 0 || size > remaining) return null

        val field = SortField.entries.firstOrNull { it.id3 == id }
        val statusMask = if (version == 3) 0x1f else 0x8f
        if (field != null && size <= MAX_SORT_TEXT_BYTES &&
            header[8].toInt() and statusMask == 0 && header[9] == 0.toByte()) {
            val body = ByteArray(size)
            data.readFully(body)
            values.addTag(field, decodeId3Text(body, version))
        } else {
            data.skipFully(size)
            if (field != null) values.addTag(field, null)
        }
        remaining -= size
    }
    if (!data.readPadding(remaining)) return null
    return values.toSortTags()
}

private fun synchsafeSize(raw: Int): Int? {
    if (raw and 0x80808080.toInt() != 0) return null
    return ((raw ushr 24) shl 21) or ((raw ushr 16 and 0x7f) shl 14) or
        ((raw ushr 8 and 0x7f) shl 7) or (raw and 0x7f)
}

private fun decodeId3Text(bytes: ByteArray, version: Int): String? {
    val encoding = when (bytes[0].toInt()) {
        0 -> Charsets.ISO_8859_1
        1 -> {
            if (bytes.size < 3) return null
            val bom = ((bytes[1].toInt() and 0xff) shl 8) or (bytes[2].toInt() and 0xff)
            if (bom != 0xfeff && bom != 0xfffe) return null
            Charsets.UTF_16
        }
        2 -> if (version == 4) Charsets.UTF_16BE else return null
        3 -> if (version == 4) Charsets.UTF_8 else return null
        else -> return null
    }
    val text = decodeText(ByteBuffer.wrap(bytes, 1, bytes.size - 1), encoding)
    return text?.removeSuffix("\u0000")
}

private fun readFlac(data: DataInputStream): LocalMusicSortTags? {
    var remaining = MAX_METADATA_BYTES - 4
    var tags: LocalMusicSortTags? = null
    repeat(256) { index ->
        if (remaining < 4) return null
        val header = data.readInt()
        val type = header ushr 24 and 0x7f
        val size = header and 0xffffff
        remaining -= 4
        if (size > remaining || type == 127) return null
        if ((index == 0 && (type != 0 || size != 34)) || (index > 0 && type == 0)) return null
        if (type == 4) {
            if (tags != null || size > MAX_COMMENT_BYTES) return null
            val body = ByteArray(size)
            data.readFully(body)
            tags = readVorbisComments(body) ?: return null
        } else {
            data.skipFully(size)
        }
        if (header < 0) return tags
        remaining -= size
    }
    return null
}

private fun readVorbisComments(bytes: ByteArray): LocalMusicSortTags? {
    val data = ByteBuffer.wrap(bytes).order(ByteOrder.LITTLE_ENDIAN)
    data.readVorbisString() ?: return null // vendor
    if (data.remaining() < 4) return null
    val count = data.int
    if (count !in 0..1024) return null

    val values = mutableMapOf<SortField, String?>()
    repeat(count) {
        val comment = data.readVorbisString() ?: return null
        val separator = comment.indexOf('=')
        if (separator < 1) return null
        val key = comment.substring(0, separator)
        if (!key.all { it in ' '..'~' }) return null
        val field = SortField.entries.firstOrNull { it.vorbis.equals(key, ignoreCase = true) }
        if (field != null) values.addTag(field, comment.substring(separator + 1))
    }
    if (data.hasRemaining()) return null
    return values.toSortTags()
}

private fun ByteBuffer.readVorbisString(): String? {
    if (remaining() < 4) return null
    val size = int
    if (size !in 0..remaining()) return null
    val content = slice().apply { limit(size) }
    position(position() + size)
    return decodeText(content, Charsets.UTF_8)
}

private fun decodeText(bytes: ByteBuffer, charset: Charset): String? = try {
    charset.newDecoder().decode(bytes).toString()
} catch (_: CharacterCodingException) {
    null
}

private fun MutableMap<SortField, String?>.addTag(field: SortField, text: String?) {
    val value = text?.trim()?.takeIf {
        it.isNotEmpty() && it.length <= 1024 && !it.equals("<unknown>", ignoreCase = true) &&
            text.none(Char::isISOControl)
    }
    this[field] = if (field in this) null else value
}

private fun Map<SortField, String?>.toSortTags() = LocalMusicSortTags(
    title = this[SortField.TITLE],
    artist = this[SortField.ARTIST],
    album = this[SortField.ALBUM],
    albumArtist = this[SortField.ALBUM_ARTIST],
)

private fun DataInputStream.skipFully(size: Int) {
    if (size == 0) return
    // A seekable stream may report a successful skip beyond EOF.
    var remaining = size - skipBytes(size - 1)
    if (remaining == 1) {
        readByte()
        return
    }
    val buffer = ByteArray(minOf(remaining, 8192))
    while (remaining > 0) {
        val count = minOf(remaining, buffer.size)
        readFully(buffer, 0, count)
        remaining -= count
    }
}

private fun DataInputStream.readPadding(size: Int): Boolean {
    var remaining = size
    val buffer = ByteArray(minOf(size, 8192))
    while (remaining > 0) {
        val count = minOf(remaining, buffer.size)
        readFully(buffer, 0, count)
        if ((0 until count).any { buffer[it] != 0.toByte() }) return false
        remaining -= count
    }
    return true
}
