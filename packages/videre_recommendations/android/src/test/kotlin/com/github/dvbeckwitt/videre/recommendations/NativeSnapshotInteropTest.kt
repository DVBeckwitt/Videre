package com.github.dvbeckwitt.videre.recommendations

import io.flutter.plugin.common.StandardMessageCodec
import java.io.File
import org.junit.Assert.assertEquals
import org.junit.Test

/** Exercises the actual Flutter wire codec; the synthetic artifact also feeds Dart acceptance checks. */
class NativeSnapshotInteropTest {
    @Test fun bothSnapshotsSurviveTheFlutterMessageCodec() {
        val at = 1_800_000_000_000L
        val candidate = mapOf<String,Any?>("id" to "fixture-track", "title" to "Guitar melody", "authorId" to "UCfixture", "author" to "Fixture", "artistKey" to "UCfixtureArtist", "artist" to "Fixture Artist", "durationSeconds" to 240, "genre" to "rock")
        val outputs = listOf("video", "music").associateWith { domain ->
            val state = if (domain == "video") mapOf("schemaVersion" to 1, "domain" to domain, "languageProfile" to "en", "keyLanguage" to "en") else emptyMap()
            val output = RecommendationEvaluator.evaluate(mapOf("domain" to domain, "state" to state, "candidates" to listOf(candidate), "events" to listOf(mapOf("id" to "fixture-listen", "type" to "listen", "candidate" to candidate, "playedMs" to 220000L, "durationMs" to 240000L, "timeMs" to at)), "nowMs" to at, "seed" to 1))
            val encoded = StandardMessageCodec.INSTANCE.encodeMessage(output)!!
            encoded.flip()
            assertEquals(output, StandardMessageCodec.INSTANCE.decodeMessage(encoded))
            output
        }
        File("build/native-snapshot-interop.json").also { requireNotNull(it.parentFile).mkdirs() }.writeText(json(outputs))
    }

    private fun json(value: Any?): String = when (value) {
        null -> "null"
        is Boolean, is Number -> value.toString()
        is String -> "\"" + value.map { char -> when (char) { '"' -> "\\\""; '\\' -> "\\\\"; '\n' -> "\\n"; '\r' -> "\\r"; '\t' -> "\\t"; else -> if (char.code < 32) "\\u%04x".format(char.code) else char.toString() } }.joinToString("") + "\""
        is List<*> -> value.joinToString(",", "[", "]") { json(it) }
        is Map<*,*> -> value.entries.joinToString(",", "{", "}") { json(it.key) + ":" + json(it.value) }
        else -> error("Nonportable snapshot value")
    }
}
