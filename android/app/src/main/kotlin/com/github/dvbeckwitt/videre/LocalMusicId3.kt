package com.github.dvbeckwitt.videre

import java.io.IOException
import java.nio.ByteBuffer
import java.nio.CharBuffer
import java.nio.charset.CharacterCodingException
import java.nio.charset.CodingErrorAction

/** Edits a leading ID3v2.3 or ID3v2.4 tag within its existing byte range. */
internal object LocalMusicId3 {
    class Unsupported : IOException()
    class NoSpace : IOException()
    class InvalidNumber : IOException()
    class InvalidReleaseDate : IOException()

    data class Inspection(val values: Map<String, String?>, val editableFields: Set<String>, val version: Int)

    data class ArtworkEdit(val image: ByteArray?)
    data class ArtworkState(val editable: Boolean, val hasFrontCover: Boolean, val removable: Boolean)

    const val MAX_ARTWORK_SIZE = 4 * 1024 * 1024
    private const val HEADER_SIZE = 10
    const val MAX_TAG_SIZE = 8 * 1024 * 1024
    private const val MAX_FRAMES = 8192
    private const val MAX_EDIT_LENGTH = 1024
    private const val FRONT_COVER = 3
    private val textFields = mapOf("TIT2" to "title", "TPE1" to "artist", "TALB" to "album", "TPE2" to "albumArtist")
    private data class PositionFields(val number: String, val total: String)
    private val positionFields = mapOf(
        "TRCK" to PositionFields("trackNumber", "trackTotal"),
        "TPOS" to PositionFields("discNumber", "discTotal"),
    )
    private val legacyReleaseFrames = setOf("TYER", "TDAT")
    private val releaseFrames = setOf("TDRL")
    val supportedFields = textFields.values.toSet() +
        positionFields.values.flatMap { listOf(it.number, it.total) } + setOf("genre", "releaseDate")
    private val numberPattern = Regex("[0-9]{1,5}")
    private val pngSignature = byteArrayOf(0x89.toByte(), 0x50, 0x4e, 0x47, 0x0d, 0x0a, 0x1a, 0x0a)
    private val jpegSignature = byteArrayOf(0xff.toByte(), 0xd8.toByte(), 0xff.toByte())

    private data class Frame(val id: String, val start: Int, val end: Int)

    private data class Tag(val version: Int, val frames: List<Frame>, val inspection: Inspection)

    private data class Picture(
        val frame: Frame,
        val encoding: Int,
        val description: String,
        val descriptionStart: Int,
        val imageStart: Int,
    )

    private data class Pictures(val front: Picture?, val otherDescriptions: Set<String>)

    fun tagSize(header: ByteArray): Int {
        if (header.size < HEADER_SIZE || ascii(header, 0, 3) != "ID3" || unsigned(header[3]) !in 3..4 ||
            header[4] != 0.toByte() || header[5] != 0.toByte()) throw Unsupported()
        val size = sizeAt(header, 6, syncSafe = true) + HEADER_SIZE
        if (size !in (2 * HEADER_SIZE + 1)..MAX_TAG_SIZE) throw Unsupported()
        return size
    }

    fun inspect(tag: ByteArray): Map<String, String?> = inspectEditable(tag).values

    fun inspectEditable(tag: ByteArray): Inspection = parse(tag).inspection

    fun artworkState(tag: ByteArray): ArtworkState {
        val parsed = parse(tag)
        return try {
            val hasFrontCover = pictures(tag, parsed).front != null
            ArtworkState(editable = true, hasFrontCover, removable = hasFrontCover && parsed.frames.size > 1)
        } catch (_: Unsupported) {
            ArtworkState(editable = false, hasFrontCover = false, removable = false)
        }
    }

    fun edit(
        tag: ByteArray,
        changes: Map<String, String?>,
        artwork: ArtworkEdit? = null,
        lyrics: LocalMusicUslt.Edit? = null,
    ): ByteArray {
        val parsed = parse(tag)
        val (values, editableFields) = parsed.inspection
        if (changes.keys.any { it !in editableFields }) throw Unsupported()
        val edits = changes.filter { (field, value) -> values[field] != value }
        val pending = mutableMapOf<String, String?>()
        for ((id, field) in textFields) {
            if (field in edits) pending[id] = edits[field]
        }
        for ((id, fields) in positionFields) {
            if (fields.number !in edits && fields.total !in edits) continue
            val number = if (fields.number in edits) edits[fields.number] else values[fields.number]
            val total = if (fields.total in edits) edits[fields.total] else values[fields.total]
            val numberValue = number?.let(::positiveNumber)
            val totalValue = total?.let(::positiveNumber)
            if (totalValue != null && (numberValue == null || totalValue < numberValue)) throw InvalidNumber()
            pending[id] = if (total == null) number else "$number/$total"
        }
        if ("genre" in edits) pending["TCON"] = edits["genre"]
        if ("releaseDate" in edits) {
            val date = edits["releaseDate"]?.let { value ->
                localReleaseDate(value)?.takeIf { it == value && (parsed.version == 4 || it.length != 7) }
                    ?: throw InvalidReleaseDate()
            }
            if (parsed.version == 4) {
                pending["TDRL"] = date
            } else {
                pending["TYER"] = date?.take(4)
                pending["TDAT"] = date?.takeIf { it.length == 10 }?.let { it.takeLast(2) + it.substring(5, 7) }
            }
        }
        val artworkFrames = if (artwork != null) pictures(tag, parsed) else null
        val oldCover = artworkFrames?.front?.frame
        val newCover = artwork?.image?.let { encodeArtwork(tag, it, parsed.version, checkNotNull(artworkFrames)) }
        if (pending.isEmpty() && oldCover == null && newCover == null && lyrics == null) return tag
        val previousLyrics = lyrics?.let { findLyricsFrame(tag, parsed, it) }
        val replacementLyrics = lyrics?.let {
            val payload = LocalMusicUslt.encode(it, parsed.version)
            frameBytes(LocalMusicUslt.ID, payload.size, parsed.version).apply {
                payload.copyInto(this, destinationOffset = HEADER_SIZE)
                checkFalseSync(this)
            }
        }

        val output = ByteArray(tag.size)
        tag.copyInto(output, endIndex = HEADER_SIZE)
        var position = HEADER_SIZE
        var writtenFrames = 0

        fun append(bytes: ByteArray, start: Int, end: Int) {
            if (writtenFrames == MAX_FRAMES) throw Unsupported()
            if (end - start > output.size - position) throw NoSpace()
            bytes.copyInto(output, position, start, end)
            position += end - start
            writtenFrames++
        }

        fun appendText(id: String, value: String) {
            val frame = encodeText(id, value, parsed.version)
            append(frame, 0, frame.size)
        }

        var pendingCover = newCover
        for (frame in parsed.frames) {
            // Some Android readers take the first picture, regardless of type.
            if (frame.id == "APIC" && pendingCover != null) {
                append(pendingCover, 0, pendingCover.size)
                pendingCover = null
            }
            if (frame == oldCover) continue
            if (frame == previousLyrics && replacementLyrics != null) {
                append(replacementLyrics, 0, replacementLyrics.size)
            } else if (frame.id in pending) {
                pending.remove(frame.id)?.let { appendText(frame.id, it) }
            } else {
                append(tag, frame.start, frame.end)
            }
        }
        for ((id, value) in pending) {
            value?.let { appendText(id, it) }
        }
        pendingCover?.let { append(it, 0, it.size) }

        if (previousLyrics == null && replacementLyrics != null) {
            append(replacementLyrics, 0, replacementLyrics.size)
        }

        // A tag must contain a frame. The last byte may not create a false sync with the audio.
        if (position == HEADER_SIZE || unsigned(output.last()) == 0xff) throw Unsupported()
        return output
    }

    private fun pictures(tag: ByteArray, parsed: Tag): Pictures {
        var front: Picture? = null
        val otherDescriptions = mutableSetOf<String>()
        for (frame in parsed.frames) {
            val start = frame.start + HEADER_SIZE
            if (frame.id == "LINK" && ascii(tag, start, 4) == "APIC") throw Unsupported()
            if (frame.id != "APIC") continue
            // Compression, encryption, unsynchronisation and read-only flags
            // can make it unsafe to identify or replace this picture.
            if (tag[frame.start + 8] != 0.toByte() || tag[frame.start + 9] != 0.toByte()) throw Unsupported()
            val encoding = unsigned(tag[start])
            val charset = when (encoding) {
                0 -> Charsets.ISO_8859_1
                1 -> Charsets.UTF_16
                2 -> if (parsed.version == 4) Charsets.UTF_16BE else throw Unsupported()
                3 -> if (parsed.version == 4) Charsets.UTF_8 else throw Unsupported()
                else -> throw Unsupported()
            }
            val descriptionUnit = if (encoding in 1..2) 2 else 1
            val mimeEnd = terminator(tag, start + 1, frame.end, 1)
            val typeAt = mimeEnd + 1
            if (mimeEnd == start + 1 || typeAt >= frame.end) throw Unsupported()
            val descriptionStart = typeAt + 1
            val descriptionEnd = terminator(tag, descriptionStart, frame.end, descriptionUnit)
            val imageStart = descriptionEnd + descriptionUnit
            if (imageStart >= frame.end) throw Unsupported()
            val description = String(tag, descriptionStart, descriptionEnd - descriptionStart, charset)
            if (unsigned(tag[typeAt]) != FRONT_COVER) {
                otherDescriptions.add(description)
                continue
            }
            if (front != null || ascii(tag, start + 1, mimeEnd - start - 1) == "-->") throw Unsupported()
            front = Picture(frame, encoding, description, descriptionStart, imageStart)
        }
        return Pictures(front, otherDescriptions)
    }

    private fun terminator(bytes: ByteArray, start: Int, end: Int, width: Int): Int {
        if (width == 1) {
            for (offset in start until end) if (bytes[offset] == 0.toByte()) return offset
        } else {
            for (offset in start until end - 1 step 2) {
                if (bytes[offset] == 0.toByte() && bytes[offset + 1] == 0.toByte()) return offset
            }
        }
        throw Unsupported()
    }

    private fun encodeArtwork(tag: ByteArray, image: ByteArray, version: Int, pictures: Pictures): ByteArray {
        val mime = imageMime(image) ?: throw Unsupported()
        val label = mime.toByteArray(Charsets.US_ASCII)
        val front = pictures.front?.takeUnless { it.description in pictures.otherDescriptions }
        val description = if (front != null) {
            tag.copyOfRange(front.descriptionStart, front.imageStart)
        } else {
            // Some readers identify pictures by description alone.
            val available = generateSequence(1) { it + 1 }.map {
                if (it == 1) "Front cover" else "Front cover $it"
            }.first { it !in pictures.otherDescriptions }
            val encoded = available.toByteArray(Charsets.ISO_8859_1)
            encoded.copyOf(encoded.size + 1)
        }
        val prefix = ByteArray(label.size + 3 + description.size)
        prefix[0] = (front?.encoding ?: 0).toByte()
        label.copyInto(prefix, destinationOffset = 1)
        prefix[label.size + 2] = FRONT_COVER.toByte()
        description.copyInto(prefix, destinationOffset = label.size + 3)
        val frame = frameBytes("APIC", prefix.size + image.size, version)
        prefix.copyInto(frame, destinationOffset = HEADER_SIZE)
        image.copyInto(frame, destinationOffset = HEADER_SIZE + prefix.size)
        return frame
    }

    fun imageMime(image: ByteArray): String? {
        if (image.size > MAX_ARTWORK_SIZE) return null
        fun startsWith(signature: ByteArray) =
            image.size > signature.size && signature.indices.all { image[it] == signature[it] }
        return when {
            startsWith(pngSignature) -> "image/png"
            startsWith(jpegSignature) -> "image/jpeg"
            else -> null
        }
    }

    private fun findLyricsFrame(tag: ByteArray, parsed: Tag, lyrics: LocalMusicUslt.Edit): Frame? {
        var match: Frame? = null
        for (frame in parsed.frames) {
            val start = frame.start + HEADER_SIZE
            if (frame.id == "LINK" && ascii(tag, start, 4) == LocalMusicUslt.ID) throw Unsupported()
            if (frame.id != LocalMusicUslt.ID) continue

            // Format flags can obscure the key. Status flags matter only on a frame we would replace.
            if (tag[frame.start + 9] != 0.toByte()) throw Unsupported()
            if (LocalMusicUslt.matches(tag, start, frame.end, parsed.version, lyrics)) {
                if (match != null || tag[frame.start + 8] != 0.toByte()) throw Unsupported()
                match = frame
            }
        }
        return match
    }

    private fun parse(tag: ByteArray): Tag {
        if (tagSize(tag) != tag.size) throw Unsupported()
        val version = unsigned(tag[3])
        var position = HEADER_SIZE
        val frames = mutableListOf<Frame>()
        val seenPositions = mutableSetOf<String>()
        val opaquePositions = mutableSetOf<String>()
        val editedReleaseFrames = if (version == 3) legacyReleaseFrames else releaseFrames
        val extraFields = mapOf("TCON" to "genre") + editedReleaseFrames.associateWith { "releaseDate" }
        val extraValues = mutableMapOf<String, String>()
        val opaqueFields = mutableSetOf<String>()
        val values = supportedFields.associateWithTo(linkedMapOf<String, String?>()) { null }

        while (position < tag.size && tag[position] != 0.toByte()) {
            if (tag.size - position < HEADER_SIZE || frames.size == MAX_FRAMES) throw Unsupported()
            val id = ascii(tag, position, 4)
            if (id.any { it !in 'A'..'Z' && it !in '0'..'9' }) throw Unsupported()
            val length = sizeAt(tag, position + 4, syncSafe = version == 4)
            val start = position + HEADER_SIZE
            if (length !in 1..(tag.size - start)) throw Unsupported()
            val end = start + length
            val status = unsigned(tag[position + 8])
            val format = unsigned(tag[position + 9])
            val field = textFields[id]
            if (field != null) {
                // One ordinary, single-value frame per editable field.
                if (status != 0 || format != 0 || values[field] != null) throw Unsupported()
                values[field] = readText(tag, start, end, version)
            } else {
                val discardOnEdit = if (version == 3) 0x80 else 0x40
                // Altering these tags could discard a frame or shadow edited values elsewhere.
                if (status and discardOnEdit != 0 || id == "SEEK" ||
                    (id == "LINK" && (format != 0 || length < 5 || ascii(tag, start, 4) in textFields)) ||
                    (id == "RBUF" && (format != 0 || length != 4 || tag[start + 3] != 0.toByte()))) {
                    throw Unsupported()
                }
                if (id == "LINK") {
                    val target = ascii(tag, start, 4)
                    if (target in positionFields) opaquePositions.add(target)
                    extraFields[target]?.let(opaqueFields::add)
                }
                extraFields[id]?.let { extraField ->
                    // Keep multi-value, duplicate, or flagged frames intact on other edits.
                    val value = if (status == 0 && format == 0 && id !in extraValues) {
                        try { readText(tag, start, end, version) } catch (_: Unsupported) { null }
                    } else null
                    if (value == null) opaqueFields.add(extraField) else extraValues[id] = value
                }
                // Higher-priority, nonstandard date frames would hide a v2.3 edit.
                if (version == 3 && (id == "TDRL" || id == "TDRC")) opaqueFields.add("releaseDate")
                val fields = positionFields[id]
                if (fields != null) {
                    val value = if (seenPositions.add(id) && status == 0 && format == 0) {
                        try {
                            readText(tag, start, end, version)
                        } catch (_: Unsupported) {
                            null
                        }
                    } else null
                    if (value == null) {
                        opaquePositions.add(id)
                    } else {
                        values[fields.number] = value.substringBefore('/').trim().takeIf(String::isNotEmpty)
                        values[fields.total] = value.substringAfter('/', "").trim().takeIf(String::isNotEmpty)
                    }
                }
            }
            frames.add(Frame(id, position, end))
            position = end
        }

        if (frames.isEmpty() || (position until tag.size).any { tag[it] != 0.toByte() }) throw Unsupported()
        val editableFields = (supportedFields - opaqueFields).toMutableSet()
        if ("genre" in editableFields) {
            values["genre"] = extraValues["TCON"]?.takeIf(String::isNotBlank)
        }
        if ("releaseDate" in editableFields) {
            values["releaseDate"] = if (version == 4) localReleaseDate(extraValues["TDRL"])
                else localLegacyId3Date(extraValues["TYER"], extraValues["TDAT"])
        }
        for (id in opaquePositions) {
            val fields = positionFields.getValue(id)
            values[fields.number] = null
            values[fields.total] = null
            editableFields.remove(fields.number)
            editableFields.remove(fields.total)
        }
        return Tag(version, frames, Inspection(values, editableFields, version))
    }

    private fun positiveNumber(value: String): Int =
        value.takeIf(numberPattern::matches)?.toIntOrNull()?.takeIf { it in 1..0xffff } ?: throw InvalidNumber()

    private fun readText(bytes: ByteArray, start: Int, end: Int, version: Int): String {
        var offset = start + 1
        val encoding = unsigned(bytes[start])
        val charset = when (encoding) {
            0 -> Charsets.ISO_8859_1
            1 -> {
                if (end - offset < 2) throw Unsupported()
                val bom = (unsigned(bytes[offset]) shl 8) or unsigned(bytes[offset + 1])
                offset += 2
                when (bom) {
                    0xfeff -> Charsets.UTF_16BE
                    0xfffe -> Charsets.UTF_16LE
                    else -> throw Unsupported()
                }
            }
            2 -> if (version == 4) Charsets.UTF_16BE else throw Unsupported()
            3 -> if (version == 4) Charsets.UTF_8 else throw Unsupported()
            else -> throw Unsupported()
        }
        val value = try {
            charset.newDecoder()
                .onMalformedInput(CodingErrorAction.REPORT)
                .onUnmappableCharacter(CodingErrorAction.REPORT)
                .decode(ByteBuffer.wrap(bytes, offset, end - offset))
                .toString()
                .removeSuffix("\u0000")
        } catch (_: CharacterCodingException) {
            throw Unsupported()
        }
        if (value.any { it.isISOControl() }) throw Unsupported()
        return value
    }

    private fun encodeText(id: String, value: String, version: Int): ByteArray {
        if (value.length > MAX_EDIT_LENGTH || value.any { it.isISOControl() }) throw Unsupported()
        val encoding = when {
            version == 4 -> 3
            value.all { it.code <= 0xff } -> 0
            else -> 1
        }
        val charset = when (encoding) {
            0 -> Charsets.ISO_8859_1
            1 -> Charsets.UTF_16BE
            else -> Charsets.UTF_8
        }
        val encoded = try {
            charset.newEncoder()
                .onMalformedInput(CodingErrorAction.REPORT)
                .onUnmappableCharacter(CodingErrorAction.REPORT)
                .encode(CharBuffer.wrap(value))
        } catch (_: CharacterCodingException) {
            throw Unsupported()
        }

        val prefix = if (encoding == 1) 3 else 1
        val length = prefix + encoded.remaining()
        val frame = frameBytes(id, length, version)
        frame[HEADER_SIZE] = encoding.toByte()
        if (encoding == 1) {
            frame[HEADER_SIZE + 1] = 0xfe.toByte()
            frame[HEADER_SIZE + 2] = 0xff.toByte()
        }
        encoded.get(frame, HEADER_SIZE + prefix, encoded.remaining())

        checkFalseSync(frame)
        return frame
    }

    private fun frameBytes(id: String, length: Int, version: Int): ByteArray {
        val frame = ByteArray(HEADER_SIZE + length)
        id.toByteArray(Charsets.US_ASCII).copyInto(frame)
        val shift = if (version == 4) 7 else 8
        val mask = (1 shl shift) - 1
        for (i in 0..3) frame[4 + i] = ((length shr ((3 - i) * shift)) and mask).toByte()
        return frame
    }

    private fun checkFalseSync(frame: ByteArray) {
        // v2.3 unsynchronisation changes the entire tag's byte representation.
        if ((0 until frame.lastIndex).any { unsigned(frame[it]) == 0xff && unsigned(frame[it + 1]) >= 0xe0 }) {
            throw Unsupported()
        }
    }

    private fun sizeAt(bytes: ByteArray, offset: Int, syncSafe: Boolean): Int {
        val shift = if (syncSafe) 7 else 8
        var value = 0L
        for (i in offset until offset + 4) {
            val byte = unsigned(bytes[i])
            if (syncSafe && byte >= 0x80) throw Unsupported()
            value = (value shl shift) or byte.toLong()
        }
        if (value > MAX_TAG_SIZE) throw Unsupported()
        return value.toInt()
    }

    private fun ascii(bytes: ByteArray, start: Int, length: Int): String =
        String(bytes, start, length, Charsets.ISO_8859_1)

    private fun unsigned(value: Byte): Int = value.toInt() and 0xff
}
