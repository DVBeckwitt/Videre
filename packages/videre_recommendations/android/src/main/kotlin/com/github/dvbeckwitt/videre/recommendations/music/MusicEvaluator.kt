/*
 * Copyright (C) 2026 Videre contributors
 * Adapter for Flow Android Client's MusicBrain, pinned at
 * 565d1f7a3da4ca8e54463b029f151ef87415858a.
 * https://github.com/Flow-Tube/Flow
 * SPDX-License-Identifier: GPL-3.0-only
 */
package com.github.dvbeckwitt.videre.recommendations.music

import com.github.dvbeckwitt.videre.recommendations.SubscriptionChannel

/**
 * Stateless batch boundary around the upstream music algorithms. It performs no
 * I/O and does not own a player, network client, preferences or durable storage.
 * A listen event is one finalized playback occurrence, never a progress tick.
 */
object MusicEvaluator {
    fun evaluate(
        state: Map<String, Any?>,
        candidates: List<Map<String, Any?>>,
        events: List<Map<String, Any?>>,
        nowMs: Long,
        surface: String = MusicBrainRanker.SURFACE_QUICK_PICKS,
        subscriptionChannels: List<SubscriptionChannel> = emptyList(),
    ): Map<String, Any?> {
        require(candidates.size <= 1000 && events.size <= 1000) { "Music batch is oversized" }
        require(nowMs >= 0) { "Invalid evaluation time" }
        val brain = MusicStateCodec.decode(state)
        val processed = LinkedHashSet(MusicStateCodec.strings(state["processedEventIds"], MusicStateCodec.EVENT_LIMIT))
        // Retain the incoming snapshot throughout this batch, even if its oldest
        // ids leave the bounded persisted ring while newer events are applied.
        val deliveredThisBatch = HashSet(processed)
        val anchor = MusicStateCodec.entries(state["sessionAnchor"], 2)
        var previousArtist = MusicStateCodec.string(anchor["artistKey"], 512).takeIf { it.isNotEmpty() }
        var previousAt = MusicStateCodec.timestamp(anchor["atMs"])
        if (nowMs < previousAt || nowMs - previousAt >= MusicBrainParams.SESSION_GAP_MS) previousArtist = null
        var applied = 0
        var ignored = 0

        events.sortedBy { MusicStateCodec.timestamp(it["timeMs"], nowMs) }.forEach { event ->
            val eventId = MusicStateCodec.string(event["id"], 512)
            require(eventId.isNotBlank()) { "Music event needs a stable id" }
            if (!deliveredThisBatch.add(eventId)) return@forEach
            processed.add(eventId)
            while (processed.size > MusicStateCodec.EVENT_LIMIT) processed.remove(processed.first())
            val type = MusicStateCodec.string(event["type"], 40)
            val candidate = MusicStateCodec.entries(event["candidate"], 40)
            val at = MusicStateCodec.timestamp(event["timeMs"], nowMs).coerceAtMost(nowMs)
            val track = parseTrack(candidate)
            if (track.artistKey.isEmpty() || (track.id.isEmpty() && type in setOf("listen", "like"))) {
                ignored++
                return@forEach
            }
            val signal = MusicSignal(
                trackId = track.id,
                artistKey = track.artistKey,
                artistDisplay = track.artist,
                genre = track.genre,
                percentPlayed = 0.0,
                title = track.title,
                thumbnail = "",
            )
            when (type) {
                "listen", "like" -> {
                    val duration = MusicStateCodec.number(event["durationMs"], 0.0, 0.0, 1.0e12)
                    val played = MusicStateCodec.number(event["playedMs"], 0.0, 0.0, 1.0e12)
                    val fraction = if (type == "listen" && duration > 0) (played / duration).coerceIn(0.0, 1.0) else 0.0
                    val crossed = MusicBrainLearn.newlyCrossed(0.0, fraction)
                    if (crossed.isEmpty() && type != "like") {
                        ignored++
                        return@forEach
                    }
                    // Imported counters must not overflow the upstream Int counters.
                    // A name-key entry may be folded into the explicit id during learning.
                    val nameKey = track.artist.trim().lowercase()
                    val oldNamePlays = if (isIdKeyedArtist(track.artistKey) && nameKey != track.artistKey) {
                        brain.artistAffinity[nameKey]?.plays ?: 0
                    } else 0
                    val combinedPlays = (brain.artistAffinity[track.artistKey]?.plays ?: 0).toLong() + oldNamePlays
                    val willCount = type == "like" || crossed.any { it >= MusicBrainParams.COUNT_MILESTONE }
                    require(combinedPlays + (if (willCount) 1 else 0) <= Int.MAX_VALUE && (!willCount || brain.totalPlays < Int.MAX_VALUE)) {
                        "Music play counter is out of range"
                    }
                    val coArtist = previousArtist?.takeIf {
                        it != track.artistKey && at >= previousAt && at - previousAt < MusicBrainParams.SESSION_GAP_MS
                    }
                    val counted = MusicBrainLearn.applyMusicSignal(
                        brain,
                        signal.copy(percentPlayed = fraction, isExplicitLike = type == "like"),
                        crossed,
                        at,
                        // Upstream explicit likes update the anchor but do not create a co-listen edge.
                        if (type == "like") null else coArtist,
                    )
                    if (counted) {
                        previousArtist = track.artistKey
                        previousAt = at
                    }
                    applied++
                }
                "dislike", "notInterested", "not_interested" -> {
                    MusicBrainLearn.applyDislike(brain, track.artistKey, at)
                    applied++
                }
                "block" -> {
                    MusicBrainLearn.blockArtist(brain, track.artistKey)
                    applied++
                }
                "unblock" -> {
                    MusicBrainLearn.unblockArtist(brain, track.artistKey)
                    applied++
                }
                // Flow has no negative learning for an early skip and no music search/save signal.
                // A caller may send these to record delivery, but must not relabel them as dislikes/likes.
                "skip", "save", "search" -> ignored++
                else -> throw IllegalArgumentException("Unsupported music event type: $type")
            }
        }

        MusicBrainLearn.prune(brain)
        // Bound per-bucket genre evidence at the same genre cap as the upstream global model.
        brain.timeBuckets.values.forEach { genres ->
            if (genres.size > MusicBrainParams.GENRE_AFFINITY_MAX) {
                genres.keys.retainAll(genres.entries.sortedByDescending { it.value }.take(MusicBrainParams.GENRE_AFFINITY_MAX).map { it.key }.toSet())
            }
        }

        // The upstream facade filters blocked singletons before calling rank(), which short-circuits.
        val tracks = candidates.map(::parseTrack).filter { it.id.isNotEmpty() }
            .distinctBy { it.id }.filterNot { brain.isArtistBlocked(it.artistKey) }
        val inputs = tracks.map { MusicRankInput(it.id, it.artistKey, it.genre) }
        val next = MusicStateCodec.encode(brain)
        val hidden = MusicBrainLearn.hiddenArtistKeys(brain, nowMs)
        // The caller sends only followed channels with verified Music metadata.
        // Use Flow's favourite-artist affinity floor in a temporary ranking model.
        val followed = subscriptionChannels.associate { "uploader:${it.id}" to it.name }
            .filter { (key, name) -> key !in hidden && name.lowercase() !in hidden }
        val rankingBrain = if (followed.isEmpty()) brain else MusicStateCodec.decode(next).also { copy ->
            followed.forEach { (key, name) -> MusicBrainLearn.setFavouriteArtist(copy, key, name, favourite = true) }
        }
        val order = MusicBrainRanker.rank(rankingBrain, inputs, surface, nowMs)
        val weights = MusicBrainRanker.surfaceWeights(surface)
        val anchors = rankingBrain.topArtists(MusicBrainParams.COOC_ANCHOR_ARTISTS).map { it.first }
        val bucket = MusicTimeBucket.fromTimestamp(nowMs)
        val ranked = order.map { index ->
            val track = tracks[index]
            linkedMapOf<String, Any?>(
                "id" to track.id,
                // This is the upstream score before novelty composition and artist spreading.
                "score" to MusicBrainRanker.scoreCandidate(rankingBrain, inputs[index], weights, anchors, bucket, nowMs),
                "reason" to reason(brain, inputs[index], anchors, nowMs, track.artistKey in followed),
            )
        }
        next["processedEventIds"] = processed.toList()
        if (previousArtist != null && nowMs >= previousAt && nowMs - previousAt < MusicBrainParams.SESSION_GAP_MS) {
            next["sessionAnchor"] = linkedMapOf("artistKey" to previousArtist, "atMs" to previousAt)
        }
        return linkedMapOf(
            "state" to next,
            "ranked" to ranked,
            "summary" to linkedMapOf(
                "domain" to "music",
                "totalPlays" to brain.totalPlays,
                "artistCount" to brain.artistAffinity.size,
                "discoveryAppetite" to brain.discoveryAppetite,
                "appliedEvents" to applied,
                "ignoredEvents" to ignored,
                "scoresArePreDiversity" to true,
                "topArtists" to brain.topArtists(12).map { (key, score) ->
                    linkedMapOf("key" to key, "name" to (brain.artistAffinity[key]?.display ?: ""), "score" to score)
                },
                "blockedArtists" to brain.blockedArtists.sorted(),
                "hiddenArtists" to hidden.sorted(),
                "onRepeat" to MusicBrainRanker.heavyRotation(brain, nowMs, 16).filterNot { brain.trackMeta[it]?.artistKey in hidden },
                "rediscover" to MusicBrainRanker.rediscover(brain, nowMs, 12),
                "timeOfDay" to MusicBrainRanker.timeOfDayRotation(brain, nowMs, 12),
                "timeBucket" to bucket.wireName,
                "dailyMixes" to MusicBrainMixes.dailyMixes(brain, nowMs, 3).map {
                    linkedMapOf("label" to it.label, "seedTrackIds" to it.seedTrackIds)
                },
            ),
        )
    }

    private data class Track(val id: String, val title: String, val artist: String, val artistKey: String, val genre: String?)

    private fun parseTrack(candidate: Map<String, Any?>): Track {
        val artist = MusicStateCodec.string(candidate["artist"]).trim()
        // author/authorId are uploader fields. They are not automatically a musical artist.
        val key = musicArtistKey(MusicStateCodec.string(candidate["artistKey"], 512), artist)
        return Track(
            id = MusicStateCodec.string(candidate["id"], 512).trim(),
            title = MusicStateCodec.string(candidate["title"]),
            artist = artist,
            artistKey = key,
            genre = MusicStateCodec.string(candidate["genre"], 512).trim().lowercase().takeIf { it.isNotEmpty() },
        )
    }

    private fun reason(brain: MusicBrain, input: MusicRankInput, anchors: List<String>, nowMs: Long, followed: Boolean): String = when {
        MusicBrainRanker.isInDislikeCooldown(brain, input.artistKey, nowMs) -> "Lower priority after your feedback"
        // Flow records a counted occurrence for either a listen or an explicit like.
        MusicBrainRanker.baseLevelActivation(brain, input.trackId, nowMs) > 0.0 -> "A song you have listened to or liked"
        followed -> "From a music creator you follow"
        (brain.artistAffinity[input.artistKey]?.score ?: 0.0) > 0.0 -> "An artist you have listened to or liked"
        MusicBrainRanker.coocScore(brain, input.artistKey, anchors) > 0.0 -> "An artist linked to others you listen to or like"
        (input.genre?.let { brain.genreAffinity[it] } ?: 0.0) > 0.0 -> "A genre from your listens or likes"
        input.artistKey.isNotEmpty() && input.artistKey !in brain.seenArtists -> "A new artist to explore"
        else -> "From the available music candidates"
    }
}
