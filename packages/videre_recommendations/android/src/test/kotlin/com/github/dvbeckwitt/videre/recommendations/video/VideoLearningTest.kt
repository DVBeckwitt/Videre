/*
 * Copyright (C) 2025-2026 Flow | A-EDev
 * Adapted for Videre from Flow's NeuroDocumentCountTest and
 * NeuroLearningDynamicsTest at 565d1f7a3da4ca8e54463b029f151ef87415858a.
 * Flow Android Client: https://github.com/Flow-Tube/Flow
 * SPDX-License-Identifier: GPL-3.0-only
 */
package com.github.dvbeckwitt.videre.recommendations.video

import java.util.Calendar
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

class VideoLearningTest {
    private val video = Video(
        id = "q1",
        title = "Quantum gravity explained simply",
        channelName = "Physics Lab",
        channelId = "ch-physics",
        duration = 900,
        viewCount = 1L,
        uploadDate = "",
    )
    private val now = Calendar.getInstance().apply {
        clear()
        set(2026, Calendar.NOVEMBER, 16, 9, 0)
    }.timeInMillis

    private fun learn(
        state: UserBrain,
        event: InteractionType,
        fraction: Float = 0f,
        input: Video = video,
    ) = VideoLearning.learn(state, input, event, fraction, NeuroTokenizer(), now)

    @Test
    fun openingWatchingAndLikingOneVideoCountsOneDocument() {
        var state = UserBrain(idfTotalDocuments = 100)
        state = learn(state, InteractionType.CLICK)
        state = learn(state, InteractionType.WATCHED, 0.9f)
        state = learn(state, InteractionType.LIKED)

        assertEquals(101, state.idfTotalDocuments)
        assertEquals(1, state.idfWordFrequency.values.max())
        assertFalse(NeuroPhrases.isPhrase("quantum gravity", IdfSnapshot(state.idfWordFrequency, state.idfTotalDocuments)))
        assertEquals(setOf("q1"), state.countedDocumentIds)
        assertEquals(3, state.totalInteractions)
    }

    @Test
    fun watchingAgainAfterRestoringStateDoesNotAddDocument() {
        val saved = learn(UserBrain(idfTotalDocuments = 100), InteractionType.WATCHED, 0.9f)
        val restored = learn(saved, InteractionType.WATCHED, 1f)
        assertEquals(101, restored.idfTotalDocuments)
        assertEquals(1f, restored.watchHistoryMap.getValue("q1"), 0f)
    }

    @Test
    fun likingAnUnwatchedVideoAgainDoesNotAddDocument() {
        val saved = learn(UserBrain(), InteractionType.LIKED)
        val restored = learn(saved, InteractionType.LIKED)
        assertEquals(1, restored.idfTotalDocuments)
        assertTrue(restored.watchHistoryMap.isEmpty())
    }

    @Test
    fun channelLearningMatchesUpstreamEmaAndExplicitDislikeFactor() {
        val first = learn(UserBrain(), InteractionType.WATCHED, 0.9f)
        val second = learn(first, InteractionType.LIKED)
        val rejected = learn(second, InteractionType.DISLIKED)

        assertEquals(0.525, first.channelScores.getValue("ch-physics"), 1e-12)
        assertEquals(0.54875, second.channelScores.getValue("ch-physics"), 1e-12)
        assertEquals(0.274375, rejected.channelScores.getValue("ch-physics"), 1e-12)
        assertEquals(0, rejected.consecutiveSkips)
        assertTrue(rejected.topicEvidence.values.any { it.negativeSignals > 0 })
    }

    @Test
    fun explicitSkipAddsNegativeEvidenceWithoutWatchedOrIdfHistory() {
        val skipped = learn(UserBrain(), InteractionType.SKIPPED)
        assertEquals(0.475, skipped.channelScores.getValue("ch-physics"), 1e-12)
        assertEquals(1, skipped.consecutiveSkips)
        assertEquals(0, skipped.idfTotalDocuments)
        assertTrue(skipped.watchHistoryMap.isEmpty())
        assertTrue(skipped.topicEvidence.values.any { it.negativeSignals > 0 })
    }

    @Test
    fun suppliedClockDeterminesBucketAndEvidenceTimestamp() {
        val watched = learn(UserBrain(), InteractionType.WATCHED, 1f)
        assertEquals(1, watched.timeBucketCounts.getValue(TimeBucket.WEEKDAY_MORNING))
        assertTrue(watched.topicEvidence.isNotEmpty())
        assertTrue(watched.topicEvidence.values.all { it.firstSeenAt == now && it.lastSeenAt == now })
        assertEquals(0.0, NeuroScoring.timeBucketConfidence(watched, TimeBucket.WEEKDAY_NIGHT), 0.0)
    }

    @Test
    fun fullStrengthVectorDecayPreservesUpstreamTieredRates() {
        val learned = ContentVector(topics = mapOf("comedy" to 0.08, "stand-up comedy" to 0.25, "cooking" to 0.4))
        val incoming = ContentVector(topics = mapOf("prank" to 1.0))
        val decayed = NeuroVectorMath.adjustVector(learned, incoming, 0.15)
        assertEquals(0.08 * 0.97, decayed.topics.getValue("comedy"), 1e-9)
        assertEquals(0.4 * 0.998, decayed.topics.getValue("cooking"), 1e-9)
    }

    @Test
    fun actualSaveUsesPositiveLearningWithoutPretendingTheVideoWasWatched() {
        val saved = learn(UserBrain(), InteractionType.SAVED)
        assertTrue(saved.globalVector.topics.isNotEmpty())
        assertTrue(saved.topicEvidence.values.any { it.explicitSignals == 1 })
        assertTrue(saved.watchHistoryMap.isEmpty())
        assertEquals(0.525, saved.channelScores.getValue("ch-physics"), 1e-12)
    }

    @Test
    fun missingCreatorIdDoesNotCombineUnidentifiedCreators() {
        val unknown = video.copy(channelId = "")
        val watched = learn(UserBrain(), InteractionType.WATCHED, 0.9f, unknown)
        val rejected = learn(watched, InteractionType.DISLIKED, input = unknown)
        assertTrue(rejected.channelScores.isEmpty())
        assertTrue(rejected.channelTopicProfiles.isEmpty())
        assertTrue(rejected.channelMemory.entries.isEmpty())
        assertTrue(watched.globalVector.topics.isNotEmpty())
        assertEquals(1, rejected.idfTotalDocuments)
        assertTrue(rejected.topicEvidence.values.all { it.channelIds.isEmpty() })
    }

    @Test
    fun notInterestedSuppressesVideoAndTemporarilySuppressesChannelWithoutPermanentBlock() {
        val learned = learn(UserBrain(), InteractionType.WATCHED, 0.9f)
        val first = VideoLearning.notInterested(learned, video, NeuroTokenizer(), now)
        val second = VideoLearning.notInterested(first, video, NeuroTokenizer(), now + 1000)
        assertEquals(now + 1000, second.suppressedVideoIds.getValue(video.id))
        assertEquals(now + 1000, second.suppressedChannels.getValue(video.channelId))
        assertTrue(second.blockedChannels.isEmpty())
        assertTrue(second.channelScores.getValue(video.channelId) < learned.channelScores.getValue(video.channelId))
        assertTrue(second.topicEvidence.values.any { it.negativeSignals >= 2 })
        assertEquals(3, second.totalInteractions)
    }

    @Test
    fun notInterestedCapsPersistentVideoMarksByAge() {
        val marks = (0 until 5000).associate { "old-$it" to it.toLong() }
        val rejected = VideoLearning.notInterested(UserBrain(suppressedVideoIds = marks), video, NeuroTokenizer(), now)
        assertEquals(5000, rejected.suppressedVideoIds.size)
        assertFalse(rejected.suppressedVideoIds.containsKey("old-0"))
        assertTrue(rejected.suppressedVideoIds.containsKey(video.id))
    }

    @Test(expected = IllegalArgumentException::class)
    fun invalidWatchFractionCannotContaminateModel() {
        learn(UserBrain(), InteractionType.WATCHED, Float.NaN)
    }

    @Test
    fun recentChannelSuppressionRetainsNewestHundredAndCanBeSerialized() {
        val marks = (0 until 100).associate { "recent-$it" to now - 100 + it }
        val rejected = VideoLearning.notInterested(
            UserBrain(suppressedChannels = marks), video, NeuroTokenizer(), now,
        )
        assertEquals(100, rejected.suppressedChannels.size)
        assertFalse(rejected.suppressedChannels.containsKey("recent-0"))
        assertEquals(now, rejected.suppressedChannels.getValue(video.channelId))
        assertTrue(rejected.blockedChannels.isEmpty())
        assertEquals(rejected.suppressedChannels, VideoStateCodec.decode(VideoStateCodec.encode(rejected)).suppressedChannels)
    }
}
