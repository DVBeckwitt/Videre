package com.github.dvbeckwitt.videre.recommendations

import java.io.File
import org.junit.Assert.*
import org.junit.Test

class RecommendationEvaluatorTest {
    private fun request(vararg changes: Pair<String,Any?>) = mapOf<String,Any?>("domain" to "video", "state" to emptyMap<String,Any?>(), "nowMs" to 1_800_000_000_000L, "candidates" to emptyList<Any>(), "events" to emptyList<Any>()) + changes
    private fun rejects(input: Map<String,Any?>) {
        try { RecommendationEvaluator.evaluate(input); fail("Invalid input was accepted") } catch (_: IllegalArgumentException) { }
    }

    @Test fun rejectsStateFromAnotherDomain() = rejects(request("state" to mapOf("domain" to "music")))
    @Test fun rejectsFutureOrMalformedSchema() {
        rejects(request("state" to mapOf("schemaVersion" to 2)))
        rejects(request("state" to mapOf("schemaVersion" to "1")))
        rejects(request("state" to mapOf("schemaVersion" to 1.5)))
    }
    @Test fun rejectsNonFiniteAndFractionalClock() {
        rejects(request("nowMs" to Double.NaN))
        rejects(request("nowMs" to 1.5))
        rejects(request("nowMs" to 1.0e30))
    }
    @Test fun requiresStableEventIdentity() = rejects(request("events" to listOf(mapOf("type" to "like"))))
    @Test fun enforcesBatchBudget() = rejects(request("candidates" to (0..1000).map { mapOf("id" to "item$it") }))
    @Test fun unsupportedMusicEventsFailExplicitly() = rejects(request("domain" to "music", "events" to listOf(mapOf("id" to "event", "type" to "impression"))))
    @Test fun rejectsNonPrimitiveData() = rejects(request("state" to mapOf("payload" to byteArrayOf(1,2))))
    @Test fun extractedCoreHasNoTransportOrDurableStorageDependency() {
        val directory = File("src/main/kotlin/com/github/dvbeckwitt/videre/recommendations")
        assertTrue(directory.isDirectory)
        val forbidden = Regex("^import (okhttp|java\\.net|android\\.content|androidx\\.datastore|io\\.github\\.aedev)", RegexOption.MULTILINE)
        directory.walkTopDown().filter { it.extension == "kt" }.forEach { file ->
            assertFalse("Forbidden dependency in ${file.name}", forbidden.containsMatchIn(file.readText()))
        }
    }
}
