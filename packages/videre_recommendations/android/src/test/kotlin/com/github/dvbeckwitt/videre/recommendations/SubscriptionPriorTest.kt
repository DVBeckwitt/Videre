package com.github.dvbeckwitt.videre.recommendations

import com.github.dvbeckwitt.videre.recommendations.video.ContentVector
import com.github.dvbeckwitt.videre.recommendations.video.NeuroScoring
import com.github.dvbeckwitt.videre.recommendations.video.NeuroTokenizer
import com.github.dvbeckwitt.videre.recommendations.video.NeuroVectorMath
import com.github.dvbeckwitt.videre.recommendations.video.UserBrain
import com.github.dvbeckwitt.videre.recommendations.video.VideoSubscriptionPrior
import org.junit.Assert.assertEquals
import org.junit.Assert.assertSame
import org.junit.Assert.assertTrue
import org.junit.Assert.fail
import org.junit.Test

class SubscriptionPriorTest {
    private val now = 1_800_000_000_000L
    private val followed = "UC" + "a".repeat(22)
    private val other = "UC" + "b".repeat(22)
    private val channel = mapOf("id" to followed, "name" to "Ceramic Pottery")

    private fun evaluate(domain: String, vararg overrides: Pair<String, Any?>) =
        RecommendationEvaluator.evaluate(mapOf("domain" to domain, "nowMs" to now) + overrides)

    private fun rows(result: Map<String, Any?>): List<Map<*, *>> =
        (result["ranked"] as List<*>).filterIsInstance<Map<*, *>>()

    private fun score(result: Map<String, Any?>, id: String) =
        (rows(result).first { it["id"] == id }["score"] as Number).toDouble()

    @Test fun flowBootstrapUsesCappedNameWeightsAndDoesNotReplaceEstablishedTaste() {
        val tokenizer = NeuroTokenizer().apply { languageProfile = "en"; keyLanguage = "en" }
        val words = tokenizer.tokenize("Ceramic Pottery").toList()
        assertTrue(words.size >= 2)
        val base = UserBrain(globalVector = ContentVector(topics = mapOf(words[0] to 0.8)))
        val next = VideoSubscriptionPrior.apply(base, listOf("Ceramic Pottery", "Ceramic Pottery"), tokenizer)
        assertEquals(0.8, next.globalVector.topics.getValue(words[0]), 0.0)
        assertEquals(NeuroVectorMath.ESTABLISHED_TOPIC_THRESHOLD - 0.01, next.globalVector.topics.getValue(words[1]), 1e-9)
        assertEquals(0.15, next.topicAffinities[NeuroScoring.makeAffinityKey(words[0], words[1])]!!, 1e-9)
        assertTrue(next.preferredTopics.isEmpty())
        assertEquals(0, next.totalInteractions)
        val mature = base.copy(totalInteractions = 6)
        assertSame(mature, VideoSubscriptionPrior.apply(mature, listOf("Ceramic Pottery"), tokenizer))
    }

    @Test fun videoFollowWorksBeforeTheFirstWatchAndUnfollowLeavesNoLearnedTrace() {
        val candidates = listOf(
            mapOf("id" to "recording01", "title" to "Ceramic Pottery", "authorId" to followed),
            mapOf("id" to "recording02", "title" to "Running Form", "authorId" to other),
        )
        val empty = evaluate("video", "candidates" to candidates)
        val seeded = evaluate("video", "candidates" to candidates, "subscriptionChannels" to listOf(channel))
        val duplicate = evaluate("video", "candidates" to candidates, "subscriptionChannels" to listOf(channel, channel))
        assertTrue(score(seeded, "recording01") > score(empty, "recording01"))
        assertEquals("From a creator you follow", rows(seeded).first { it["id"] == "recording01" }["reason"])
        assertEquals(empty["state"], seeded["state"])
        assertEquals(seeded, duplicate)
        val unfollowed = evaluate("video", "candidates" to candidates, "state" to seeded["state"])
        assertEquals(empty["ranked"], unfollowed["ranked"])
        val blocked = evaluate("video", "candidates" to candidates, "subscriptionChannels" to listOf(channel),
            "state" to mapOf("blockedChannels" to listOf(followed)))
        assertEquals(listOf("recording02"), rows(blocked).map { it["id"] })
        assertTrue(((blocked["summary"] as Map<*, *>)["topTopics"] as List<*>).isEmpty())
    }

    @Test fun musicFollowUsesTheCreatorKeyAndDoesNotInventPlaysOrOverrideFeedback() {
        val key = "uploader:$followed"
        val candidates = listOf(
            mapOf("id" to "recording01", "artistKey" to key, "artist" to "Ceramic Pottery"),
            mapOf("id" to "recording02", "artistKey" to "uploader:$other", "artist" to "Ceramic Pottery"),
        )
        val empty = evaluate("music", "candidates" to candidates)
        val seeded = evaluate("music", "candidates" to candidates, "subscriptionChannels" to listOf(channel))
        assertTrue(score(seeded, "recording01") > score(empty, "recording01"))
        assertEquals("From a music creator you follow", rows(seeded).first { it["id"] == "recording01" }["reason"])
        assertEquals(score(empty, "recording02"), score(seeded, "recording02"), 0.0)
        assertEquals(empty["state"], seeded["state"])
        val cooldown = mapOf("domain" to "music", "dislikedArtists" to mapOf(key to now))
        val disliked = evaluate("music", "candidates" to candidates, "state" to cooldown)
        val stillDisliked = evaluate("music", "candidates" to candidates, "state" to cooldown,
            "subscriptionChannels" to listOf(channel))
        assertEquals(disliked, stillDisliked)
        val blocked = evaluate("music", "candidates" to candidates,
            "state" to mapOf("domain" to "music", "blockedArtists" to listOf(key)),
            "subscriptionChannels" to listOf(channel))
        assertEquals(listOf("recording02"), rows(blocked).map { it["id"] })
    }

    @Test fun rejectsMalformedOrOversizedSubscriptionBatches() {
        for (value in listOf(listOf(mapOf("id" to "https://example.invalid/", "name" to "x")),
            listOf(channel + mapOf("name" to "x".repeat(301))), List(201) { channel })) {
            try {
                evaluate("video", "subscriptionChannels" to value)
                fail("Invalid subscription metadata was accepted")
            } catch (_: IllegalArgumentException) {
                // Untrusted names and identities never enter Flow's tokenizer.
            }
        }
    }
}
