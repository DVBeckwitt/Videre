package com.github.dvbeckwitt.videre.recommendations

import com.github.dvbeckwitt.videre.recommendations.video.VideoEvaluator
import com.github.dvbeckwitt.videre.recommendations.music.MusicEvaluator

/** Validates the platform boundary before doing any work; evaluation is stateless. */
object RecommendationEvaluator {
    fun evaluate(arguments: Any?): Map<String, Any?> {
        validateTree(arguments)
        val request = stringMap(arguments)
        val domain = request["domain"] as? String
        require(domain == "video" || domain == "music") { "Unsupported recommendation domain." }
        val state = stringMap(request["state"] ?: emptyMap<String, Any?>())
        require(state["domain"] == null || state["domain"] == domain) { "Recommendation state domain mismatch." }
        require(!state.containsKey("schemaVersion") || integral(state["schemaVersion"], 1L, 1L) != null) { "Unsupported recommendation state schema." }
        val candidates = mapList(request["candidates"])
        val events = mapList(request["events"])
        val subscriptions = subscriptionChannels(request["subscriptionChannels"])
        require(candidates.size <= 1000 && events.size <= 1000) { "Recommendation batch exceeds limit." }
        require(candidates.all { validId(it["id"]) }) { "Candidate identity is required and must fit the limit." }
        require(events.all { validId(it["id"]) }) { "Event identity is required and must fit the limit." }
        require(events.all { it["candidate"] == null || validId(stringMap(it["candidate"])["id"]) }) { "Event candidate identity is invalid." }
        require(events.all { it["type"] in if (domain == "video") videoEvents else musicEvents }) { "Unsupported recommendation event." }
        val now = integral(request["nowMs"], 0L, 253_402_300_799_999L)
        require(now != null) { "An integral evaluation timestamp within range is required." }
        require(events.all { !it.containsKey("timeMs") || integral(it["timeMs"], 0L, 253_402_300_799_999L) != null }) { "Invalid event timestamp." }
        val seed = if (request.containsKey("seed")) integral(request["seed"], 0L, 9_000_000_000_000_000L) else 0L
        require(seed != null) { "Invalid recommendation seed." }
        val result = if (domain == "music") {
            MusicEvaluator.evaluate(state, candidates, events, now, request["surface"] as? String ?: "quick_picks", subscriptions)
        } else {
            VideoEvaluator.evaluate(state, candidates, events, now, seed, subscriptions)
        }
        return result + mapOf("schemaVersion" to 1, "domain" to domain)
    }

    private val videoEvents = setOf("listen", "like", "dislike", "skip", "save", "search", "notInterested", "block", "unblock", "impression", "click", "favorite")
    private val musicEvents = setOf("listen", "like", "dislike", "skip", "save", "search", "notInterested", "block", "unblock")
    private val channelId = Regex("UC[A-Za-z0-9_-]{22}")

    private fun subscriptionChannels(value: Any?): List<SubscriptionChannel> {
        if (value == null) return emptyList()
        require(value is List<*> && value.size <= 200) { "Invalid subscription batch." }
        return value.map { item ->
            val row = stringMap(item)
            val id = row["id"]
            val name = row["name"]
            require(row.size == 2 && id is String && channelId.matches(id) && name is String && name.length <= 300) {
                "Invalid subscription channel."
            }
            SubscriptionChannel(id, name.trim())
        }.distinctBy { it.id }.sortedBy { it.id }
    }

    private fun validId(value: Any?): Boolean = value is String && value.isNotBlank() && value.length <= 512

    private fun integral(value: Any?, minimum: Long, maximum: Long): Long? {
        if (value !is Number) return null
        val number = value.toDouble()
        if (!number.isFinite() || number < minimum.toDouble() || number > maximum.toDouble() || number % 1.0 != 0.0) return null
        return number.toLong()
    }

    private fun mapList(value: Any?): List<Map<String, Any?>> {
        require(value == null || value is List<*>) { "A recommendation batch must be a list." }
        return (value as? List<*>).orEmpty().map(::stringMap)
    }

    private fun stringMap(value: Any?): Map<String, Any?> {
        require(value is Map<*, *> && value.keys.all { it is String }) { "Expected a string-keyed object." }
        @Suppress("UNCHECKED_CAST")
        return value as Map<String, Any?>
    }

    private fun validateTree(value: Any?) {
        var nodes = 0
        var textCharacters = 0L
        fun visit(item: Any?, depth: Int) {
            require(++nodes <= 250_000 && depth <= 16) { "Recommendation data exceeds limits." }
            when (item) {
                null, is Boolean, is Int, is Long -> Unit
                is Double -> require(item.isFinite()) { "Recommendation numbers must be finite." }
                is Float -> require(item.isFinite()) { "Recommendation numbers must be finite." }
                is String -> {
                    textCharacters += item.length
                    require(item.length <= 65_536 && textCharacters <= 8_000_000L) { "Recommendation text exceeds limit." }
                }
                is Map<*, *> -> {
                    require(item.size <= 25_000 && item.keys.all { it is String }) { "Recommendation object exceeds limits." }
                    item.forEach { (key, child) -> visit(key, depth + 1); visit(child, depth + 1) }
                }
                is List<*> -> {
                    require(item.size <= 25_000) { "Recommendation list exceeds limit." }
                    item.forEach { visit(it, depth + 1) }
                }
                else -> throw IllegalArgumentException("Unsupported recommendation value.")
            }
        }
        visit(value, 0)
    }
}
