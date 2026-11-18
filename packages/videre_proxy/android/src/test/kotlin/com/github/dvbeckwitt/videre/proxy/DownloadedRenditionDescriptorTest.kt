package com.github.dvbeckwitt.videre.proxy

import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Assert.assertThrows
import org.junit.Test

class DownloadedRenditionDescriptorTest {
    private val local = "file:///private/song.webm"
    private val values = mapOf<String, Any>("uri" to local,
        "remoteUri" to "https://instance.example/videoplayback", "byteLength" to 123L,
        "sha256" to "a".repeat(64))

    @Test fun `optional descriptor preserves sources without saved media`() {
        assertNull(DownloadedRenditionDescriptor.parse(null, "https://instance.example/videoplayback"))
    }

    @Test fun `whole rendition descriptor retains exact local and remote anchors`() {
        val descriptor = DownloadedRenditionDescriptor.parse(values, local)!!
        assertEquals(local, descriptor.uri)
        assertEquals(values["remoteUri"], descriptor.remoteUri)
        assertEquals(123L, descriptor.byteLength)
    }

    @Test fun `local selection needs no signed URL or fabricated network resource`() {
        assertNull(DownloadedRenditionDescriptor.parse(values - "remoteUri", local)!!.remoteUri)
    }

    @Test fun `malformed or ambiguous integrity proof rejects the candidate`() {
        for (invalid in listOf(values + ("byteLength" to 0), values + ("byteLength" to -1),
            values + ("byteLength" to 1.5), values + ("byteLength" to Double.NaN),
            values + ("sha256" to "A".repeat(64)), values + ("sha256" to "a".repeat(63)),
            values + ("remoteUri" to ""), values + ("folderUri" to ""))) {
            assertThrows(LocalDownloadUnavailable::class.java) {
                DownloadedRenditionDescriptor.parse(invalid, local)
            }
        }
        assertThrows(LocalDownloadUnavailable::class.java) {
            DownloadedRenditionDescriptor.parse(values, "file:///private/other.webm")
        }
    }
}
