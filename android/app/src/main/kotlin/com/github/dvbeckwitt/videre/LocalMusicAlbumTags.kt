package com.github.dvbeckwitt.videre

import androidx.annotation.OptIn
import androidx.media3.common.util.UnstableApi
import androidx.media3.extractor.metadata.id3.Id3Decoder
import androidx.media3.extractor.metadata.id3.TextInformationFrame
import java.io.DataInputStream
import java.io.IOException
import java.io.InputStream

private val albumPositionTag = Regex("([0-9]{1,5})(?:\\s*/\\s*[0-9]{1,5})?")
private val musicDateTag = Regex(
    "([0-9]{4})(?:-([0-9]{2})(?:-([0-9]{2})(?:T[0-9]{2}(?::[0-9]{2}){0,2}" +
        "(?:\\.[0-9]+)?(?:Z|[+-][0-9]{2}:?[0-9]{2})?)?)?)?",
)

internal fun localAlbumPosition(tag: String?): Int? =
    tag?.trim()?.let(albumPositionTag::matchEntire)?.groupValues?.get(1)?.toIntOrNull()
        ?.takeIf { it in 1..0xffff }

internal fun localReleaseDate(tag: String?): String? {
    val match = tag?.trim()?.let(musicDateTag::matchEntire) ?: return null
    val (_, yearText, monthText, dayText) = match.groupValues
    val year = yearText.toInt()
    if (year == 0) return null
    if (monthText.isEmpty()) return yearText
    val month = monthText.toInt()
    if (month !in 1..12) return null
    if (dayText.isEmpty()) return "$yearText-$monthText"
    val lastDay = when (month) {
        2 -> if (year % 4 == 0 && (year % 100 != 0 || year % 400 == 0)) 29 else 28
        4, 6, 9, 11 -> 30
        else -> 31
    }
    return "$yearText-$monthText-$dayText".takeIf { dayText.toInt() in 1..lastDay }
}

internal data class LocalId3Dates(val release: String?, val original: String?)

private const val id3HeaderSize = 10
private const val maxId3TagBytes = 2 * 1024 * 1024
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
private fun decodeLocalId3Dates(data: ByteArray): LocalId3Dates? {
    val tags = Id3Decoder { version, first, second, third, fourth ->
        val id = if (version == 2) charArrayOf(first.toChar(), second.toChar(), third.toChar())
            else charArrayOf(first.toChar(), second.toChar(), third.toChar(), fourth.toChar())
        String(id) in id3DateFrames
    }.decode(data, data.size) ?: return null
    val values = buildMap {
        for (index in 0 until tags.length()) {
            val frame = tags[index] as? TextInformationFrame ?: continue
            frame.values.firstOrNull()?.let { putIfAbsent(frame.id, it.trim()) }
        }
    }
    val legacyYear = localReleaseDate(values["TYER"] ?: values["TYE"])
    val dayMonth = (values["TDAT"] ?: values["TDA"])?.takeIf { it.length == 4 }
    val legacyDate = if (legacyYear?.length == 4 && dayMonth != null) {
        localReleaseDate("$legacyYear-${dayMonth.takeLast(2)}-${dayMonth.take(2)}")
    } else null
    // Taggers commonly use TDRC for the release date when TDRL is absent.
    return LocalId3Dates(
        localReleaseDate(values["TDRL"]) ?: localReleaseDate(values["TDRC"]) ?: legacyDate ?: legacyYear,
        sequenceOf("TDOR", "TORY", "TOR").firstNotNullOfOrNull { localReleaseDate(values[it]) },
    )
}
