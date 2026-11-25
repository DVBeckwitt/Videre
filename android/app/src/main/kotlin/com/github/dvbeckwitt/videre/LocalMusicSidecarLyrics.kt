package com.github.dvbeckwitt.videre

import java.io.ByteArrayOutputStream
import java.io.InputStream
import java.nio.ByteBuffer
import java.nio.charset.CharacterCodingException
import java.nio.charset.CodingErrorAction

internal object LocalMusicSidecarLyrics {
    private const val MAX_CHARACTERS = 128 * 1024
    const val MAX_BYTES = MAX_CHARACTERS * 3 + 3

    data class Sibling(val id: String, val fileName: String, val audio: Boolean)

    /** Resolve only within the active track's verified directory. */
    fun candidates(trackId: String, fileName: String, siblings: Sequence<Sibling>): List<String> {
        val stem = fileStem(fileName)
        var trackPresent = false
        var audioWithFileName = 0
        var audioWithStem = 0
        var stemIsAnotherFileName = false
        val matches = mutableMapOf<String, String>()
        val ambiguous = mutableSetOf<String>()
        for (sibling in siblings) {
            val name = sibling.fileName
            if (sibling.audio) {
                if (name == fileName) {
                    audioWithFileName++
                    if (sibling.id == trackId) trackPresent = true
                }
                if (fileStem(name) == stem) audioWithStem++
                if (sibling.id != trackId && name == stem) stemIsAnotherFileName = true
            } else if (name.endsWith(".lrc", ignoreCase = true)) {
                val prefix = name.dropLast(4)
                if ((prefix == fileName || prefix == stem) &&
                    matches.putIfAbsent(prefix, sibling.id) != null) ambiguous.add(prefix)
            }
        }
        if (!trackPresent || audioWithFileName != 1) return emptyList()
        return listOfNotNull(
            matches[fileName]?.takeUnless { fileName in ambiguous },
            matches[stem]?.takeIf {
                stem != fileName && stem !in ambiguous && audioWithStem == 1 && !stemIsAnotherFileName
            },
        )
    }

    fun read(input: InputStream): String? {
        val buffer = ByteArray(8192)
        val output = ByteArrayOutputStream()
        while (true) {
            val read = input.read(buffer, 0, minOf(buffer.size, MAX_BYTES + 1 - output.size()))
            if (read < 0) break
            if (read == 0 || read > MAX_BYTES - output.size()) return null
            output.write(buffer, 0, read)
        }
        val bytes = output.toByteArray()
        val (encoding, start) = when {
            bytes.startsWith(0xef, 0xbb, 0xbf) -> Charsets.UTF_8 to 3
            bytes.startsWith(0xff, 0xfe) -> Charsets.UTF_16LE to 2
            bytes.startsWith(0xfe, 0xff) -> Charsets.UTF_16BE to 2
            else -> Charsets.UTF_8 to 0
        }
        val text = try {
            encoding.newDecoder()
                .onMalformedInput(CodingErrorAction.REPORT)
                .onUnmappableCharacter(CodingErrorAction.REPORT)
                .decode(ByteBuffer.wrap(bytes, start, bytes.size - start)).toString()
        } catch (_: CharacterCodingException) {
            return null
        }
        return text.takeIf { it.length <= MAX_CHARACTERS && it.isNotBlank() && '\u0000' !in it }
    }

    private fun fileStem(name: String): String =
        name.substringBeforeLast('.').takeIf(String::isNotEmpty) ?: name

    private fun ByteArray.startsWith(vararg prefix: Int): Boolean =
        size >= prefix.size && prefix.indices.all { (this[it].toInt() and 0xff) == prefix[it] }
}
