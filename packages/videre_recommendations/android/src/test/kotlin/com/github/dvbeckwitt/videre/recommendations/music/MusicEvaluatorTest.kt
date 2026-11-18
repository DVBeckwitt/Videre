/*
 * Copyright (C) 2025-2026 Flow | A-EDev
 * Copyright (C) 2026 Videre contributors
 * Core fixtures adapted from Flow Android Client's MusicBrainLearnTest,
 * MusicBrainRankerTest, and MusicBrainMixesTest at commit
 * 565d1f7a3da4ca8e54463b029f151ef87415858a.
 * https://github.com/Flow-Tube/Flow
 * SPDX-License-Identifier: GPL-3.0-only
 */
package com.github.dvbeckwitt.videre.recommendations.music

import org.junit.Assert.*
import org.junit.Test

class MusicEvaluatorTest {
    private val now = 1_700_000_000_000L

    private fun track(id: String = "song", artist: String = "Artist", key: String = "UCartist") =
        mapOf<String, Any?>("id" to id, "title" to "Song $id", "artist" to artist, "artistKey" to key)

    private fun event(
        id: String = "listen-1",
        type: String = "listen",
        track: Map<String, Any?> = track(),
        played: Long = 180_000,
        at: Long = now,
    ) = mapOf<String, Any?>(
        "id" to id, "type" to type, "candidate" to track,
        "playedMs" to played, "durationMs" to 180_000L, "timeMs" to at,
    )

    @Suppress("UNCHECKED_CAST")
    private fun state(result: Map<String, Any?>): Map<String, Any?> = result["state"] as Map<String, Any?>

    @Suppress("UNCHECKED_CAST")
    private fun ids(result: Map<String, Any?>): List<String> = (result["ranked"] as List<Map<String, Any?>>).map { it["id"] as String }

    @Test
    fun fullListenMatchesUpstreamMilestoneFixture() {
        val result = MusicEvaluator.evaluate(emptyMap(), listOf(track()), listOf(event()), now)
        val brain = MusicStateCodec.decode(state(result))
        assertEquals(1, brain.totalPlays)
        assertEquals(1, brain.artistAffinity["UCartist"]!!.plays)
        assertEquals(0.27718125, brain.artistAffinity["UCartist"]!!.score, 1e-12)
        assertEquals(0.35, brain.recentRotation["UCartist"]!!, 1e-12)
        assertEquals(listOf(now), brain.trackPlays["song"])
        assertEquals("", brain.trackMeta["song"]!!.thumbnail)
    }

    @Test
    fun fifteenPercentSampleDoesNotCountAPlay() {
        val result = MusicEvaluator.evaluate(emptyMap(), emptyList(), listOf(event(played = 36_000)), now)
        val brain = MusicStateCodec.decode(state(result))
        assertEquals(0, brain.totalPlays)
        assertEquals(0.0525, brain.artistAffinity["UCartist"]!!.score, 1e-12)
        assertTrue(brain.trackPlays.isEmpty())
    }

    @Test
    fun seekingOrCompletionFlagsDoNotCreateListeningTime() {
        val seek = event(played = 1_000) + mapOf("positionMs" to 180_000, "completed" to true)
        val result = MusicEvaluator.evaluate(emptyMap(), emptyList(), listOf(seek), now)
        assertTrue(MusicStateCodec.decode(state(result)).artistAffinity.isEmpty())
    }

    @Test
    fun eventReplayIsIdempotentAndNewOccurrenceRewardsRelistening() {
        val first = MusicEvaluator.evaluate(emptyMap(), emptyList(), listOf(event()), now)
        val retry = MusicEvaluator.evaluate(state(first), emptyList(), listOf(event()), now)
        assertEquals(state(first), state(retry))
        val replay = MusicEvaluator.evaluate(state(retry), emptyList(), listOf(event(id = "listen-2", at = now + 10_000)), now + 10_000)
        assertEquals(2, MusicStateCodec.decode(state(replay)).totalPlays)
    }

    @Test
    fun retryAtEndOfBatchRemainsDeduplicatedAfterRingEviction() {
        val first = MusicEvaluator.evaluate(emptyMap(), emptyList(), listOf(event(id = "old0", type = "like")), now)
        val fullRing = state(first) + ("processedEventIds" to (0 until 1000).map { "old$it" })
        val batch = (0 until 999).map { event(id = "new$it", type = "save") } + event(id = "old0", type = "like")
        val result = MusicEvaluator.evaluate(fullRing, emptyList(), batch, now)
        assertEquals(1, MusicStateCodec.decode(state(result)).totalPlays)
    }

    @Test
    fun explicitLikeUsesUpstreamFloorWithoutPlayedTime() {
        val result = MusicEvaluator.evaluate(emptyMap(), emptyList(), listOf(event(type = "like", played = 0)), now)
        val brain = MusicStateCodec.decode(state(result))
        assertEquals(0.8, brain.artistAffinity["UCartist"]!!.score, 1e-12)
        assertTrue(brain.artistAffinity["UCartist"]!!.liked)
        assertEquals(1, brain.totalPlays)
    }

    @Test
    fun explicitLikeCanExplainBothATrackAndItsArtistWithoutClaimingAListen() {
        val result = MusicEvaluator.evaluate(
            emptyMap(), listOf(track(), track("other")),
            listOf(event(type = "like", played = 0)), now,
        )
        val explanations = (result["ranked"] as List<*>).map { it as Map<*, *> }
            .associate { it["id"] to it["reason"] }
        assertEquals("A song you have listened to or liked", explanations["song"])
        assertEquals("An artist you have listened to or liked", explanations["other"])
    }

    @Test
    fun skipSaveAndSearchDoNotInventExplicitFeedback() {
        val events = listOf("skip", "save", "search").map { event(id = it, type = it) }
        val result = MusicEvaluator.evaluate(emptyMap(), emptyList(), events, now)
        val brain = MusicStateCodec.decode(state(result))
        assertTrue(brain.artistAffinity.isEmpty())
        assertTrue(brain.dislikedArtists.isEmpty())
        assertEquals(0, brain.totalPlays)
    }

    @Test
    fun uploaderIsNotAssumedToBeArtist() {
        val uploaderOnly = mapOf<String, Any?>("id" to "song", "title" to "Music", "author" to "Compilation channel", "authorId" to "UCuploader")
        val result = MusicEvaluator.evaluate(emptyMap(), listOf(uploaderOnly), listOf(event(track = uploaderOnly)), now)
        assertTrue(MusicStateCodec.decode(state(result)).artistAffinity.isEmpty())
        assertEquals(listOf("song"), ids(result))
    }

    @Test
    fun blockedSingletonNeverLeaksThroughRankerShortCircuit() {
        val result = MusicEvaluator.evaluate(emptyMap(), listOf(track()), listOf(event(type = "block")), now)
        assertTrue(ids(result).isEmpty())
        val unblocked = MusicEvaluator.evaluate(state(result), listOf(track()), listOf(event(id = "unblock", type = "unblock", track = mapOf("artistKey" to "UCartist"))), now)
        assertEquals(listOf("song"), ids(unblocked))
    }

    @Test
    fun explicitDislikeCooldownEscalatesAsUpstreamDoes() {
        val result = MusicEvaluator.evaluate(emptyMap(), emptyList(), listOf(event(type = "dislike")), now)
        assertTrue(MusicStateCodec.decode(state(result)).dislikedArtists.containsKey("UCartist"))
        val second = MusicEvaluator.evaluate(state(result), listOf(track()), listOf(event(id = "dislike-2", type = "notInterested")), now)
        assertTrue(MusicStateCodec.decode(state(second)).blockedArtists.contains("UCartist"))
        assertTrue(ids(second).isEmpty())
    }

    @Test
    fun adjacentSessionsCreateMixSeedsWithoutRemoteRequests() {
        val events = listOf(event(track = track("one", "One", "UCone")), event(id = "two", track = track("two", "Two", "UCtwo"), at = now + 10_000))
        val result = MusicEvaluator.evaluate(emptyMap(), emptyList(), events, now + 10_000)
        val brain = MusicStateCodec.decode(state(result))
        assertEquals(1.0, brain.artistCooc[musicPairKey("UCone", "UCtwo")]!!, 0.0)
        val mixes = MusicBrainMixes.dailyMixes(brain, now + 10_000, 3)
        assertEquals(1, mixes.size)
        assertEquals(setOf("one", "two"), mixes.single().seedTrackIds.toSet())
    }

    @Test
    fun expiredAnchorDoesNotInventAListeningSession() {
        val first = MusicEvaluator.evaluate(emptyMap(), emptyList(), listOf(event()), now)
        val later = now + MusicBrainParams.SESSION_GAP_MS + 1
        val second = MusicEvaluator.evaluate(state(first), emptyList(), listOf(event(id = "next", track = track("two", "Two", "UCtwo"), at = later)), later)
        assertTrue(MusicStateCodec.decode(state(second)).artistCooc.isEmpty())
    }

    @Test
    fun quickPicksAndDiscoverRetainUpstreamSurfaceDifference() {
        val brain = MusicBrain()
        brain.artistAffinity["UCfav"] = MusicAffinity(plays = 20, score = 0.9, lastPlayed = now)
        brain.seenArtists.add("UCfav")
        brain.totalPlays = 20
        brain.discoveryAppetite = 0.5
        repeat(6) { brain.artistCooc[musicPairKey("UCfav", "UCnew$it")] = 3.0 }
        val input = (0 until 6).map { MusicRankInput("f$it", "UCfav") } + (0 until 6).map { MusicRankInput("n$it", "UCnew$it") }
        fun novel(surface: String) = MusicBrainRanker.rank(brain, input, surface, now).take(6).count { input[it].artistKey.startsWith("UCnew") }
        assertTrue(novel("discover") > novel("quick_picks"))
    }

    @Test
    fun activationFixtureRewardsFrequencyAndRecency() {
        val brain = MusicBrain()
        brain.trackPlays["hot"] = (0 until 4).map { now - it * 3_600_000L }.toMutableList()
        brain.trackPlays["stale"] = mutableListOf(now - 21L * 86_400_000L)
        assertEquals(listOf("hot"), MusicBrainRanker.heavyRotation(brain, now, 10))
    }

    @Test
    fun stateRoundTripPreservesModelAndContainsNoArtwork() {
        val result = MusicEvaluator.evaluate(emptyMap(), emptyList(), listOf(event()), now)
        val snapshot = state(result)
        val encoded = MusicStateCodec.encode(MusicStateCodec.decode(snapshot))
        assertEquals(snapshot.filterKeys { it != "processedEventIds" && it != "sessionAnchor" }, encoded)
        assertFalse(encoded.toString().contains("thumbnail"))
    }

    @Test(expected = IllegalArgumentException::class)
    fun rejectsVideoStateRatherThanMixingProfiles() {
        MusicEvaluator.evaluate(mapOf("schemaVersion" to 1, "domain" to "video"), emptyList(), emptyList(), now)
    }

    @Test(expected = IllegalArgumentException::class)
    fun rejectsFutureSchema() {
        MusicEvaluator.evaluate(mapOf("schemaVersion" to 2, "domain" to "music"), emptyList(), emptyList(), now)
    }

    @Test(expected = IllegalArgumentException::class)
    fun rejectsNonfinitePersistedAffinity() {
        val snapshot = mapOf("schemaVersion" to 1, "domain" to "music", "genreAffinity" to mapOf("jazz" to Double.NaN))
        MusicEvaluator.evaluate(snapshot, emptyList(), emptyList(), now)
    }
}
