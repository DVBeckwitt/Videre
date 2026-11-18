package com.github.dvbeckwitt.videre.recommendations.video

import com.github.dvbeckwitt.videre.recommendations.RecommendationEvaluator
import org.junit.Assert.*
import org.junit.Test

class VideoEvaluatorTest {
    private val now = 1_800_000_000_000L
    private val physics = mapOf<String, Any?>("id" to "physics", "title" to "Quantum physics experiment", "authorId" to "UCphysics", "author" to "Physics", "durationSeconds" to 600, "keywords" to listOf("quantum", "physics"))
    private val cooking = mapOf<String, Any?>("id" to "cooking", "title" to "Chocolate cake recipe", "authorId" to "UCcooking", "author" to "Baking", "durationSeconds" to 600, "keywords" to listOf("chocolate", "cake"))
    private val initial = mapOf<String, Any?>("schemaVersion" to 1, "domain" to "video", "languageProfile" to "en", "keyLanguage" to "en")
    private fun evaluate(state: Map<String, Any?> = initial, candidates: List<Map<String, Any?>> = listOf(physics, cooking), events: List<Map<String, Any?>> = emptyList()) =
        RecommendationEvaluator.evaluate(mapOf("domain" to "video", "state" to state, "candidates" to candidates, "events" to events, "nowMs" to now, "seed" to 17L))
    private fun state(result: Map<String, Any?>) = VideoStateCodec.map(result["state"])
    private fun ids(result: Map<String, Any?>) = (result["ranked"] as List<*>).map { VideoStateCodec.map(it)["id"] }
    private fun event(id: String, type: String, candidate: Map<String,Any?> = physics) = mapOf("id" to id, "type" to type, "candidate" to candidate, "playedMs" to 540_000L, "durationMs" to 600_000L, "timeMs" to now)

    @Test fun repeatedInputAndSeedProduceTheSameOrderAndScores() {
        assertEquals(evaluate(), evaluate())
    }

    @Test fun actualPositiveHistoryPromotesItsSubject() {
        val learned = evaluate(events = (0 until 35).map { event("listen-$it", "listen") })
        assertEquals("physics", ids(learned).first())
        assertEquals(35, state(learned)["totalInteractions"])
        val isolated = evaluate()
        assertEquals(0, state(isolated)["totalInteractions"])
    }

    @Test fun retriedEventsAreNotLearnedTwice() {
        val events = listOf(event("same-event", "like"))
        val first = evaluate(events = events)
        val repeated = evaluate(state(first), events = events)
        assertEquals(state(first)["globalVector"], state(repeated)["globalVector"])
        assertEquals(state(first)["totalInteractions"], state(repeated)["totalInteractions"])
        assertEquals(0, VideoStateCodec.map(repeated["summary"])["appliedEvents"])
    }

    @Test fun zeroConsumptionDoesNotBecomeNegativeEvidence() {
        val result = evaluate(events = listOf(event("buffer-failure", "listen") + ("playedMs" to 0L)))
        assertEquals(0, state(result)["totalInteractions"])
        assertTrue(VideoStateCodec.map(state(result)["channelScores"]).isEmpty())
    }

    @Test fun explicitUserSkipOnFinalizedListenUsesUpstreamSkipSignal() {
        val skipped = evaluate(events = listOf(event("user-next", "listen") + mapOf("playedMs" to 10_000L, "skipped" to true)))
        assertEquals(1, state(skipped)["totalInteractions"])
        assertEquals(1, state(skipped)["consecutiveSkips"])
        assertTrue((VideoStateCodec.map(state(skipped)["channelScores"])["UCphysics"] as Double) < 0.5)
    }

    @Test fun quickExplicitDepartureUsesElapsedTimeAndIgnoresSeekPosition() {
        val bounce = event("user-next", "listen") + mapOf(
            "playedMs" to 9_999L, "positionMs" to 540_000L, "skipped" to true,
        )
        val result = evaluate(events = listOf(bounce))
        assertEquals(0, state(result)["totalInteractions"])
        assertEquals(0, state(result)["consecutiveSkips"])
        assertTrue(VideoStateCodec.map(state(result)["channelScores"]).isEmpty())
    }

    @Test fun explicitDepartureAtTwentyPercentCountsAsWatched() {
        val result = evaluate(events = listOf(
            event("user-next", "listen") + mapOf(
                "playedMs" to 2_000L, "durationMs" to 10_000L, "skipped" to true,
            ),
        ))
        assertEquals(1, state(result)["totalInteractions"])
        assertEquals(0, state(result)["consecutiveSkips"])
        val fraction = VideoStateCodec.map(state(result)["watchHistoryMap"])["physics"] as Number
        assertEquals(0.20, fraction.toDouble(), 1e-7)
    }

    @Test fun interruptedTimeRetainsPositiveFractionAndDirectSkipRemainsSupported() {
        val interrupted = evaluate(events = listOf(
            event("recovered", "listen") + mapOf("playedMs" to 2_000L, "skipped" to false),
        ))
        assertEquals(1, state(interrupted)["totalInteractions"])
        assertEquals(0, state(interrupted)["consecutiveSkips"])
        val skipped = evaluate(events = listOf(
            event("direct-skip", "skip") + mapOf("playedMs" to 0L, "durationMs" to 0L),
        ))
        assertEquals(1, state(skipped)["consecutiveSkips"])
    }

    @Test fun completedFlagCannotManufactureAListenAfterSeekOrError() {
        val completed = evaluate(events = listOf(event("jump-to-end", "listen") + mapOf("playedMs" to 0L, "completed" to true, "skipped" to false)))
        assertEquals(0, state(completed)["totalInteractions"])
    }

    @Test fun notInterestedAndExplicitBlockRemainExcluded() {
        val hidden = evaluate(events = listOf(event("reject", "notInterested")))
        assertEquals(listOf("cooking"), ids(hidden))
        val blocked = evaluate(events = listOf(event("block", "block")))
        assertEquals(listOf("cooking"), ids(blocked))
        val restored = evaluate(state(blocked), events = listOf(event("unblock", "unblock")))
        assertTrue("physics" in ids(restored))
    }

    @Test fun onlyActualImpressionEventsChangeTheSeenLedger() {
        assertTrue(VideoStateCodec.map(state(evaluate())["feedHistory"]).isEmpty())
        val shown = evaluate(events = listOf(event("shown", "impression")))
        val repeated = evaluate(state(shown), events = listOf(event("shown-again", "impression")))
        assertEquals(1, VideoStateCodec.map(VideoStateCodec.map(state(repeated)["feedHistory"])["physics"])["showCount"])
        val liked = evaluate(state(repeated), events = listOf(event("liked", "like")))
        assertFalse(VideoStateCodec.map(VideoStateCodec.map(state(liked)["session"])["impressions"]).containsKey("physics"))
    }

    @Test fun searchLearnsLocallyWithoutInventingCandidates() {
        val result = evaluate(candidates = emptyList(), events = listOf(mapOf("id" to "search1", "type" to "search", "query" to "quantum physics", "timeMs" to now)))
        assertTrue(ids(result).isEmpty())
        assertFalse(VideoStateCodec.map(VideoStateCodec.map(state(result)["globalVector"])["topics"]).isEmpty())
    }

    @Test fun batchDeduplicationSurvivesRingEviction() {
        val snapshot = initial + ("processedEventIds" to (0 until 1000).map { "old-$it" })
        val result = evaluate(snapshot, events = listOf(event("new", "like"), event("old-0", "like")))
        assertEquals(1, state(result)["totalInteractions"])
    }

    @Test fun adapterSnapshotRoundTripPreservesLearnedEvidence() {
        val result = evaluate(events = listOf(event("listen", "listen"), event("like", "like")))
        val a = VideoStateCodec.decode(state(result))
        val b = VideoStateCodec.decode(VideoStateCodec.encode(a))
        assertEquals(a, b)
    }

    @Test fun learnedInterestUsesPinnedChipAndQueryPolicyAndPersistsItsOrder() {
        val learned = initial + mapOf(
            "globalVector" to mapOf("topics" to mapOf("minecraft" to 1.0)),
            "preferredTopics" to listOf("minecraft"),
            "topicEvidence" to mapOf("minecraft" to mapOf("watchSignals" to 3, "positiveScore" to 3.0)),
        )
        val first = evaluate(learned, candidates = emptyList())
        val summary = VideoStateCodec.map(first["summary"])
        val chip = VideoStateCodec.map((summary["interestChips"] as List<*>).single())
        assertEquals("minecraft", chip["id"])
        assertEquals(listOf("minecraft"), chip["queries"])
        assertTrue((summary["discoveryQueries"] as List<*>).any { (it as String).contains("minecraft", ignoreCase = true) })
        assertEquals(now, VideoStateCodec.map(state(first)["interestChips"])["computedAt"])
        val again = evaluate(state(first), candidates = emptyList())
        assertEquals(summary["interestChips"], VideoStateCodec.map(again["summary"])["interestChips"])
        assertEquals(state(first)["interestChips"], state(again)["interestChips"])
    }

    @Test fun actualWatchRecordsCategoryAndOnlyStrongPositiveSignalsConfirmGraph() {
        val creator = "UC" + "a".repeat(22)
        val related = "UC" + "b".repeat(22)
        val first = physics + mapOf("id" to "firstVideo1", "authorId" to creator, "category" to "Science & Technology")
        val second = first + ("id" to "secondVid02")
        val weak = evaluate(events = listOf(event("weak", "listen", first) +
            mapOf("playedMs" to 12_000L, "relatedChannels" to listOf(related))))
        assertTrue(VideoStateCodec.coWatchSources(state(weak)).isEmpty())
        val one = evaluate(state(weak), events = listOf(event("watched-1", "listen", first) +
            ("relatedChannels" to listOf(related))))
        val sources = VideoStateCodec.coWatchSources(state(one))
        assertTrue(NeuroCoWatchStore.edges(sources.values, { it == creator }, now).isEmpty())
        val two = evaluate(state(one), events = listOf(event("watched-2", "listen", second) +
            ("relatedChannels" to listOf(related))))
        val confirmed = NeuroCoWatchStore.edges(VideoStateCodec.coWatchSources(state(two)).values, { it == creator }, now)
        assertEquals(mapOf(related to 1.0), NeuroCoWatchStore.neighbours(confirmed) { it == creator })
        val category = NeuroCategoryIndex.categoryOf(VideoStateCodec.channelCategories(state(two)), creator)
        assertEquals(ChannelCategory("science", 0.75), category)
    }
}
