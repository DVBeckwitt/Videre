package com.github.dvbeckwitt.videre

import java.io.ByteArrayOutputStream
import java.io.InputStream
import java.nio.ByteBuffer
import java.nio.charset.CharacterCodingException
import java.nio.charset.Charset
import java.util.Locale

internal data class LocalMusicCueSheet(
    val title: String?,
    val performer: String?,
    val files: List<LocalMusicCueFile>,
) {
    companion object {
        fun parse(input: InputStream): LocalMusicCueSheet? {
            val text = readCueText(input) ?: return null
            if ('\u0000' in text) return null

            var title: String? = null
            var performer: String? = null
            var file: CueFileDraft? = null
            var track: CueTrackDraft? = null
            var lastTrackNumber = 0
            var hasTrackDirective = false
            val files = mutableListOf<CueFileDraft>()

            for (line in text.lineSequence()) {
                if (line.length > MAX_LINE_CHARS) return null
                val trimmed = line.trim()
                val command = trimmed.takeWhile { !it.isWhitespace() }
                val argument = trimmed.drop(command.length).trimStart()
                when (command.uppercase(Locale.ROOT)) {
                    "FILE" -> {
                        track = null
                        val match = FILE_ARGUMENT.matchEntire(argument)
                        file = match?.let {
                            val name = it.groups[1]?.value ?: it.groupValues[2]
                            val type = it.groupValues[3].uppercase(Locale.ROOT)
                            cueRelativePath(name)?.let { path ->
                                CueFileDraft(path, supported = type in AUDIO_FILE_TYPES)
                            }
                        }
                        file?.let(files::add)
                    }
                    "TRACK" -> {
                        hasTrackDirective = true
                        track = null
                        val currentFile = file ?: continue
                        val match = TRACK_ARGUMENT.matchEntire(argument)
                        val number = match?.groupValues?.get(1)?.toInt() ?: 0
                        if (match == null || number !in (lastTrackNumber + 1)..99) {
                            currentFile.valid = false
                            continue
                        }
                        lastTrackNumber = number
                        track = CueTrackDraft(number, match.groupValues[2].equals("AUDIO", ignoreCase = true))
                        currentFile.tracks.add(track)
                    }
                    "INDEX" -> {
                        val currentTrack = track ?: continue
                        if (!currentTrack.addIndex(argument)) file?.valid = false
                    }
                    "TITLE" -> {
                        val value = cueTag(argument) ?: continue
                        if (track != null) track.title = value
                        else if (!hasTrackDirective) title = value
                    }
                    "PERFORMER" -> {
                        val value = cueTag(argument) ?: continue
                        if (track != null) track.performer = value
                        else if (!hasTrackDirective) performer = value
                    }
                }
            }

            val declarations = files.groupingBy(CueFileDraft::relativePath).eachCount()
            val parsed = files.mapNotNull {
                // Reopening the same file in a later FILE command makes EOF
                // ambiguous for the previous declaration.
                if (declarations[it.relativePath] == 1) it.toCueFile() else null
            }
            return parsed.takeIf { it.isNotEmpty() }?.let { LocalMusicCueSheet(title, performer, it) }
        }
    }
}

internal data class LocalMusicCueFile(
    val relativePath: List<String>,
    val tracks: List<LocalMusicCueTrack>,
)

internal data class LocalMusicCueTrack(
    val number: Int,
    val title: String?,
    val performer: String?,
    val startUs: Long,
    val endUs: Long?,
)

private class CueFileDraft(val relativePath: List<String>, val supported: Boolean) {
    var valid = true
    val tracks = mutableListOf<CueTrackDraft>()

    fun toCueFile(): LocalMusicCueFile? {
        if (!valid || !supported) return null
        val result = mutableListOf<LocalMusicCueTrack>()
        var previousStart = -1L
        for ((index, track) in tracks.withIndex()) {
            val start = track.startUs ?: return null
            if (start <= previousStart || track.pregapUs?.let { it !in previousStart..start } == true) return null
            previousStart = start
            if (!track.audio) continue
            val next = tracks.getOrNull(index + 1)
            val end = if (next?.audio == false) next.pregapUs ?: next.startUs else next?.startUs
            if (end != null && end <= start) return null
            result.add(LocalMusicCueTrack(track.number, track.title, track.performer, start, end))
        }
        return result.takeIf { it.isNotEmpty() }?.let { LocalMusicCueFile(relativePath, it) }
    }
}

private class CueTrackDraft(val number: Int, val audio: Boolean) {
    var title: String? = null
    var performer: String? = null
    var startUs: Long? = null
        private set
    var pregapUs: Long? = null
        private set

    fun addIndex(argument: String): Boolean {
        val match = INDEX_ARGUMENT.matchEntire(argument) ?: return false
        val (index, minute, second, frame) = match.destructured
        val seconds = second.toInt()
        val frames = frame.toInt()
        if (seconds >= 60 || frames >= 75) return false
        val timeUs = (minute.toLong() * 60 + seconds) * 1_000_000 + frames * 1_000_000L / 75
        return when (index.toInt()) {
            0 -> {
                if (pregapUs != null || startUs != null) return false
                pregapUs = timeUs
                true
            }
            1 -> {
                if (startUs != null) return false
                startUs = timeUs
                true
            }
            else -> true
        }
    }
}

private const val MAX_SHEET_BYTES = 256 * 1024
private const val MAX_LINE_CHARS = 4096
private val AUDIO_FILE_TYPES = setOf("WAVE", "AIFF", "MP3", "FLAC", "OGG", "OPUS", "AAC", "M4A")
private val FILE_ARGUMENT = Regex("""(?:"([^"]+)"|([^"\s]+))\s+([A-Za-z0-9]+)""")
private val TRACK_ARGUMENT = Regex("""([0-9]{1,2})\s+([A-Za-z0-9/]+)""")
private val INDEX_ARGUMENT = Regex("""([0-9]{1,2})\s+([0-9]{1,6}):([0-9]{2}):([0-9]{2})""")

private fun cueRelativePath(name: String): List<String>? {
    if (name.length > 1024 || name.any { it == ':' || it.isISOControl() }) return null
    val parts = name.split('/', '\\')
    return parts.takeUnless { it.any { part -> part.isBlank() || part == "." || part == ".." } }
}

private fun cueTag(argument: String): String? {
    val text = if (argument.startsWith('"')) {
        if (argument.length < 2 || !argument.endsWith('"')) return null
        argument.substring(1, argument.lastIndex)
    } else {
        argument
    }
    return text.trim().take(1024).takeIf { it.isNotEmpty() && it.none(Char::isISOControl) }
}

private fun readCueText(input: InputStream): String? {
    val bytes = ByteArrayOutputStream()
    val buffer = ByteArray(4096)
    while (bytes.size() < MAX_SHEET_BYTES) {
        val count = input.read(buffer, 0, minOf(buffer.size, MAX_SHEET_BYTES - bytes.size()))
        if (count < 0) break
        if (count == 0) {
            val byte = input.read()
            if (byte < 0) break
            bytes.write(byte)
        } else {
            bytes.write(buffer, 0, count)
        }
    }
    if (bytes.size() == MAX_SHEET_BYTES && input.read() != -1) return null

    val encoded = bytes.toByteArray()
    val data = ByteBuffer.wrap(encoded)
    // UTF-16 is unambiguous with a BOM. Legacy Windows rippers often write
    // unmarked Windows-1252, so try UTF-8 first for an unmarked sheet.
    if (encoded.size >= 2) {
        val firstWord = data.getShort(0).toInt() and 0xffff
        if (firstWord == 0xfffe || firstWord == 0xfeff) return decodeCueText(data, Charsets.UTF_16)
    }
    val utf8 = decodeCueText(data, Charsets.UTF_8)
    if (utf8 != null) return utf8.removePrefix("\uFEFF")
    if (encoded.size >= 3 && encoded[0] == 0xef.toByte() && encoded[1] == 0xbb.toByte() &&
        encoded[2] == 0xbf.toByte()) return null
    return decodeCueText(ByteBuffer.wrap(encoded), Charset.forName("windows-1252"))
}

private fun decodeCueText(data: ByteBuffer, charset: Charset): String? = try {
    charset.newDecoder().decode(data).toString()
} catch (_: CharacterCodingException) {
    null
}
