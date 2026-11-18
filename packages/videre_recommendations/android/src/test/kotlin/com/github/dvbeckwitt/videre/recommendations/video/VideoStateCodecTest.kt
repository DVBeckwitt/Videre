package com.github.dvbeckwitt.videre.recommendations.video

import org.junit.Assert.*
import org.junit.Test

class VideoStateCodecTest {
    private fun reject(state: Map<String, Any?>) {
        try {
            VideoStateCodec.decode(state)
            fail("Malformed persisted video state must not be repaired silently")
        } catch (_: IllegalArgumentException) {
            // The caller keeps its previous durable snapshot.
        }
    }

    @Test
    fun emptyDefaultsAndEncodedStateRemainValid() {
        val brain = VideoStateCodec.decode(emptyMap())
        assertEquals(0, brain.totalInteractions)
        val encoded = VideoStateCodec.encode(brain)
        assertEquals(encoded, VideoStateCodec.encode(VideoStateCodec.decode(encoded)))
        assertEquals(VideoStateCodec.allowedKeys - setOf("session", "processedEventIds"), encoded.keys)
    }

    @Test
    fun categoryEvidenceIsCountedRatherThanClampedToProbability() {
        val state = VideoStateCodec.encode(UserBrain(categoryAffinity = mapOf("music" to 27.5)))
        assertEquals(27.5, VideoStateCodec.decode(state).categoryAffinity["music"]!!, 0.0)
    }

    @Test
    fun knownFieldWithWrongTypeOrExplicitNullIsRejected() {
        reject(mapOf("globalVector" to "corrupt"))
        reject(mapOf("globalVector" to null))
        reject(mapOf("blockedChannels" to "UCblocked"))
        reject(mapOf("channelScores" to mapOf("UCcreator" to "0.8")))
        reject(mapOf("hasCompletedOnboarding" to 1))
        reject(mapOf("timeVectors" to mapOf("UNKNOWN" to emptyMap<String, Any?>())))
    }

    @Test
    fun schemasAndTimestampsMustBeIntegralAndBounded() {
        reject(mapOf("schemaVersion" to "1"))
        reject(mapOf("schemaVersion" to 1.5))
        reject(mapOf("schemaVersion" to 2))
        reject(mapOf("schemaVersion" to null))
        reject(mapOf("domain" to "music"))
        reject(mapOf("feedHistory" to mapOf("id" to mapOf("lastShown" to 123.5))))
        reject(mapOf("seenShortsHistory" to mapOf("id" to Double.MAX_VALUE)))
        reject(mapOf("session" to mapOf("lastAt" to -1)))
    }

    @Test
    fun numericCountsRetainAtLeastTwoBatchesOfHeadroom() {
        assertTrue(Int.MAX_VALUE - VideoStateCodec.MAX_COUNTER >= 2000)
        val accepted = VideoStateCodec.decode(mapOf("totalInteractions" to VideoStateCodec.MAX_COUNTER))
        assertEquals(VideoStateCodec.MAX_COUNTER, accepted.totalInteractions)
        reject(mapOf("totalInteractions" to Int.MAX_VALUE))
        reject(mapOf("totalInteractions" to 5.5))
        reject(mapOf("idfTotalDocuments" to Int.MAX_VALUE))
        reject(mapOf("timeBucketCounts" to mapOf("WEEKDAY_MORNING" to Int.MAX_VALUE)))
        reject(mapOf("topicEvidence" to mapOf("music" to mapOf("positiveSignals" to Int.MAX_VALUE))))
        reject(mapOf("session" to mapOf("impressions" to mapOf("v" to mapOf("count" to Int.MAX_VALUE)))) )
    }

    @Test
    fun oversizedFieldsAreRejectedBeforeKeyOrCollectionTruncation() {
        reject(mapOf("blockedChannels" to (0..1000).map { "UC$it" }))
        reject(mapOf("globalVector" to mapOf("topics" to (0..1000).associate { "topic$it" to 0.3 })))
        reject(mapOf("channelScores" to mapOf("x".repeat(513) to 0.8)))
        reject(mapOf("keyLanguage" to "x".repeat(21)))
        reject(mapOf("processedEventIds" to listOf("x".repeat(513))))
        reject(mapOf("recentQueryTokens" to List(101) { listOf("music") }))
    }

    @Test
    fun unknownFieldsCannotHideTransportDataInSnapshots() {
        reject(mapOf("accessToken" to "not-a-real-token"))
        reject(mapOf("globalVector" to mapOf("headers" to emptyMap<String, String>())))
        reject(mapOf("channelMemory" to mapOf("entries" to mapOf("UCone" to mapOf("thumbnailUrl" to "https://example.invalid/art")))))
        reject(mapOf("session" to mapOf("headers" to emptyMap<String, String>())))
    }

    @Test
    fun validSessionAdapterShapeRemainsAccepted() {
        val session = mapOf(
            "startedAt" to 1_700_000_000_000L,
            "lastAt" to 1_700_000_010_000L,
            "videoCount" to 2,
            "topics" to listOf("music", "music"),
            "momentum" to listOf(mapOf("topic" to "music", "positive" to true)),
            "impressions" to mapOf("v1" to mapOf("count" to 1, "lastSeen" to 1_700_000_000_000L)),
        )
        VideoStateCodec.validate(VideoStateCodec.encode(UserBrain()) + mapOf("session" to session, "processedEventIds" to listOf("event1")))
    }

    @Test
    fun nonfiniteWeightsAndOutOfRangeScalarsAreRejected() {
        reject(mapOf("globalVector" to mapOf("topics" to mapOf("music" to Double.NaN))))
        reject(mapOf("globalVector" to mapOf("duration" to -0.1)))
        reject(mapOf("watchHistoryMap" to mapOf("v1" to 1.1)))
        reject(mapOf("displayForms" to mapOf("music" to mapOf("form" to "Music", "votes" to 21))))
    }
}
