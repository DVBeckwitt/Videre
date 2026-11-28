package com.github.dvbeckwitt.videre

import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Test

class YtdlnisDownloadTest {
    @Test fun convertsOnlyOneVideoIdToABarePublicLink() {
        assertEquals("https://www.youtube.com/watch?v=tV5UilNUYRY", ytdlnisPublicVideoUrl("tV5UilNUYRY"))
        assertEquals("https://www.youtube.com/watch?v=abcDef01_-2", ytdlnisPublicVideoUrl("abcDef01_-2"))

        for (input in listOf(
            null, "", "tV5UilNUYRY\n", " tV5UilNUYRY", "tV5UilNUYRY&list=Playlist",
            "https://www.youtube.com/watch?v=tV5UilNUYRY",
            "https://private.instance.invalid/watch?v=tV5UilNUYRY",
            "file:///audio/local.mp3", "device:tV5UilNUYRY",
        )) {
            assertNull(ytdlnisPublicVideoUrl(input))
        }
    }
}
