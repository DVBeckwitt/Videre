package com.github.dvbeckwitt.videre

import java.io.File
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Rule
import org.junit.Test
import org.junit.rules.TemporaryFolder

class LocalMusicArtworkStorageTest {
    @get:Rule val temporary = TemporaryFolder()

    @Test fun measuresAndClearsTheManagedDeviceStores() {
        val cache = temporary.newFolder("cache")
        val source = File(cache, "music-covers-${"a".repeat(64)}")
        val previousSource = File(cache, "music-covers-${"b".repeat(64)}")
        val legacy = File(cache, "local_music_covers")
        val cover = write(source, "cover.jpg", 7)
        val interrupted = write(previousSource, "cover-414.tmp", 11)
        val oldCover = write(legacy, "legacy.jpg", 5)
        val nested = write(File(source, "unmanaged"), "nested.jpg", 31)
        val otherCache = write(File(cache, "music-covers-unmanaged"), "cover.jpg", 23)
        val notification = write(File(cache, "notification-artwork"), "notification.jpg", 29)
        val selectedCover = write(temporary.newFolder("chosen-images"), "custom.jpg", 13)
        val index = write(temporary.newFolder("noBackup"), "music-index-legacy.json", 19)
        val download = write(temporary.newFolder("downloads"), "saved.jpg", 17)
        val storage = LocalMusicArtworkStorage(cache)

        assertEquals(mapOf("usedBytes" to 23L, "limitBytes" to 24L * 1024 * 1024, "canClear" to true), storage.status())
        assertEquals(mapOf("usedBytes" to 0L, "limitBytes" to 24L * 1024 * 1024, "canClear" to false), storage.clear())
        assertFalse(cover.exists())
        assertFalse(interrupted.exists())
        assertFalse(oldCover.exists())
        for (file in listOf(nested, otherCache, index)) assertTrue(file.isFile)
        assertEquals(29L, notification.length())
        assertEquals(13L, selectedCover.length())
        assertEquals(17L, download.length())

        assertEquals(storage.status(), storage.clear())
        write(source, "cover.jpg", 3)
        assertEquals(3L, storage.status()["usedBytes"])
    }

    @Test fun zeroByteArtifactsCanStillBeCleared() {
        val directory = temporary.newFolder("cache")
        val artifact = write(File(directory, "local_music_covers"), "cover-001.tmp", 0)
        val storage = LocalMusicArtworkStorage(directory)

        assertEquals(0L, storage.status()["usedBytes"])
        assertEquals(true, storage.status()["canClear"])
        assertEquals(false, storage.clear()["canClear"])
        assertFalse(artifact.exists())
    }

    private fun write(directory: File, name: String, length: Int) = File(directory, name).apply {
        directory.mkdirs()
        writeBytes(ByteArray(length))
    }
}
