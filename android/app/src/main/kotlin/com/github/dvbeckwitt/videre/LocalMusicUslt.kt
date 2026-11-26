package com.github.dvbeckwitt.videre

import java.nio.ByteBuffer
import java.nio.CharBuffer
import java.nio.charset.CharacterCodingException
import java.nio.charset.Charset

/** Builds an unsynchronised lyrics frame payload and identifies its language and descriptor key. */
internal object LocalMusicUslt {
    const val ID = "USLT"

    private const val PREFIX_SIZE = 4 // Encoding byte and three language bytes.
    private const val MAX_DESCRIPTOR_LENGTH = 256
    private const val MAX_TEXT_LENGTH = 128 * 1024
    private const val BOM_BIG_ENDIAN = 0xfeff
    private const val BOM_LITTLE_ENDIAN = 0xfffe
    private val languageCode = Regex("[a-z]{3}")

    data class Edit(val language: String, val descriptor: String, val text: String)

    private enum class Encoding(val id: Int, val charset: Charset, val terminatorSize: Int) {
        LATIN1(0, Charsets.ISO_8859_1, 1),
        UTF16(1, Charsets.UTF_16, 2),
        UTF16_BE(2, Charsets.UTF_16BE, 2),
        UTF8(3, Charsets.UTF_8, 1),
    }

    fun matches(tag: ByteArray, start: Int, end: Int, version: Int, edit: Edit): Boolean {
        if (end - start < PREFIX_SIZE) throw LocalMusicId3.Unsupported()
        if (String(tag, start + 1, 3, Charsets.US_ASCII) != edit.language) return false

        val encoding = when (tag[start].toInt()) {
            0 -> Encoding.LATIN1
            1 -> Encoding.UTF16
            2 -> if (version == 4) Encoding.UTF16_BE else throw LocalMusicId3.Unsupported()
            3 -> if (version == 4) Encoding.UTF8 else throw LocalMusicId3.Unsupported()
            else -> throw LocalMusicId3.Unsupported()
        }
        val descriptorStart = start + PREFIX_SIZE
        val width = encoding.terminatorSize
        val descriptorEnd = (descriptorStart..end - width step width).firstOrNull {
            tag[it] == 0.toByte() && (width == 1 || tag[it + 1] == 0.toByte())
        } ?: throw LocalMusicId3.Unsupported()
        if (descriptorStart == descriptorEnd) return edit.descriptor.isEmpty()

        val descriptor = ByteBuffer.wrap(tag, descriptorStart, descriptorEnd - descriptorStart)
        if (encoding == Encoding.UTF16) {
            val bom = descriptor.getShort(descriptorStart).toInt() and 0xffff
            if (bom != BOM_BIG_ENDIAN && bom != BOM_LITTLE_ENDIAN) throw LocalMusicId3.Unsupported()
        }
        return try {
            encoding.charset.newDecoder().decode(descriptor).toString() == edit.descriptor
        } catch (_: CharacterCodingException) {
            throw LocalMusicId3.Unsupported()
        }
    }

    fun encode(edit: Edit, version: Int): ByteArray {
        val (language, descriptor, text) = edit
        if (!languageCode.matches(language) || descriptor.length > MAX_DESCRIPTOR_LENGTH ||
            descriptor.any(Char::isISOControl) || text.length > MAX_TEXT_LENGTH || text.isBlank() ||
            text.any { it.isISOControl() && it != '\t' && it != '\n' && it != '\r' }) {
            throw LocalMusicId3.Unsupported()
        }
        val encoding = when {
            version == 4 -> Encoding.UTF8
            descriptor.all { it.code <= 0xff } && text.all { it.code <= 0xff } -> Encoding.LATIN1
            else -> Encoding.UTF16
        }
        val descriptionBytes = encodeText(descriptor, encoding)
        val textBytes = encodeText(text, encoding)
        val width = encoding.terminatorSize
        val payload = ByteArray(PREFIX_SIZE + descriptionBytes.remaining() + width + textBytes.remaining())
        val bytes = ByteBuffer.wrap(payload)
        bytes.put(encoding.id.toByte())
        bytes.put(language.toByteArray(Charsets.US_ASCII))
        bytes.put(descriptionBytes)
        bytes.position(bytes.position() + width)
        bytes.put(textBytes)
        return payload
    }

    private fun encodeText(text: String, encoding: Encoding): ByteBuffer = try {
        // An empty UTF-16 descriptor is represented by just its terminator.
        if (text.isEmpty()) ByteBuffer.allocate(0)
        else encoding.charset.newEncoder().encode(CharBuffer.wrap(text))
    } catch (_: CharacterCodingException) {
        throw LocalMusicId3.Unsupported()
    }
}
