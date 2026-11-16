package com.github.dvbeckwitt.videre

import java.io.BufferedInputStream
import java.io.ByteArrayOutputStream
import java.io.File
import java.io.IOException
import java.io.InputStream
import java.io.RandomAccessFile
import java.nio.ByteBuffer
import java.nio.charset.CharacterCodingException
import java.util.Locale
import java.util.zip.CRC32
import java.util.zip.ZipException
import java.util.zip.ZipFile

/** Reads only the selected local file. Archive paths are never extracted. */
internal object TakeoutFiles {
    const val MAX_ARCHIVE_BYTES = 64 * 1024 * 1024
    const val MAX_CSV_BYTES = 10 * 1024 * 1024
    const val MAX_TOTAL_CSV_BYTES = 16 * 1024 * 1024
    private const val MAX_ENTRIES = 4096
    private const val MAX_CSV_FILES = 256
    private val localAuthorities = setOf(
        "com.android.externalstorage.documents",
        "com.android.providers.downloads.documents",
        "com.android.providers.media.documents"
    )

    class ReadError(val code: String, message: String) : IOException(message)

    fun isLocalDocument(scheme: String?, authority: String?): Boolean =
        (scheme == "file" && authority.isNullOrEmpty()) ||
            (scheme == "content" && authority?.lowercase(Locale.ROOT) in localAuthorities)

    fun read(input: InputStream, name: String, cacheDirectory: File): List<Map<String, String>> {
        BufferedInputStream(input).use { stream ->
            stream.mark(4)
            val first = stream.read()
            val second = stream.read()
            stream.reset()
            val zip = name.endsWith(".zip", ignoreCase = true) || (first == 0x50 && second == 0x4b)
            if (!zip) {
                if (!name.endsWith(".csv", ignoreCase = true)) {
                    throw ReadError("TAKEOUT_FORMAT", "Choose a Google Takeout ZIP or CSV file saved on this device.")
                }
                val bytes = readBounded(stream, MAX_CSV_BYTES)
                return listOf(mapOf("name" to name.take(1024), "text" to decode(bytes)))
            }
            val temporary = File.createTempFile("videre-takeout-", ".zip", cacheDirectory)
            try {
                temporary.outputStream().use { output ->
                    val buffer = ByteArray(8192)
                    var copied = 0
                    while (true) {
                        if (Thread.currentThread().isInterrupted) throw IOException("Interrupted")
                        val count = stream.read(buffer)
                        if (count < 0) break
                        copied += count
                        if (copied > MAX_ARCHIVE_BYTES) throw tooLarge()
                        output.write(buffer, 0, count)
                    }
                }
                checkDirectorySize(temporary)
                return try {
                    readZip(temporary)
                } catch (_: ZipException) {
                    throw ReadError("TAKEOUT_FORMAT", "The ZIP is damaged, encrypted, or unsupported. Extract and choose a playlist CSV instead.")
                }
            } finally {
                temporary.delete()
            }
        }
    }

    // Bound the central-directory allocation before ZipFile parses it. ZIP64 and
    // split archives are unnecessary for the small CSV exports supported here.
    private fun checkDirectorySize(file: File) {
        RandomAccessFile(file, "r").use { source ->
            val length = source.length()
            val tail = ByteArray(minOf(length, 65557L).toInt())
            source.seek(length - tail.size)
            source.readFully(tail)
            fun word(at: Int) = (tail[at].toInt() and 255) or ((tail[at + 1].toInt() and 255) shl 8)
            fun dword(at: Int) = word(at).toLong() or (word(at + 2).toLong() shl 16)
            for (at in tail.size - 22 downTo 0) {
                if (word(at) != 0x4b50 || word(at + 2) != 0x0605 ||
                    at + 22 + word(at + 20) != tail.size) continue
                if (word(at + 4) != 0 || word(at + 6) != 0 || word(at + 8) != word(at + 10)) {
                    throw ReadError("TAKEOUT_FORMAT", "Split ZIP archives are not supported. Extract and choose a playlist CSV instead.")
                }
                if (word(at + 10) > MAX_ENTRIES) throw tooLarge()
                val directorySize = dword(at + 12)
                if (directorySize > 4 * 1024 * 1024) throw tooLarge()
                if (dword(at + 16) + directorySize > length - tail.size + at) {
                    throw ReadError("TAKEOUT_FORMAT", "The ZIP directory is incomplete. Extract and choose a playlist CSV instead.")
                }
                return
            }
            throw ReadError("TAKEOUT_FORMAT", "The ZIP file is incomplete or unsupported. Extract and choose a playlist CSV instead.")
        }
    }

    private fun readZip(file: File): List<Map<String, String>> {
        ZipFile(file).use { archive ->
            if (archive.size() > MAX_ENTRIES) throw tooLarge()
            val entries = archive.entries().toList()
            val names = HashSet<String>()
            for (entry in entries) {
                val name = entry.name
                if (name.length > 1024 || name.startsWith('/') || name.contains('\\') ||
                    name.contains(':') || name.any { it.code < 32 } ||
                    name.split('/').any { it == ".." || it == "." } || !names.add(name)) {
                    throw ReadError("TAKEOUT_FORMAT", "The ZIP contains invalid or duplicate file names.")
                }
            }
            val hasYouTubeDirectory = entries.any { entry ->
                entry.name.split('/').dropLast(1).any { it.contains("youtube", ignoreCase = true) }
            }
            val result = ArrayList<Map<String, String>>()
            var total = 0
            for (entry in entries) {
                if (entry.isDirectory || !entry.name.endsWith(".csv", ignoreCase = true)) continue
                if (hasYouTubeDirectory && !isMusicCsv(entry.name)) continue
                if (result.size >= MAX_CSV_FILES || entry.size < 0 || entry.size > MAX_CSV_BYTES ||
                    entry.size > MAX_TOTAL_CSV_BYTES - total) throw tooLarge()
                val bytes = archive.getInputStream(entry).use { input ->
                    readBounded(input, minOf(MAX_CSV_BYTES, MAX_TOTAL_CSV_BYTES - total))
                }
                val crc = CRC32().apply { update(bytes) }.value
                if (entry.size != bytes.size.toLong() || entry.crc != crc) {
                    throw ReadError("TAKEOUT_FORMAT", "The ZIP contains damaged CSV data. Export or extract it again.")
                }
                total += bytes.size
                result.add(mapOf("name" to entry.name, "text" to decode(bytes)))
            }
            if (result.isEmpty()) {
                throw ReadError("TAKEOUT_FORMAT", "No playlist or Music library CSV files were found in this ZIP.")
            }
            return result
        }
    }

    private fun isMusicCsv(path: String): Boolean {
        val parts = path.lowercase(Locale.ROOT).split('/')
        if (parts.dropLast(1).none { it.contains("youtube") }) return false
        val name = parts.last().replace('_', '-').replace(' ', '-')
        return parts.any { it == "playlists" || it == "playlist" } ||
            name.contains("liked") ||
            (name.contains("music") && name.contains("library") && name.contains("song"))
    }

    private fun readBounded(input: InputStream, maximum: Int): ByteArray {
        val output = ByteArrayOutputStream()
        val buffer = ByteArray(8192)
        while (true) {
            if (Thread.currentThread().isInterrupted) throw IOException("Interrupted")
            val count = input.read(buffer)
            if (count < 0) break
            if (output.size() + count > maximum) throw tooLarge()
            output.write(buffer, 0, count)
        }
        return output.toByteArray()
    }

    private fun decode(bytes: ByteArray): String = try {
        Charsets.UTF_8.newDecoder().decode(ByteBuffer.wrap(bytes)).toString()
    } catch (_: CharacterCodingException) {
        throw ReadError("INVALID_UTF8", "Choose a UTF-8 CSV file or a ZIP containing UTF-8 CSV files.")
    }

    private fun tooLarge() = ReadError("TAKEOUT_TOO_LARGE",
        "This export is too large. Choose a ZIP up to 64 MiB, or extract a playlist CSV up to 10 MiB. Imported CSV data must total no more than 16 MiB.")
}
