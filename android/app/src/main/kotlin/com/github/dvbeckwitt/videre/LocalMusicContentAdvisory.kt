package com.github.dvbeckwitt.videre

import java.io.DataInputStream
import java.io.EOFException
import java.io.InputStream
import java.nio.ByteBuffer

internal enum class LocalMusicAdvisory(val channelValue: Int?) {
    EXPLICIT(1),
    CLEAN(2),
    UNKNOWN(null);

    companion object {
        fun fromTag(value: Int) = when (value) {
            1, 4 -> EXPLICIT
            2 -> CLEAN
            else -> UNKNOWN
        }
    }
}

/** Reads the same iTunes MP4 rating atom used by the Now Playing advisory. */
internal fun readLocalMusicContentAdvisory(
    input: InputStream,
    length: Long? = null,
    seekForward: ((Long) -> Boolean)? = null,
    checkCanceled: () -> Unit = {},
): LocalMusicAdvisory = try {
    LocalMusicMp4AdvisoryReader(DataInputStream(input), seekForward, checkCanceled).read(length)
} catch (_: EOFException) {
    LocalMusicAdvisory.UNKNOWN
}

private class LocalMusicMp4AdvisoryReader(
    private val input: DataInputStream,
    private val seekForward: ((Long) -> Boolean)?,
    private val checkCanceled: () -> Unit,
) {
    private var position = 0L
    private var atoms = 0
    private var streamBytesLeft = 4L * 1024 * 1024
    private var sawFileType = false
    private var advisory = LocalMusicAdvisory.UNKNOWN
    private val header = ByteArray(8)
    private val headerValues = ByteBuffer.wrap(header)
    private val skipBuffer by lazy { ByteArray(8192) }

    fun read(length: Long?): LocalMusicAdvisory =
        if (readAtoms(length, "")) advisory else LocalMusicAdvisory.UNKNOWN

    private fun readAtoms(limit: Long?, parent: String): Boolean {
        while (limit == null || position < limit) {
            checkCanceled()
            if (++atoms > 4096 || (limit != null && limit - position < 8)) return false
            val first = input.read()
            if (first < 0) return limit == null
            val start = position
            header[0] = first.toByte()
            input.readFully(header, 1, 7)
            var size = headerValues.getInt(0).toLong() and 0xffffffffL
            val type = String(header, 4, 4, Charsets.ISO_8859_1)
            position += 8
            when (size) {
                0L -> size = (limit ?: return false) - start
                1L -> {
                    if (limit != null && limit - position < 8) return false
                    size = input.readLong()
                    position += 8
                }
            }
            if (size < position - start || size > (limit ?: Long.MAX_VALUE) - start) return false
            val end = start + size
            if (parent.isEmpty() && !sawFileType) {
                when (type) {
                    "ftyp" -> {
                        if (end - position < 8 || (end - position) % 4 != 0L) return false
                        sawFileType = true
                    }
                    "free", "skip", "wide" -> Unit
                    else -> return false
                }
            }
            val valid = when (parent to type) {
                "" to "moov", "moov" to "udta", "meta" to "ilst" -> readAtoms(end, type)
                "moov" to "meta", "udta" to "meta" -> {
                    // ISO MP4 meta is a version-zero full box.
                    if (end - position < 4 || input.readInt() != 0) return false
                    position += 4
                    readAtoms(end, type)
                }
                "ilst" to "rtng" -> readRating(end)
                else -> skipTo(end)
            }
            if (!valid) return false
        }
        return true
    }

    private fun readRating(end: Long): Boolean {
        // The iTunes advisory is a single one-byte integer data atom.
        if (end - position != 17L || input.readInt() != 17 || input.readInt() != 0x64617461) return false
        val dataType = input.readInt()
        if (dataType != 0 && dataType != 21) return false
        input.readInt() // Locale.
        val rating = LocalMusicAdvisory.fromTag(input.readUnsignedByte())
        position = end
        if (rating == LocalMusicAdvisory.UNKNOWN ||
            (advisory != LocalMusicAdvisory.UNKNOWN && advisory != rating)) return false
        advisory = rating
        return true
    }

    private fun skipTo(end: Long): Boolean {
        var bytes = end - position
        if (bytes == 0L) return true
        if (bytes > skipBuffer.size && seekForward?.invoke(bytes - 1) == true) {
            // Verify the atom ends within the available bytes even if seek passed EOF.
            input.readUnsignedByte()
        } else {
            if (bytes > streamBytesLeft) return false
            streamBytesLeft -= bytes
            while (bytes > 0) {
                checkCanceled()
                val count = minOf(bytes, skipBuffer.size.toLong()).toInt()
                input.readFully(skipBuffer, 0, count)
                bytes -= count
            }
        }
        position = end
        return true
    }
}
