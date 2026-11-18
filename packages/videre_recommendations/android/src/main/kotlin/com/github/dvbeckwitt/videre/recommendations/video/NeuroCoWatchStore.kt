/*
 * Copyright (C) 2025-2026 Flow | A-EDev
 * Copyright (C) 2026 Videre contributors
 * Pure graph rules from Flow Android Client NeuroCoWatchStore at
 * 565d1f7a3da4ca8e54463b029f151ef87415858a.
 * https://github.com/Flow-Tube/Flow
 * SPDX-License-Identifier: GPL-3.0-only
 */
package com.github.dvbeckwitt.videre.recommendations.video

import kotlin.math.pow

/** Flow's bounded co-watch graph over related metadata already admitted by Videre. */
internal object NeuroCoWatchStore {
    const val MAX_SOURCES = 200
    const val CHANNELS_PER_SOURCE = 10
    const val HALF_LIFE_MS = 45L * 24L * 60L * 60L * 1000L

    /** Fresh sources that make a pair as strong as it gets. */
    private const val FULL_STRENGTH_SOURCES = 2.0

    fun pairKey(
        a: String,
        b: String,
    ) = if (a < b) "$a|$b" else "$b|$a"

    /**
     * Confirmed channel pairs ("a|b") and their strength from 0 to 1: the decayed number of source
     * videos listing them, over [FULL_STRENGTH_SOURCES]. [isWatched] confirms a pair seen once.
     */
    fun edges(
        sources: Collection<Source>,
        isWatched: (channelId: String) -> Boolean,
        now: Long,
    ): Map<String, Double> {
        val weight = HashMap<String, Double>()
        val seen = HashMap<String, Int>()
        sources.forEach { source ->
            val decay = 0.5.pow((now - source.at).coerceAtLeast(0L).toDouble() / HALF_LIFE_MS)
            source.related.forEach { channel ->
                val key = pairKey(source.channelId, channel)
                weight.merge(key, decay, Double::plus)
                seen.merge(key, 1, Int::plus)
            }
        }
        return weight
            .filter { (key, _) ->
                (seen[key] ?: 0) >= 2 || key.split('|').all(isWatched)
            }.mapValues { (_, value) -> (value / FULL_STRENGTH_SOURCES).coerceAtMost(1.0) }
    }

    /** For each channel next to one the viewer watches, the strongest such pair. */
    fun neighbours(
        edges: Map<String, Double>,
        isWatched: (channelId: String) -> Boolean,
    ): Map<String, Double> {
        val strongest = HashMap<String, Double>()
        edges.forEach { (key, strength) ->
            val (a, b) = key.split('|')
            if (isWatched(a)) strongest.merge(b, strength, ::maxOf)
            if (isWatched(b)) strongest.merge(a, strength, ::maxOf)
        }
        return strongest
    }

    data class Source(val channelId: String, val related: List<String>, val at: Long)

    fun record(
        sources: Map<String, Source>,
        videoId: String,
        channelId: String,
        relatedChannels: List<String>,
        now: Long,
    ): Map<String, Source> {
        val related = relatedChannels.filter { it.isNotBlank() && it != channelId }
            .distinct().take(CHANNELS_PER_SOURCE)
        if (videoId.isBlank() || channelId.isBlank() || related.isEmpty()) return sources
        val updated = sources + (videoId to Source(channelId, related, now))
        return if (updated.size <= MAX_SOURCES) updated else updated.entries
            .sortedByDescending { it.value.at }.take(MAX_SOURCES).associate { it.key to it.value }
    }
}
