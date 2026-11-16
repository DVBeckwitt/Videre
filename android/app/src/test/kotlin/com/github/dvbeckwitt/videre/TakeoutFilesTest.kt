package com.github.dvbeckwitt.videre

import org.junit.Assert.*
import org.junit.Rule
import org.junit.Test
import org.junit.rules.TemporaryFolder
import java.io.ByteArrayInputStream
import java.io.ByteArrayOutputStream
import java.io.InputStream
import java.util.zip.CRC32
import java.util.zip.ZipEntry
import java.util.zip.ZipOutputStream

class TakeoutFilesTest {
    @get:Rule val temporary = TemporaryFolder()

    private fun read(bytes: ByteArray, name: String = "takeout.zip"): List<Map<String, String>> {
        val directory = temporary.newFolder()
        try {
            return TakeoutFiles.read(ByteArrayInputStream(bytes), name, directory)
        } finally {
            assertTrue("Temporary import ZIP must be removed on success and failure", directory.listFiles()!!.isEmpty())
        }
    }

    private fun zip(vararg files: Pair<String, ByteArray>, stored: Boolean = false): ByteArray {
        val output = ByteArrayOutputStream()
        ZipOutputStream(output).use { zip ->
            for ((name, bytes) in files) {
                val entry = ZipEntry(name)
                if (stored) {
                    entry.method = ZipEntry.STORED
                    entry.size = bytes.size.toLong()
                    entry.crc = CRC32().apply { update(bytes) }.value
                }
                zip.putNextEntry(entry)
                zip.write(bytes)
                zip.closeEntry()
            }
        }
        return output.toByteArray()
    }

    private fun fails(code: String, action: () -> Unit) {
        try {
            action()
            fail("Expected $code")
        } catch (error: TakeoutFiles.ReadError) {
            assertEquals(code, error.code)
        }
    }

    @Test fun acceptsOnlyKnownOnDeviceProviders() {
        assertTrue(TakeoutFiles.isLocalDocument("content", "com.android.externalstorage.documents"))
        assertTrue(TakeoutFiles.isLocalDocument("content", "com.android.providers.downloads.documents"))
        assertTrue(TakeoutFiles.isLocalDocument("content", "com.android.providers.media.documents"))
        assertTrue(TakeoutFiles.isLocalDocument("file", null))
        assertFalse(TakeoutFiles.isLocalDocument("https", "youtube.com"))
        assertFalse(TakeoutFiles.isLocalDocument("content", "com.google.android.apps.docs.storage"))
        assertFalse(TakeoutFiles.isLocalDocument("content", "com.android.providers.downloads.documents.evil"))
        assertFalse(TakeoutFiles.isLocalDocument("file", "youtube.com"))
        assertFalse(TakeoutFiles.isLocalDocument(null, null))
    }

    @Test fun standaloneCsvPreservesUtf8AndDoesNotInterpretLinks() {
        val text = "\uFEFFVideo ID,Song Title\r\nabcdefghijk,\"Café, song\"\r\nhttps://youtube.com/watch?v=abcdefghijk,Link\r\n"
        assertEquals(listOf(mapOf("name" to "Liked Music.csv", "text" to text)),
            read(text.toByteArray(), "Liked Music.csv"))
    }

    @Test fun takeoutZipReadsOnlyMusicAndPlaylistCsvData() {
        val library = "Takeout/YouTube and YouTube Music/music-library-songs/music-library-songs.csv"
        val likes = "Takeout/YouTube and YouTube Music/playlists/Liked Music.csv"
        val files = read(zip(
            library to "Video ID,Song Title\nabcdefghijk,Song".toByteArray(),
            likes to "Video ID,Time Added\nabcdefghijk,2026".toByteArray(),
            "Takeout/YouTube and YouTube Music/history/watch-history.csv" to ByteArray(11 * 1024 * 1024),
            "Takeout/YouTube and YouTube Music/videos/upload.mp4" to ByteArray(11 * 1024 * 1024),
            "Takeout/Contacts/contacts.csv" to "contacts".toByteArray()
        ))
        assertEquals(listOf(library, likes), files.map { it["name"] })
    }

    @Test fun flatCsvZipAndZipWithoutExtensionAreSupported() {
        val bytes = zip("favorites.csv" to "Video ID\nabcdefghijk".toByteArray())
        assertEquals("favorites.csv", read(bytes, "download").single()["name"])
    }

    @Test fun rejectsUnrelatedNonCsvFilesAndEmptyArchives() {
        fails("TAKEOUT_FORMAT") { read("{}".toByteArray(), "data.json") }
        fails("TAKEOUT_FORMAT") { read(zip("image.png" to byteArrayOf(1, 2))) }
    }

    @Test fun rejectsInvalidUtf8InsideAndOutsideArchives() {
        val invalid = byteArrayOf(0xc3.toByte(), 0x28)
        fails("INVALID_UTF8") { read(invalid, "songs.csv") }
        fails("INVALID_UTF8") { read(zip("songs.csv" to invalid)) }
    }

    @Test fun rejectsDangerousArchiveNamesWithoutExtractingAnything() {
        for (name in listOf("../songs.csv", "/songs.csv", "C:/songs.csv", "safe\\songs.csv", "a/./songs.csv", "bad\u0000.csv")) {
            fails("TAKEOUT_FORMAT") { read(zip(name to "data".toByteArray())) }
        }
    }

    @Test fun rejectsDuplicateArchiveNames() {
        val bytes = zip("first.csv" to "a".toByteArray(), "other.csv" to "b".toByteArray())
        replace(bytes, "other.csv".toByteArray(), "first.csv".toByteArray())
        fails("TAKEOUT_FORMAT") { read(bytes) }
    }

    @Test fun rejectsTruncationAndCorruptCsvCrc() {
        val bytes = zip("songs.csv" to "unique-content".toByteArray(), stored = true)
        fails("TAKEOUT_FORMAT") { read(bytes.copyOf(bytes.size - 1)) }
        replace(bytes, "unique-content".toByteArray(), "damagedcontent".toByteArray())
        fails("TAKEOUT_FORMAT") { read(bytes) }
    }

    @Test fun rejectsTooManyArchiveEntriesAndCsvFiles() {
        fails("TAKEOUT_TOO_LARGE") {
            read(zip(*(0..4096).map { "entry$it.txt" to byteArrayOf(1) }.toTypedArray()))
        }
        fails("TAKEOUT_TOO_LARGE") {
            read(zip(*(0..256).map { "songs$it.csv" to byteArrayOf(1) }.toTypedArray()))
        }
    }

    @Test fun enforcesCsvAndCombinedDecompressionLimits() {
        fails("TAKEOUT_TOO_LARGE") { read(ByteArray(TakeoutFiles.MAX_CSV_BYTES + 1), "songs.csv") }
        fails("TAKEOUT_TOO_LARGE") {
            read(zip("songs.csv" to ByteArray(TakeoutFiles.MAX_CSV_BYTES + 1)))
        }
        val half = TakeoutFiles.MAX_TOTAL_CSV_BYTES / 2 + 1
        fails("TAKEOUT_TOO_LARGE") {
            read(zip("one.csv" to ByteArray(half), "two.csv" to ByteArray(half)))
        }
    }

    @Test fun checksActualInflatedSizeEvenWhenZipDirectoryLies() {
        val bytes = zip("songs.csv" to ByteArray(TakeoutFiles.MAX_CSV_BYTES + 1))
        val central = bytes.indices.first { at ->
            at + 4 <= bytes.size && bytes[at] == 0x50.toByte() && bytes[at + 1] == 0x4b.toByte() &&
                bytes[at + 2] == 1.toByte() && bytes[at + 3] == 2.toByte()
        }
        // Central directory advertises one byte while its compressed payload expands past the limit.
        bytes[central + 24] = 1
        for (offset in 25..27) bytes[central + offset] = 0
        fails("TAKEOUT_TOO_LARGE") { read(bytes) }
    }

    @Test fun boundsZipDirectoryAllocationAndRejectsInvalidOffsets() {
        val bytes = zip("songs.csv" to "Video ID".toByteArray())
        val end = bytes.size - 22
        val large = bytes.copyOf()
        for (offset in 0..3) large[end + 12 + offset] = ((4 * 1024 * 1024 + 1) ushr (8 * offset)).toByte()
        fails("TAKEOUT_TOO_LARGE") { read(large) }
        for (offset in 0..3) bytes[end + 16 + offset] = 0xff.toByte()
        fails("TAKEOUT_FORMAT") { read(bytes) }
    }

    @Test fun encryptedZipIsReportedAsUnsupported() {
        val bytes = zip("songs.csv" to "Video ID".toByteArray())
        val central = bytes.indices.first { at ->
            at + 4 <= bytes.size && bytes[at] == 0x50.toByte() && bytes[at + 1] == 0x4b.toByte() &&
                bytes[at + 2] == 1.toByte() && bytes[at + 3] == 2.toByte()
        }
        bytes[central + 8] = (bytes[central + 8].toInt() or 1).toByte()
        bytes[6] = (bytes[6].toInt() or 1).toByte()
        fails("TAKEOUT_FORMAT") { read(bytes) }
    }

    @Test fun limitsArchiveCopyAndClosesTheSelectedStreamOnFailure() {
        var closed = false
        val stream = object : InputStream() {
            var remaining = TakeoutFiles.MAX_ARCHIVE_BYTES + 1
            override fun read(): Int = if (remaining-- > 0) 0 else -1
            override fun read(buffer: ByteArray, offset: Int, length: Int): Int {
                if (remaining <= 0) return -1
                val count = minOf(length, remaining)
                buffer.fill(0, offset, offset + count)
                remaining -= count
                return count
            }
            override fun close() { closed = true }
        }
        val directory = temporary.newFolder()
        fails("TAKEOUT_TOO_LARGE") { TakeoutFiles.read(stream, "takeout.zip", directory) }
        assertTrue(closed)
        assertTrue(directory.listFiles()!!.isEmpty())
    }

    private fun replace(bytes: ByteArray, old: ByteArray, replacement: ByteArray) {
        require(old.size == replacement.size)
        for (at in 0..bytes.size - old.size) {
            if (old.indices.all { bytes[at + it] == old[it] }) {
                replacement.copyInto(bytes, at)
            }
        }
    }
}
