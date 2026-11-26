package com.github.dvbeckwitt.videre

import androidx.annotation.OptIn
import androidx.media3.common.util.UnstableApi
import androidx.media3.extractor.metadata.id3.Id3Util
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
    val discSubtitle: String? = null,
    val discSubtitleRead: Boolean = true,
    val releaseKind: LocalMusicReleaseKind? = null,
    val releaseKindRead: Boolean = true,
)

internal data class LocalMusicTagValues(
    val artists: List<String> = emptyList(),
    val albumArtists: List<String> = emptyList(),
    val genres: List<String> = emptyList(),
)

internal data class LocalMusicReadTags(
    val sortTags: LocalMusicSortTags = LocalMusicSortTags(),
    val values: LocalMusicTagValues = LocalMusicTagValues(),
)

internal enum class LocalMusicReleaseKind(val tag: String) {
    // Refinements take precedence over the base type in multivalued tags.
    LIVE("live"),
    REMIX("remix"),
    COMPILATION("compilation"),
    SOUNDTRACK("soundtrack"),
    DJ_MIX("dj-mix"),
    MIXTAPE("mixtape"),
    DEMO("demo"),
    ALBUM("album"),
    EP("ep"),
    SINGLE("single");

    companion object {
        fun fromTag(tag: String?): LocalMusicReleaseKind? = entries.firstOrNull { it.tag == tag }
    }
}

private val primaryReleaseKinds = setOf(
    LocalMusicReleaseKind.ALBUM, LocalMusicReleaseKind.EP, LocalMusicReleaseKind.SINGLE,
)

private const val ID3_RELEASE_TYPE = "MusicBrainz Album Type"
private const val VORBIS_RELEASE_TYPE = "RELEASETYPE"
private const val MAX_METADATA_BYTES = 4 * 1024 * 1024
private const val MAX_COMMENT_BYTES = 512 * 1024
private const val MAX_TAG_TEXT_BYTES = 4 * 1024 + 4
private const val MAX_TAG_VALUES = 1024
private const val MAX_TAG_VALUE_CHARACTERS = 64 * 1024
private const val ID3_HEADER_BYTES = 10
private val id3ValueFrames = setOf("TPE1", "TP1", "TPE2", "TP2", "TCON", "TCO")

private enum class TextField(val id3: String, val vorbis: String) {
    TITLE("TSOT", "TITLESORT"),
    ARTIST("TSOP", "ARTISTSORT"),
    ALBUM("TSOA", "ALBUMSORT"),
    ALBUM_ARTIST("TSO2", "ALBUMARTISTSORT"),
    DISC_SUBTITLE("TSST", "DISCSUBTITLE"),
}

/** Reads embedded credit and genre lists, sort keys, disc subtitles, and release types. */
internal fun readLocalMusicTags(input: InputStream): LocalMusicReadTags {
    val data = DataInputStream(input)
    val tags = try {
        val prefix = data.readInt()
        when {
            prefix ushr 8 == 0x494433 -> readId3(data, prefix)
            prefix == 0x664c6143 -> readFlac(data)
            prefix == 0x4f676753 -> readLocalOggComments(data)?.let {
                readVorbisComments(it.bytes, it.prefixLength, it.end)
            }
            else -> null
        }
    } catch (_: EOFException) {
        null
    }
    return tags ?: LocalMusicReadTags()
}

@OptIn(UnstableApi::class)
private fun readId3(data: DataInputStream, prefix: Int): LocalMusicReadTags? {
    val version = prefix and 0xff
    if (version !in 2..4) return null
    val header = ByteBuffer.allocate(ID3_HEADER_BYTES).putInt(prefix).array()
    data.readFully(header, 4, ID3_HEADER_BYTES - 4)
    val size = synchsafeSize(ByteBuffer.wrap(header, 6, 4).int) ?: return null
    if (size > MAX_METADATA_BYTES - ID3_HEADER_BYTES) return null

    val tag = header.copyOf(ID3_HEADER_BYTES + size)
    data.readFully(tag, ID3_HEADER_BYTES, size)
    val sort = DataInputStream(tag.inputStream(ID3_HEADER_BYTES, size)).let {
        readId3SortTags(it, version, header[4].toInt(), header[5].toInt(), size)
    }
    val values = TagValues()
    // Media3 may adjust the tag bytes in place when removing unsynchronisation.
    val text = try {
        decodeLocalId3TextFrames(tag, id3ValueFrames)
    } catch (_: RuntimeException) {
        null
    }
    frames@ for (frame in text.orEmpty()) {
        val key = when (frame.id) {
            "TPE1", "TP1" -> "ARTIST"
            "TPE2", "TP2" -> "ALBUMARTIST"
            "TCON", "TCO" -> "GENRE"
            else -> continue
        }
        for (value in frame.values) {
            if (values.full) break@frames
            val valid = musicTagText(value) ?: continue
            values.add(key, if (key == "GENRE") decodeId3Genre(valid) else valid)
        }
    }
    return LocalMusicReadTags(sort ?: LocalMusicSortTags(), values.build())
}

@OptIn(UnstableApi::class)
private fun decodeId3Genre(value: String): String {
    val code = if (value.startsWith('(') && value.endsWith(')')) value.substring(1, value.lastIndex) else value
    return code.toIntOrNull()?.let(Id3Util::resolveV1Genre) ?: value
}

private fun readId3SortTags(
    data: DataInputStream, version: Int, revision: Int, flags: Int, size: Int,
): LocalMusicSortTags? {
    if (version != 3 && version != 4) return null
    // Whole-tag unsynchronisation and extended headers can change frame offsets.
    if (revision != 0 || flags != 0) return null
    var remaining = size

    val values = mutableMapOf<TextField, String?>()
    var releaseKind: LocalMusicReleaseKind? = null
    var releaseTypeSeen = false
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

        val field = TextField.entries.firstOrNull { it.id3 == id }
        val statusMask = if (version == 3) 0x1f else 0x8f
        if ((field != null || id == "TXXX") && size <= MAX_TAG_TEXT_BYTES &&
            header[8].toInt() and statusMask == 0 && header[9] == 0.toByte()) {
            val body = ByteArray(size)
            data.readFully(body)
            val text = decodeId3Text(body, version)
            if (field != null) {
                values.addTag(field, text)
            } else if (text != null && text.substringBefore('\u0000').equals(ID3_RELEASE_TYPE, ignoreCase = true)) {
                // ID3 permits one TXXX frame per description. Its values may be
                // NUL-separated (2.4) or joined into one string (2.3).
                releaseKind = if (releaseTypeSeen) null else parseReleaseKind(
                    text.splitToSequence('\u0000').drop(1).map { it.trimStart('\ufeff') },
                )
                releaseTypeSeen = true
            }
        } else {
            data.skipFully(size)
            if (field != null) values.addTag(field, null)
        }
        remaining -= size
    }
    if (!data.readPadding(remaining)) return null
    return values.toSortTags(releaseKind)
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

private fun readFlac(data: DataInputStream): LocalMusicReadTags? {
    var remaining = MAX_METADATA_BYTES - 4
    var tags: LocalMusicReadTags? = null
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

private fun readVorbisComments(
    bytes: ByteArray, offset: Int = 0, end: VorbisCommentEnd = VorbisCommentEnd.Exact,
): LocalMusicReadTags? {
    val data = ByteBuffer.wrap(bytes, offset, bytes.size - offset).order(ByteOrder.LITTLE_ENDIAN)
    data.readVorbisString() ?: return null // vendor
    if (data.remaining() < 4) return null
    val count = data.int
    if (count !in 0..MAX_TAG_VALUES) return null

    val sorts = mutableMapOf<TextField, String?>()
    val values = TagValues()
    val releaseTypes = mutableListOf<String>()
    repeat(count) {
        val comment = data.readVorbisString() ?: return null
        val separator = comment.indexOf('=')
        if (separator < 1) return null
        val key = comment.substring(0, separator)
        if (!key.all { it in ' '..'~' }) return null
        val text = comment.substring(separator + 1)
        if (end == VorbisCommentEnd.Exact) {
            val field = TextField.entries.firstOrNull { it.vorbis.equals(key, ignoreCase = true) }
            if (field != null) sorts.addTag(field, text)
            if (key.equals(VORBIS_RELEASE_TYPE, ignoreCase = true)) releaseTypes.add(text)
        }
        musicTagText(text)?.let { values.add(key.uppercase(), it) }
    }
    if (end == VorbisCommentEnd.Exact && data.hasRemaining()) return null
    if (end == VorbisCommentEnd.FramingBit && (!data.hasRemaining() || data.get().toInt() and 1 == 0)) return null
    return LocalMusicReadTags(sorts.toSortTags(parseReleaseKind(releaseTypes.asSequence())), values.build())
}

private fun parseReleaseKind(values: Sequence<String>): LocalMusicReleaseKind? {
    val kinds = values
        .filter { it.length <= 1024 && it.none(Char::isISOControl) }
        .flatMap { it.splitToSequence(';') }
        .mapNotNull { token ->
            when (val normalized = token.trim().lowercase()) {
                "mixtape/street" -> LocalMusicReleaseKind.MIXTAPE
                else -> LocalMusicReleaseKind.fromTag(normalized)
            }
        }.toSet()
    if (kinds.count { it in primaryReleaseKinds } > 1) return null
    return LocalMusicReleaseKind.entries.firstOrNull { it in kinds }
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

private fun MutableMap<TextField, String?>.addTag(field: TextField, text: String?) {
    val value = musicTagText(text)
    this[field] = when {
        field !in this -> value
        field == TextField.DISC_SUBTITLE && this[field] == value -> value
        else -> null
    }
}

private fun musicTagText(text: String?): String? = text?.trim()?.takeIf {
    it.isNotEmpty() && it.length <= 1024 && !it.equals("<unknown>", ignoreCase = true) &&
        text.none(Char::isISOControl)
}

private class TagValues {
    private val artists = mutableListOf<String>()
    private val albumArtists = mutableListOf<String>()
    private val genres = mutableListOf<String>()
    private var count = 0
    private var characters = 0

    val full get() = count == MAX_TAG_VALUES || characters == MAX_TAG_VALUE_CHARACTERS

    fun add(key: String, text: String) {
        if (full || text.length > MAX_TAG_VALUE_CHARACTERS - characters) return
        val values = when (key) {
            "ARTIST" -> artists
            "ALBUMARTIST", "ALBUM ARTIST" -> albumArtists
            "GENRE" -> genres
            else -> return
        }
        values.add(text)
        count++
        characters += text.length
    }

    fun build() = LocalMusicTagValues(artists, albumArtists, genres)
}

private fun Map<TextField, String?>.toSortTags(releaseKind: LocalMusicReleaseKind?) = LocalMusicSortTags(
    title = this[TextField.TITLE],
    artist = this[TextField.ARTIST],
    album = this[TextField.ALBUM],
    albumArtist = this[TextField.ALBUM_ARTIST],
    discSubtitle = this[TextField.DISC_SUBTITLE],
    releaseKind = releaseKind,
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
