package com.github.dvbeckwitt.videre

import androidx.annotation.OptIn
import androidx.media3.common.util.UnstableApi
import androidx.media3.extractor.metadata.id3.Id3Decoder
import androidx.media3.extractor.metadata.id3.TextInformationFrame
import java.io.DataInputStream
import java.io.IOException
import java.io.InputStream

private val albumPositionTag = Regex("([0-9]{1,5})(?:\\s*/\\s*[0-9]{1,5})?")

internal fun localAlbumPosition(tag: String?): Int? =
    tag?.trim()?.let(albumPositionTag::matchEntire)?.groupValues?.get(1)?.toIntOrNull()
        ?.takeIf { it in 1..0xffff }

internal data class LocalId3Dates(val release: String?, val original: String?)

private const val id3HeaderSize = 10
private const val maxId3TagBytes = LocalMusicId3.MAX_TAG_SIZE
private val id3DateFrames = setOf("TDRL", "TDOR", "TORY", "TOR", "TDRC", "TYER", "TYE", "TDAT", "TDA")

/** Reads only the leading ID3v2 tag. The platform's legacy year is a separate fallback. */
@OptIn(UnstableApi::class)
internal fun readLocalId3Dates(open: () -> InputStream?): LocalId3Dates? {
    try {
        val stream = open() ?: return null
        return DataInputStream(stream).use { input ->
            val header = ByteArray(id3HeaderSize)
            input.readFully(header)
            if (header[0] != 'I'.code.toByte() || header[1] != 'D'.code.toByte() ||
                header[2] != '3'.code.toByte() || header[3].toInt() !in 2..4) return null
            var size = 0
            for (index in 6..9) {
                val byte = header[index].toInt()
                if (byte < 0) return null
                size = (size shl 7) or byte
            }
            if (size !in 1..maxId3TagBytes) return null
            val data = header.copyOf(id3HeaderSize + size)
            input.readFully(data, id3HeaderSize, size)
            decodeLocalId3Dates(data)
        }
    } catch (denied: SecurityException) {
        throw denied
    } catch (_: IOException) {
        return null
    } catch (_: RuntimeException) {
        return null
    }
}

@OptIn(UnstableApi::class)
internal fun decodeLocalId3TextFrames(data: ByteArray, frameIds: Set<String>): List<TextInformationFrame>? {
    val tags = Id3Decoder { version, first, second, third, fourth ->
        val id = if (version == 2) charArrayOf(first.toChar(), second.toChar(), third.toChar())
            else charArrayOf(first.toChar(), second.toChar(), third.toChar(), fourth.toChar())
        String(id) in frameIds
    }.decode(data, data.size) ?: return null
    return (0 until tags.length()).mapNotNull { tags[it] as? TextInformationFrame }
}

@OptIn(UnstableApi::class)
private fun decodeLocalId3Dates(data: ByteArray): LocalId3Dates? {
    val tags = decodeLocalId3TextFrames(data, id3DateFrames) ?: return null
    val values = buildMap {
        for (frame in tags) {
            frame.values.firstOrNull()?.let { putIfAbsent(frame.id, it.trim()) }
        }
    }
    val legacyDate = localLegacyId3Date(values["TYER"] ?: values["TYE"], values["TDAT"] ?: values["TDA"])
    // Taggers commonly use TDRC for the release date when TDRL is absent.
    return LocalId3Dates(
        localReleaseDate(values["TDRL"]) ?: localReleaseDate(values["TDRC"]) ?: legacyDate,
        sequenceOf("TDOR", "TORY", "TOR").firstNotNullOfOrNull { localReleaseDate(values[it]) },
    )
}
