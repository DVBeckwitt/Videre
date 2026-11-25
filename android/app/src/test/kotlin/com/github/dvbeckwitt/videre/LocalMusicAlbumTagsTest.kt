package com.github.dvbeckwitt.videre

import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Test

class LocalMusicAlbumTagsTest {
    @Test fun albumPositionsUseOnlyThePositiveNumberBeforeTheTotal() {
        assertEquals(2, localAlbumPosition(" 02 / 12 "))
        assertEquals(10, localAlbumPosition("10"))
        for (tag in listOf(null, "0", "-1", "65536", "1/hundred", "one", "2/3/4")) {
            assertNull(localAlbumPosition(tag))
        }
    }

    @Test fun datesRetainPrecisionAndRequireAValidCalendarDate() {
        assertEquals("1982", localReleaseDate("1982"))
        assertEquals("1995-07", localReleaseDate("1995-07"))
        assertEquals("2000-02-29", localReleaseDate("2000-02-29T23:14:09Z"))
        for (tag in listOf(null, "0000", "1900-02-29", "2024-04-31", "2000-00", "2000-12-00", "2000s")) {
            assertNull(localReleaseDate(tag))
        }
    }

    @Test fun id3UsesExplicitReleaseAndOriginalReleaseAheadOfRecordingTime() {
        val data = id3Tag("TDRC" to "1999", "TDRL" to "2001-12", "TDOR" to "1998-05-04")
        assertEquals(LocalId3Dates("2001-12", "1998-05-04"), readLocalId3Dates { data.inputStream() })
    }

    @Test fun id3FallsBackToConventionalDatesAndHandlesTruncatedTags() {
        val data = id3Tag("TYER" to "1999", "TDAT" to "2001", "TORY" to "1993")
        assertEquals(LocalId3Dates("1999-01-20", "1993"), readLocalId3Dates { data.inputStream() })
        assertNull(readLocalId3Dates { data.copyOf(12).inputStream() })
        val oversized = data.copyOf(10).apply { this[6] = 2 }
        assertNull(readLocalId3Dates { oversized.inputStream() })
    }

    private fun id3Tag(vararg frames: Pair<String, String>): ByteArray {
        val body = frames.fold(ByteArray(0)) { data, (id, value) ->
            val payload = byteArrayOf(3) + value.toByteArray()
            data + id.toByteArray() + byteArrayOf(0, 0, 0, payload.size.toByte(), 0, 0) + payload
        }
        return "ID3".toByteArray() + byteArrayOf(4, 0, 0, 0, 0, 0, body.size.toByte()) + body
    }
}
