/*
 * Copyright (C) 2025-2026 Flow | A-EDev
 * Copyright (C) 2026 Videre contributors
 * Extracted/adapted from Flow Android Client, FlowNeuroEngine rankTraced and
 * recordFeedImpressions, and WatchSessionTracker.watchSignalFor at
 * 565d1f7a3da4ca8e54463b029f151ef87415858a.
 * https://github.com/Flow-Tube/Flow
 * SPDX-License-Identifier: GPL-3.0-only
 */
package com.github.dvbeckwitt.videre.recommendations.video

import com.github.dvbeckwitt.videre.recommendations.SubscriptionChannel
import java.util.Locale
import java.util.Random

/** Stateless transport-free orchestration around the pinned Flow algorithms. */
object VideoEvaluator {
    private const val WATCHED_FRACTION = 0.20
    private const val MIN_SKIP_SIGNAL_PLAYED_MS = 10_000

    fun evaluate(
        state: Map<String, Any?>,
        candidates: List<Map<String, Any?>>,
        events: List<Map<String, Any?>>,
        nowMs: Long,
        seed: Long,
        subscriptionChannels: List<SubscriptionChannel> = emptyList(),
    ): Map<String, Any?> {
        var brain = VideoStateCodec.decode(state)
        var coWatchSources = VideoStateCodec.coWatchSources(state)
        var channelCategories = VideoStateCodec.channelCategories(state)
        if (brain.languageProfile == null) brain = brain.copy(languageProfile = Locale.getDefault().language)
        if (brain.keyLanguage == null) brain = brain.copy(keyLanguage = brain.languageProfile)
        val tokenizer = NeuroTokenizer().apply {
            languageProfile = brain.languageProfile ?: "en"
            keyLanguage = brain.keyLanguage ?: languageProfile
        }
        val processed = VideoStateCodec.strings(state["processedEventIds"], 1000).toMutableSet()
        val session = VideoStateCodec.map(state["session"])
        val startedAt = VideoStateCodec.number(session["startedAt"], nowMs.toDouble()).toLong()
        val age = nowMs - startedAt
        val activeSession = if (age in 0..120 * 60_000L && !(age > 30 * 60_000L && VideoStateCodec.number(session["videoCount"]) == 0.0)) session else emptyMap()
        val sessionStart = if (activeSession.isEmpty()) nowMs else startedAt
        var videoCount = VideoStateCodec.number(activeSession["videoCount"]).toInt().coerceAtLeast(0)
        val sessionTopics = (activeSession["topics"] as? List<*>).orEmpty().filterIsInstance<String>().takeLast(50).toMutableList()
        val momentum = (activeSession["momentum"] as? List<*>).orEmpty().takeLast(10).map {
            val row = VideoStateCodec.map(it)
            MomentumEntry(VideoStateCodec.text(row["topic"]), row["positive"] == true)
        }.toMutableList()
        val impressions = VideoStateCodec.map(activeSession["impressions"]).entries.take(500).associate { (id, value) ->
            val row = VideoStateCodec.map(value)
            id to ImpressionEntry(VideoStateCodec.number(row["count"]).toInt().coerceAtLeast(0), VideoStateCodec.number(row["lastSeen"]).toLong())
        }.toMutableMap()
        var applied = 0
        var ignored = 0
        events.sortedBy { VideoStateCodec.number(it["timeMs"], nowMs.toDouble()) }.forEach { event ->
            val eventId = VideoStateCodec.text(event["id"])
            if (!processed.add(eventId)) return@forEach
            val at = VideoStateCodec.number(event["timeMs"], nowMs.toDouble()).toLong().coerceIn(0L, nowMs)
            val type = event["type"] as? String
            if (type == "search") {
                val query = VideoStateCodec.text(event["query"], 1000)
                val learned = NeuroSearchLearning.learn(brain, query, tokenizer, at)
                if (learned == null) ignored++ else {
                    val spellings = NeuroDisplayForms.spellingsIn(query, learned.globalVector.topics.keys, tokenizer)
                    brain = learned.copy(displayForms = NeuroDisplayForms.fillGaps(learned.displayForms, spellings) { it in learned.globalVector.topics })
                    applied++
                }
                return@forEach
            }
            val metadata = VideoStateCodec.map(event["candidate"])
            if (VideoStateCodec.text(metadata["id"]).isBlank()) { ignored++; return@forEach }
            val video = candidate(metadata, at)
            when (type) {
                "block" -> {
                    if (video.channelId.isBlank()) { ignored++; return@forEach }
                    require(video.channelId in brain.blockedChannels || brain.blockedChannels.size < 1000) { "Creator block limit reached." }
                    brain = brain.copy(blockedChannels = brain.blockedChannels + video.channelId)
                }
                "unblock" -> brain = brain.copy(blockedChannels = brain.blockedChannels - video.channelId, suppressedChannels = brain.suppressedChannels - video.channelId)
                "notInterested" -> brain = VideoLearning.notInterested(brain, video, tokenizer, at)
                "impression" -> {
                    // Flow FeedImpressionLedger's thirty-minute recount window.
                    val previous = brain.feedHistory[video.id]
                    if (previous != null && at - previous.lastShown < 30 * 60_000L) { ignored++; return@forEach }
                    val history = (brain.feedHistory + (video.id to FeedEntry(at, (previous?.showCount ?: 0) + 1)))
                        .filterValues { at - it.lastShown < NeuroScoring.FEED_HISTORY_EXPIRY_DAYS * 86_400_000L }
                        .entries.sortedByDescending { it.value.lastShown }.take(NeuroScoring.FEED_HISTORY_MAX).associate { it.key to it.value }
                    brain = brain.copy(feedHistory = history)
                    impressions[video.id] = ImpressionEntry((impressions[video.id]?.count ?: 0) + 1, at)
                    if (impressions.size > 500) impressions.remove(impressions.minBy { it.value.lastSeen }.key)
                }
                else -> {
                    val played = VideoStateCodec.number(event["playedMs"])
                    val duration = VideoStateCodec.number(event["durationMs"])
                    val interaction = when (type) {
                        "listen" -> watchSignalFor(played, duration, event["skipped"] == true)
                        "like", "favorite" -> InteractionType.LIKED
                        "dislike" -> InteractionType.DISLIKED
                        "skip" -> InteractionType.SKIPPED
                        "save" -> InteractionType.SAVED
                        "click" -> InteractionType.CLICK
                        else -> null
                    }
                    if (interaction == null) { ignored++; return@forEach }
                    val fraction = if (duration > 0) (played / duration).coerceIn(0.0, 1.0).toFloat() else 0f
                    if (VideoStateCodec.isChannelId(video.channelId)) {
                        val categoryId = NeuroCategories.idOf(video.category)
                        if (categoryId != null && type == "listen") {
                            channelCategories = NeuroCategoryIndex.record(channelCategories, video.channelId, categoryId, at)
                        }
                        // The pinned engine records a related list only after a strong signal.
                        val strong = interaction == InteractionType.LIKED || interaction == InteractionType.SAVED ||
                            (interaction == InteractionType.WATCHED && fraction >= 0.40f)
                        if (strong && !video.isShort && VideoStateCodec.isVideoId(video.id)) {
                            val related = VideoStateCodec.strings(event["relatedChannels"], NeuroCoWatchStore.CHANNELS_PER_SOURCE)
                                .filter(VideoStateCodec::isChannelId)
                            coWatchSources = NeuroCoWatchStore.record(coWatchSources, video.id, video.channelId, related, at)
                        }
                    }
                    val vector = tokenizer.extractFeatures(video, IdfSnapshot(brain.idfWordFrequency, brain.idfTotalDocuments))
                    brain = VideoLearning.learn(brain, video, interaction, fraction, tokenizer, at, impressions[video.id]?.lastSeen)
                    videoCount++
                    vector.topics.maxByOrNull { it.value }?.let {
                        sessionTopics.add(it.key)
                        while (sessionTopics.size > 50) sessionTopics.removeAt(0)
                        momentum.add(MomentumEntry(it.key, interaction != InteractionType.DISLIKED && interaction != InteractionType.SKIPPED))
                        while (momentum.size > NeuroScoring.MOMENTUM_WINDOW) momentum.removeAt(0)
                    }
                    if (interaction != InteractionType.DISLIKED && interaction != InteractionType.SKIPPED) impressions.remove(video.id)
                }
            }
            applied++
        }

        val learned = brain
        val matchers = NeuroScoring.buildBlockedMatchers(brain.blockedTopics, NeuroTopicCatalog.TOPIC_CATEGORIES, tokenizer::keyOf)
        fun visibleChannel(id: String): Boolean = id !in learned.blockedChannels &&
            (learned.suppressedChannels[id]?.let { nowMs - it >= 14 * 86_400_000L } ?: true)
        val followed = subscriptionChannels.filter {
            visibleChannel(it.id) && !NeuroScoring.isBlockedByText("", it.name, matchers, tokenizer::keyOf)
        }
        brain = VideoSubscriptionPrior.apply(learned, followed.map { it.name }, tokenizer)
        val videos = candidates.distinctBy { it["id"] }.map { candidate(it, nowMs) }
        val subscriptions = candidates.filter { it["isSubscribed"] == true }.map { VideoStateCodec.text(it["authorId"]) }
            .filter { it.isNotBlank() }.toSet() + followed.map { it.id }
        val idf = IdfSnapshot(brain.idfWordFrequency, brain.idfTotalDocuments)
        val filtered = videos.filter { video ->
            video.id !in brain.suppressedVideoIds && visibleChannel(video.channelId) &&
                !NeuroScoring.isBlockedByText(video.title, video.channelName, matchers, tokenizer::keyOf)
        }
        val gated = NeuroScoring.applySeenGate(filtered, brain.feedHistory, nowMs) { it.id }
        val blockedTopicKeys = brain.blockedTopics.map(tokenizer::keyOf).toSet()
        val vectors = gated.map { it to tokenizer.extractFeatures(it, idf, brain.channelTopicProfiles[it.channelId]) }.filter { (_,vector) ->
            vector.topics.entries.sortedByDescending { it.value }.take(3).none { topic ->
                val base = NeuroScoring.stripDomainTag(topic.key)
                blockedTopicKeys.any { it == base || it in base.split(' ') }
            }
        }
        val bucket = TimeBucket.current(nowMs)
        val contextWeight = 0.8 * 0.5 * NeuroScoring.timeBucketConfidence(brain, bucket)
        val persona = VideoLearning.getPersona(brain)
        val isWatchedChannel: (String) -> Boolean = { (brain.channelScores[it] ?: 0.0) > 0.5 }
        val channelEdges = NeuroCoWatchStore.edges(coWatchSources.values, isWatchedChannel, nowMs)
        val categoryOf: (String) -> ChannelCategory? = { NeuroCategoryIndex.categoryOf(channelCategories, it) }
        val cold = brain.totalInteractions < NeuroScoring.COLD_START_THRESHOLD
        val onboarding = brain.totalInteractions < NeuroScoring.ONBOARDING_WARMUP_INTERACTIONS
        val params = ScoringParams(
            brain = brain, userSubs = subscriptions, timeContextVector = brain.timeVectors[bucket] ?: ContentVector(),
            wPersonality = 0.8 - contextWeight, wContext = contextWeight, wNovelty = 0.2,
            isColdStart = cold, isOnboarding = onboarding,
            onboardingWarmup = if (onboarding) 1.0 - (brain.totalInteractions / NeuroScoring.ONBOARDING_WARMUP_INTERACTIONS.toDouble()) * 0.5 else 0.5,
            lemmatizedPreferred = brain.preferredTopics.flatMapTo(HashSet(), tokenizer::keysOf),
            sessionTopics = sessionTopics, sessionVideoCount = videoCount, impressions = impressions,
            watchHistory = brain.watchHistoryMap.mapValues { WatchEntry(it.value, nowMs) }, recentInteractions = momentum,
            candidatePoolSize = gated.size, now = nowMs,
            coWatchPrior = NeuroCoWatchStore.neighbours(channelEdges, isWatchedChannel),
            categoryOf = categoryOf,
            exploreWeight = when (persona) { FlowPersona.EXPLORER -> 1.0; FlowPersona.SPECIALIST -> 0.3; FlowPersona.INITIATE -> 0.0; else -> 0.6 },
        )
        val recentShown = brain.feedHistory.filterValues { nowMs - it.lastShown < 48 * 3_600_000L }.keys
        val overlap = if (videos.isEmpty()) 0.0 else videos.count { it.id in recentShown }.toDouble() / videos.size
        val base = vectors.map { (video, vector) -> ScoredVideo(video, NeuroScoring.scoreCandidate(video, vector, params), vector) }
        val median = base.map { it.score }.sorted().let { if (it.isEmpty()) 0.0 else it[it.size / 2] }.coerceAtLeast(0.05)
        val jitterUnit = NeuroScoring.calculateAdaptiveJitter(brain.totalInteractions, overlap) * median
        val random = Random(seed)
        val scored = base.map { it.copy(score = it.score + random.nextDouble() * jitterUnit) }.toMutableList()
        val viewer = NeuroVectorMath.PreparedVector(brain.interests)
        val unrelated: (ScoredVideo) -> Boolean = {
            !cold && it.video.channelId !in subscriptions && (brain.channelScores[it.video.channelId] ?: 0.0) < NeuroScoring.KNOWN_CHANNEL_SCORE &&
                NeuroVectorMath.topicSimilarity(viewer, it.vector, tokenizer::specificity) < NeuroScoring.UNRELATED_SIMILARITY
        }
        val ordered = NeuroScoring.applySmartDiversity(scored, tokenizer, if (brain.consecutiveSkips >= NeuroScoring.BOREDOM_SKIPS) 1 else 0, unrelated)
        val byId = scored.associateBy { it.video.id }
        val ranked = ordered.map { video ->
            val item = byId.getValue(video.id)
            val shared = item.vector.topics.keys.filter { it in brain.interests.topics }.maxByOrNull { brain.interests.topics[it] ?: 0.0 }
            val reason = when {
                video.channelId in subscriptions -> "From a creator you follow"
                shared != null -> "Related to ${brain.displayForms[shared]?.form ?: NeuroScoring.stripDomainTag(shared)}"
                (brain.channelScores[video.channelId] ?: 0.0) > 0.6 -> "From a creator you have enjoyed"
                else -> "Explore from available videos"
            }
            mapOf("id" to video.id, "score" to item.score, "reason" to reason)
        }
        val queries = NeuroDiscovery(NeuroTopicCatalog.TOPIC_CATEGORIES, tokenizer)
            .generateQueries(brain, nowMs, channelEdges = channelEdges, personaProvider = VideoLearning::getPersona)
        val (chipSet, chips) = interestChips(brain, tokenizer, nowMs, categoryOf, channelEdges)
        // A subscription-only topic or chip must vanish when its source is removed.
        val persisted = if (brain === learned && (chipSet.masses.isNotEmpty() || learned.interestChips.masses.isNotEmpty())) {
            learned.copy(interestChips = chipSet)
        } else learned
        val resultState = VideoStateCodec.encode(persisted, coWatchSources, channelCategories) + mapOf(
            "processedEventIds" to processed.toList().takeLast(1000),
            "session" to mapOf("startedAt" to sessionStart, "lastAt" to nowMs, "videoCount" to videoCount, "topics" to sessionTopics,
                "momentum" to momentum.map { mapOf("topic" to it.topic,"positive" to it.positive) },
                "impressions" to impressions.mapValues { mapOf("count" to it.value.count,"lastSeen" to it.value.lastSeen) }),
        )
        VideoStateCodec.validate(resultState)
        return mapOf("state" to resultState, "ranked" to ranked, "summary" to mapOf(
            "totalInteractions" to brain.totalInteractions, "appliedEvents" to applied, "ignoredEvents" to ignored,
            "topTopics" to brain.interests.topics.entries.sortedByDescending { it.value }.take(12).map { mapOf("topic" to it.key, "label" to (brain.displayForms[it.key]?.form ?: it.key), "weight" to it.value) },
            "blockedChannels" to brain.blockedChannels.toList(), "blockedTopics" to brain.blockedTopics.toList(),
            "interestChips" to chips,
            "discoveryQueries" to queries.take(6).map { it.query }, "scoresArePreDiversity" to true,
        ))
    }

    /**
     * Apply Flow's watched and quick-bounce thresholds to explicit departures.
     * Videre grades confirmed elapsed playing time, so a seek cannot qualify
     * a departure. Interrupted or recovered sessions keep their positive time
     * without turning a short watch into a skip.
     */
    private fun watchSignalFor(playedMs: Double, durationMs: Double, skipped: Boolean): InteractionType? {
        if (playedMs <= 0.0 || durationMs <= 0.0) return null
        if (!skipped) return InteractionType.WATCHED
        val fraction = playedMs / durationMs
        if (fraction < WATCHED_FRACTION && playedMs < MIN_SKIP_SIGNAL_PLAYED_MS) return null
        return if (fraction >= WATCHED_FRACTION) InteractionType.WATCHED else InteractionType.SKIPPED
    }

    private fun candidate(row: Map<String, Any?>, now: Long): Video {
        val published = VideoStateCodec.number(row["publishedMs"]).toLong().coerceAtLeast(0)
        val days = if (published > 0) ((now - published).coerceAtLeast(0) / 86_400_000L) else -1L
        val age = when { days < 0 -> ""; days < 1 -> "hours"; days < 7 -> "$days days"; days < 30 -> "${days / 7} weeks"; days < 365 -> "${days / 30} months"; else -> "${days / 365} years" }
        return Video(
            id = VideoStateCodec.text(row["id"]), title = VideoStateCodec.text(row["title"], 2000),
            channelName = VideoStateCodec.text(row["author"]), channelId = VideoStateCodec.text(row["authorId"]),
            duration = VideoStateCodec.number(row["durationSeconds"]).toInt().coerceAtLeast(0),
            viewCount = VideoStateCodec.number(row["viewCount"]).toLong().coerceAtLeast(0),
            likeCount = VideoStateCodec.number(row["likeCount"]).toLong().coerceAtLeast(0),
            uploadDate = age, timestamp = published, timestampIsExact = published > 0,
            description = VideoStateCodec.text(row["description"], 16_384),
            tags = VideoStateCodec.strings(row["keywords"], 50).toList(), category = (row["category"] as? String)?.take(100),
            isLive = row["isLive"] == true, isMusic = row["isMusic"] == true,
            isShort = row["isShort"] == true, isUpcoming = row["isUpcoming"] == true,
        )
    }
}
