package com.github.dvbeckwitt.videre

import com.github.dvbeckwitt.videre.proxy.SharedMusicDownload
import java.io.File
import org.junit.Assert.*
import org.junit.Test

class SharedMusicStorageTest {
    @Test fun onlyIndividualPrimaryAudioRowsHaveSharedMusicIdentity() {
        val media = SharedMusicDownload.COLLECTION
        assertTrue(SharedMusicDownload.isItem("$media/81"))
        for (uri in listOf(media, "$media/0", "$media/8?other=1", "$media/../../../1",
            "content://media/external_primary/images/media/3", "content://another/external_primary/audio/media/3")) {
            assertFalse(uri, SharedMusicDownload.isItem(uri))
        }
    }

    @Test fun sharedMusicAcceptsIndexedAudioContainers() {
        assertTrue(SharedMusicDownload.acceptsFile("Song.mp3", "audio/mpeg"))
        assertFalse(SharedMusicDownload.acceptsFile("Song.ogg", "audio/mpeg"))
        assertTrue(SharedMusicDownload.acceptsFile("Song.ogg", "audio/ogg"))
        assertTrue(SharedMusicDownload.acceptsFile("Song.M4A", "audio/mp4"))
        assertFalse(SharedMusicDownload.acceptsFile("Song.webm", "audio/webm"))
        assertFalse(SharedMusicDownload.acceptsFile("Song.webm", "audio/ogg"))
        assertFalse(SharedMusicDownload.acceptsFile("../private.ogg", "audio/ogg"))
    }

    @Test fun legacyDocumentsCanOnlyBeReadIntoVidereExportInputFiles() {
        val root = File(requireNotNull(System.getProperty("java.io.tmpdir"))).canonicalFile
        val path = File(root, "profiles/P_2/song.webm.export-input.part")
        assertEquals(path, exportInputFile(root, path))
        assertNull(exportInputFile(root, File(root, "profiles/P_2/song.webm")))
        assertNull(exportInputFile(root, File(root, "other/song.export-input.part")))
        assertNull(exportInputFile(root, File(root.parentFile, "song.export-input.part")))
    }

    @Test fun scansOnlyFilesInTheChosenPhysicalFolder() {
        val root = File(requireNotNull(System.getProperty("java.io.tmpdir"))).canonicalFile
        assertEquals(File(root, "Music/A song.ogg"), sharedAudioFile(root, "primary:Music", "primary:Music/A song.ogg"))
        assertEquals(File(root, "root.m4a"), sharedAudioFile(root, "sd:", "sd:root.m4a"))
        for (id in listOf("other:Music/song.ogg", "primary:Music2/song.ogg",
            "primary:Music/../private/song.ogg", "primary:Music/sub/song.ogg", "primary:/Music/name.ogg")) {
            assertNull(id, sharedAudioFile(root, "primary:Music", id))
        }
    }
}
