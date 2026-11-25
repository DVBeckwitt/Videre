package com.github.dvbeckwitt.videre

import org.junit.Assert.assertEquals
import org.junit.Test

class LocalMusicAdjacentCoversTest {
    @Test fun onlyConventionalImageNamesAreCandidatesInStablePreferenceOrder() {
        val covers = LocalMusicAdjacentCoverCandidates<String>()
        covers.add("FrOnT.webp", "image/webp") { "front" }
        covers.add("album.png", "application/octet-stream") { "album" }
        covers.add("FOLDER.JPEG", "IMAGE/JPEG") { "folder" }
        covers.add("cover.png", "image/png") { "cover png" }
        covers.add("Cover.JPG", "") { "cover jpg" }
        covers.add("photo.jpg", "image/jpeg") { error("Unrelated image") }
        covers.add("cover.svg", "image/svg+xml") { error("Unsupported format") }
        covers.add("folder.png", "audio/mpeg") { error("Files with an audio media type are ineligible") }
        covers.add("../cover.jpg", "image/jpeg") { error("A filename names one document") }

        assertEquals(listOf("cover jpg", "cover png", "folder", "album", "front"), covers.ranked().toList())
    }

    @Test fun twoDistinctDocumentsWithTheSameNormalizedNameAreSkipped() {
        val covers = LocalMusicAdjacentCoverCandidates<String>()
        covers.add("cover.jpg", "image/jpeg") { "first" }
        covers.add("COVER.JPG", "image/jpeg") { "second" }
        covers.add("cover.jpg", "image/jpeg") { "first" }
        covers.add("folder.jpg", "image/jpeg") { "folder" }
        covers.add("FOLDER.JPG", "image/jpeg") { "folder" }

        assertEquals(listOf("folder"), covers.ranked().toList())
    }
}
