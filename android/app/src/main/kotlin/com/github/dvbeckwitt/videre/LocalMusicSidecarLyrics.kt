package com.github.dvbeckwitt.videre

import java.io.ByteArrayOutputStream
import java.io.IOException
import java.io.InputStream
import java.nio.ByteBuffer
import java.nio.charset.CharacterCodingException
import java.nio.charset.CodingErrorAction

internal object LocalMusicSidecarLyrics {
    private const val MAX_CHARACTERS = 128 * 1024
    const val MAX_BYTES = MAX_CHARACTERS * 3 + 3

    data class Sibling(val id: String, val fileName: String, val audio: Boolean)

    enum class Format(val extension: String) { TTML("ttml"), SRT("srt"), LRC("lrc") }

    data class Candidate(val id: String, val format: Format)

    /** Resolve only within the active track's verified directory. */
    fun candidates(trackId: String, fileName: String, siblings: Sequence<Sibling>): List<Candidate> {
        val stem = fileStem(fileName)
        var trackPresent = false
        var audioWithFileName = 0
        var audioWithStem = 0
        var stemIsAnotherFileName = false
        val matches = mutableMapOf<Pair<String, Format>, Candidate>()
        val ambiguous = mutableSetOf<Pair<String, Format>>()
        for (sibling in siblings) {
            val name = sibling.fileName
            if (sibling.audio) {
                if (name == fileName) {
                    audioWithFileName++
                    if (sibling.id == trackId) trackPresent = true
                }
                if (fileStem(name) == stem) audioWithStem++
                if (sibling.id != trackId && name == stem) stemIsAnotherFileName = true
            } else {
                val extension = name.substringAfterLast('.', "")
                val format = Format.entries.firstOrNull { it.extension.equals(extension, ignoreCase = true) }
                    ?: continue
                val prefix = name.substringBeforeLast('.')
                if (prefix != fileName && prefix != stem) continue
                val key = prefix to format
                if (matches.putIfAbsent(key, Candidate(sibling.id, format)) != null) ambiguous.add(key)
            }
        }
        if (!trackPresent || audioWithFileName != 1) return emptyList()
        fun forName(name: String): List<Candidate> = Format.entries.mapNotNull { format ->
            val key = name to format
            matches[key]?.takeUnless { key in ambiguous }
        }
        val exact = forName(fileName)
        if (stem == fileName || audioWithStem != 1 || stemIsAnotherFileName) return exact
        return exact + forName(stem)
    }

    fun readCandidates(candidates: List<Candidate>, open: (String) -> InputStream?): Map<String, Any> {
        var timed: List<LocalTimedLyric> = emptyList()
        for ((id, format) in candidates) {
            if (timed.isNotEmpty() && format != Format.LRC) continue
            val text = try {
                open(id)?.use(::read)
            } catch (_: IOException) {
                null
            } catch (_: SecurityException) {
                null
            } ?: continue
            when (format) {
                Format.LRC -> return buildMap {
                    put("sidecar", text)
                    if (timed.isNotEmpty()) put("timedSidecar", timed.map(LocalTimedLyric::channelValue))
                }
                Format.SRT -> timed = LocalMusicSrtLyrics.parse(text)
                Format.TTML -> timed = LocalMusicTtmlLyrics.parse(text)
            }
        }
        return if (timed.isEmpty()) emptyMap()
            else mapOf("timedSidecar" to timed.map(LocalTimedLyric::channelValue))
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
