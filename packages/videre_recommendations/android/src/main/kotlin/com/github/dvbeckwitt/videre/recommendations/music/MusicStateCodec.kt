/*
 * Copyright (C) 2026 Videre contributors
 * State adapter for Flow Android Client's MusicBrain.
 * Upstream: https://github.com/Flow-Tube/Flow
 * SPDX-License-Identifier: GPL-3.0-only
 */
package com.github.dvbeckwitt.videre.recommendations.music

/** A bounded, platform-codec-safe snapshot. Dart is the sole durable owner. */
internal object MusicStateCodec {
    const val EVENT_LIMIT = 1000

    fun decode(state: Map<String, Any?>): MusicBrain {
        if (state.isNotEmpty()) {
            require(state["domain"] == "music") { "Music state has the wrong domain" }
            require(integer(state["schemaVersion"], 1, 1, 1) == 1) { "Unsupported music schema" }
        }
        val brain = MusicBrain()
        entries(state["artistAffinity"], MusicBrainParams.ARTIST_AFFINITY_MAX).forEach { (key, value) ->
            val row = entries(value, 8)
            brain.artistAffinity[key] = MusicAffinity(
                plays = integer(row["plays"], 0, 0, Int.MAX_VALUE),
                score = number(row["score"], 0.0, 0.0, 1.0),
                lastPlayed = timestamp(row["lastPlayed"]),
                liked = boolean(row["liked"]),
                display = string(row["display"]),
            )
        }
        doubles(state["genreAffinity"], MusicBrainParams.GENRE_AFFINITY_MAX, 1.0, brain.genreAffinity)
        entries(state["trackPlays"], MusicBrainParams.TRACK_PLAYS_MAX).forEach { (key, value) ->
            brain.trackPlays[key] = list(value, MusicBrainParams.TRACK_RING).map(::timestamp).toMutableList()
        }
        entries(state["trackMeta"], MusicBrainParams.TRACK_PLAYS_MAX).forEach { (key, value) ->
            val row = entries(value, 8)
            brain.trackMeta[key] = MusicTrackMeta(string(row["title"]), string(row["artist"]), string(row["artistKey"]), "")
        }
        doubles(state["recentRotation"], MusicBrainParams.RECENT_ROTATION_MAX, 1.0, brain.recentRotation)
        doubles(state["artistCooc"], MusicBrainParams.ARTIST_COOC_MAX, 1.0e100, brain.artistCooc)
        entries(state["artistRelated"], MusicBrainParams.ARTIST_RELATED_MAX).forEach { (key, value) ->
            brain.artistRelated[key] = strings(value, MusicBrainParams.ARTIST_RELATED_EDGES).toMutableList()
        }
        entries(state["timeBuckets"], MusicTimeBucket.entries.size).forEach { (key, value) ->
            val bucket = requireNotNull(MusicTimeBucket.fromWire(key)) { "Invalid music time bucket" }
            val counts = HashMap<String, Double>()
            doubles(value, MusicBrainParams.GENRE_AFFINITY_MAX, 1.0e100, counts)
            brain.timeBuckets[bucket] = counts
        }
        brain.seenArtists.addAll(strings(state["seenArtists"], MusicBrainParams.SEEN_ARTISTS_MAX))
        entries(state["dislikedArtists"], MusicBrainParams.DISLIKED_MAX).forEach { (key, value) ->
            brain.dislikedArtists[key] = timestamp(value)
        }
        brain.blockedArtists.addAll(strings(state["blockedArtists"], MusicBrainParams.BLOCKED_MAX))
        brain.discoveryAppetite = number(state["discoveryAppetite"], MusicBrainParams.DISCOVERY_NEUTRAL, 0.0, 1.0)
        brain.totalPlays = integer(state["totalPlays"], 0, 0, Int.MAX_VALUE)
        brain.lastRotationDecay = timestamp(state["lastRotationDecay"])
        // Videre never automatically replays historical listens. Backfill is a caller action.
        brain.backfilled = true
        return brain
    }

    fun encode(brain: MusicBrain): MutableMap<String, Any?> = linkedMapOf(
        "schemaVersion" to 1,
        "domain" to "music",
        "artistAffinity" to brain.artistAffinity.mapValues { (_, it) ->
            linkedMapOf("plays" to it.plays, "score" to it.score, "lastPlayed" to it.lastPlayed, "liked" to it.liked, "display" to it.display)
        },
        "genreAffinity" to brain.genreAffinity.toMap(),
        "trackPlays" to brain.trackPlays.mapValues { it.value.toList() },
        "trackMeta" to brain.trackMeta.mapValues { (_, it) ->
            // Artwork URLs are not part of recommendation state or backups.
            linkedMapOf("title" to it.title, "artist" to it.artist, "artistKey" to it.artistKey)
        },
        "recentRotation" to brain.recentRotation.toMap(),
        "artistCooc" to brain.artistCooc.toMap(),
        "artistRelated" to brain.artistRelated.mapValues { it.value.toList() },
        "timeBuckets" to brain.timeBuckets.mapKeys { it.key.wireName }.mapValues { it.value.toMap() },
        "seenArtists" to brain.seenArtists.sorted(),
        "dislikedArtists" to brain.dislikedArtists.toMap(),
        "blockedArtists" to brain.blockedArtists.sorted(),
        "discoveryAppetite" to brain.discoveryAppetite,
        "totalPlays" to brain.totalPlays,
        "lastRotationDecay" to brain.lastRotationDecay,
        "backfilled" to true,
    )

    fun entries(value: Any?, max: Int): Map<String, Any?> {
        if (value == null) return emptyMap()
        require(value is Map<*, *> && value.size <= max) { "Music state map is invalid or oversized" }
        return value.entries.associate { (key, item) ->
            require(key is String && key.length <= 2048 && key.isNotBlank()) { "Invalid music state key" }
            key to item
        }
    }

    fun list(value: Any?, max: Int): List<Any?> {
        if (value == null) return emptyList()
        require(value is List<*> && value.size <= max) { "Music state list is invalid or oversized" }
        return value
    }

    fun strings(value: Any?, max: Int): List<String> = list(value, max).map { string(it, 512) }.filter { it.isNotBlank() }

    fun string(value: Any?, max: Int = 4096): String {
        if (value == null) return ""
        require(value is String && value.length <= max) { "Invalid music state string" }
        return value
    }

    fun number(value: Any?, default: Double, min: Double = 0.0, max: Double = 1.0e12): Double {
        if (value == null) return default
        require(value is Number) { "Invalid music state number" }
        val result = value.toDouble()
        require(result.isFinite() && result in min..max) { "Music state number is out of range" }
        return result
    }

    fun integer(value: Any?, default: Int, min: Int = 0, max: Int = Int.MAX_VALUE): Int {
        val result = number(value, default.toDouble(), min.toDouble(), max.toDouble())
        require(result == result.toLong().toDouble()) { "Music state integer is fractional" }
        return result.toInt()
    }

    fun timestamp(value: Any?, default: Long = 0L): Long {
        val result = number(value, default.toDouble(), 0.0, 253402300799999.0)
        require(result == result.toLong().toDouble()) { "Music timestamp is fractional" }
        return result.toLong()
    }

    private fun boolean(value: Any?): Boolean {
        if (value == null) return false
        require(value is Boolean) { "Invalid music state boolean" }
        return value
    }

    private fun doubles(value: Any?, maxEntries: Int, maxValue: Double, target: MutableMap<String, Double>) {
        entries(value, maxEntries).forEach { (key, item) -> target[key] = number(item, 0.0, 0.0, maxValue) }
    }
}
