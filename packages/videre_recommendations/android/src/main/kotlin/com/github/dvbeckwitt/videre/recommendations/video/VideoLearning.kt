/*
 * Copyright (C) 2025-2026 Flow | A-EDev
 *
 * This file is part of Flow (https://github.com/Flow-Tube/Flow).
 *
 * Flow is free software: you can redistribute it and/or modify
 * it under the terms of the GNU General Public License as published by
 * the Free Software Foundation, version 3 of the License.
 *
 * This recommendation algorithm (FlowNeuroEngine) is the intellectual property
 * of the Flow project. Any use of this code in other projects must
 * explicitly credit "Flow Android Client" and link back to the original repository.
 */

package com.github.dvbeckwitt.videre.recommendations.video

import java.util.Calendar
import kotlin.math.ln

/**
 * Extracted from FlowNeuroEngine at 565d1f7a3da4ca8e54463b029f151ef87415858a.
 * Keeps Flow's event learning rates, vector horizons, acquisition, IDF, channel,
 * category/format, language and evidence updates. Videre supplies clock/events
 * and persists the returned profile; no Android service, storage or network is used.
 *
 * Adaptations: optional impression timestamp replaces Flow's session cache;
 * caller-owned related metadata, content-vector cache and session momentum are
 * not stored here. Counted document IDs are explicit state so batching and retry
 * never turn an already-counted video into another IDF document.
 * Missing Invidious creator identities do not create a shared empty-ID creator.
 */
internal object VideoLearning {
    private const val TOPIC_EVIDENCE_MAX_ENTRIES = 500
    private const val MAX_SUPPRESSED_CHANNELS = 100
    private const val CHANNEL_SUPPRESSION_DAYS = 14L

    fun learn(
        brain: UserBrain,
        video: Video,
        interactionType: InteractionType,
        percentWatched: Float,
        tokenizer: NeuroTokenizer,
        now: Long,
        impressionLastSeenMs: Long? = null,
    ): UserBrain {
        require(percentWatched.isFinite() && percentWatched in 0f..1f)

        // The Dart caller owns learning enablement, event identity and profile serialization.
        var currentUserBrain = brain
        val idfSnapshot = IdfSnapshot(brain.idfWordFrequency, brain.idfTotalDocuments)
        val videoVector = tokenizer.extractFeatures(video, idfSnapshot)
        val idfWordFrequency = brain.idfWordFrequency.toMutableMap()
        var idfTotalDocuments = brain.idfTotalDocuments
        val countedDocuments = brain.countedDocumentIds.toMutableSet()
        val watchHistory = LinkedHashMap(brain.watchHistoryMap.mapValues { WatchEntry(it.value, now) })
        fun isDocumentCounted(id: String) = id in watchHistory || id in countedDocuments
        fun countDocument(id: String, terms: () -> Collection<String>): Boolean {
            if (id.isNotBlank()) {
                if (isDocumentCounted(id)) return false
                countedDocuments.add(id)
                while (countedDocuments.size > 500) countedDocuments.remove(countedDocuments.first())
            }
            terms().forEach { term -> idfWordFrequency[term] = (idfWordFrequency[term] ?: 0) + 1 }
            idfTotalDocuments++
            return true
        }
        fun compactIdfIfNeeded() {
            if (idfTotalDocuments > 10000) {
                idfWordFrequency.replaceAll { _, v -> v / 2 }
                idfWordFrequency.entries.removeAll { it.value <= 0 }
                idfTotalDocuments /= 2
            }
            NeuroScoring.capIdfVocabulary(idfWordFrequency)
        }

        val absoluteMinutesWatched =
            if (
                interactionType == InteractionType.WATCHED && video.duration > 0
            ) {
                (video.duration * percentWatched / 60.0).coerceAtLeast(0.0)
            } else {
                0.0
            }

        var learningRate =
            when (interactionType) {
                InteractionType.CLICK -> {
                    0.03
                }

                InteractionType.LIKED -> {
                    0.30
                }

                InteractionType.SAVED -> {
                    0.22
                }

                InteractionType.WATCHED -> {
                    val baseWatchRate = 0.15 * percentWatched
                    val timeBonus = (
                        ln(1.0 + absoluteMinutesWatched) /
                            ln(1.0 + 60.0) * 0.08
                    )
                    baseWatchRate + timeBonus
                }

                InteractionType.SKIPPED -> {
                    -0.15
                }

                InteractionType.DISLIKED -> {
                    -0.40
                }
            }

        if (video.isShort) {
            learningRate *= NeuroScoring.SHORTS_LEARNING_PENALTY
        }
        var strength = learningRate / NeuroVectorMath.DECAY_REFERENCE_RATE

        run {
            // Maturity damping slows duration, pacing and complexity; topic evidence needs no brake (see NeuroVectorMath.Horizon).
            if (learningRate > 0) {
                val maturityDamping =
                    1.0 / (
                        1.0 +
                            ln(1.0 + currentUserBrain.totalInteractions / 50.0)
                    )
                learningRate *= maturityDamping.coerceIn(0.25, 1.0)
            }

            // 0. Watch velocity: adjust click learning rate based on impression timing
            if (interactionType == InteractionType.CLICK) {
                if (impressionLastSeenMs != null) {
                    val secondsSinceImpression =
                        (now - impressionLastSeenMs) / 1000.0
                    val clickVelocity =
                        when {
                            secondsSinceImpression < 5.0 -> 1.5

                            // instant click
                            secondsSinceImpression < 30.0 -> 1.0

                            // normal
                            secondsSinceImpression < 120.0 -> 0.8

                            // delayed
                            else -> 0.6 // much later
                        }
                    learningRate *= clickVelocity
                    strength *= clickVelocity
                }
            }

            // 1. Update the long-term and recent taste
            val learningVector = if (learningRate > 0) NeuroVectorMath.phraseFirst(videoVector) else videoVector
            val pickKeys = currentUserBrain.preferredTopics.flatMapTo(HashSet(), tokenizer::keysOf)

            fun learnOn(
                vector: ContentVector,
                horizon: NeuroVectorMath.Horizon,
            ) = if (learningRate > 0) {
                NeuroVectorMath.learn(vector, learningVector, strength, horizon, learningRate, pickKeys)
            } else {
                NeuroVectorMath.adjustVector(vector, videoVector, learningRate, pruneBelow = NeuroVectorMath.EVIDENCE_PRUNE_THRESHOLD)
            }
            var newGlobal = learnOn(currentUserBrain.globalVector, NeuroVectorMath.LONG_TERM)
            val newRecent = learnOn(currentUserBrain.recentVector, NeuroVectorMath.RECENT)

            // 1a. A real watch, like or save counts at least the acquisition floor for its top
            // topics (see NeuroVectorMath.plantTopics).
            val isStrongSignal =
                interactionType == InteractionType.LIKED ||
                    interactionType == InteractionType.SAVED ||
                    (interactionType == InteractionType.WATCHED && percentWatched >= 0.40f)
            if (isStrongSignal && !video.isShort) {
                newGlobal =
                    NeuroVectorMath.plantTopics(
                        newGlobal,
                        videoVector,
                        NeuroScoring.TOPIC_ACQUISITION_FLOOR,
                        NeuroScoring.TOPIC_ACQUISITION_TOP_K,
                        tokenizer.plantFilter(video, idfSnapshot, ownDocuments = if (isDocumentCounted(video.id)) 1 else 0),
                    )
            }
            newGlobal = NeuroVectorMath.capTopics(newGlobal, NeuroVectorMath.MAX_GLOBAL_TOPICS, pickKeys)

            // A watch session ends in one WATCHED or SKIPPED; either way the channel posted in that category.
            val categoryId = NeuroCategories.idOf(video.category)
            // Channel-category observations and remote related-list edges belong to
            // the caller's metadata provider. Learning category affinity below is unchanged.

            // 1b. Shorts-specific vector (not dampened by SHORTS_LEARNING_PENALTY)
            val newShortsVector =
                if (video.isShort) {
                    val shortsRate =
                        when (interactionType) {
                            InteractionType.CLICK -> 0.08
                            InteractionType.LIKED -> 0.20
                            InteractionType.SAVED -> 0.15
                            InteractionType.WATCHED -> 0.10 * percentWatched
                            InteractionType.SKIPPED -> -0.12
                            InteractionType.DISLIKED -> -0.30
                        }
                    NeuroVectorMath.adjustVector(
                        currentUserBrain.shortsVector,
                        videoVector,
                        shortsRate,
                    )
                } else {
                    currentUserBrain.shortsVector
                }

            // 2. Update time bucket
            val bucket = timeBucketAt(now)
            val currentBucketVec =
                currentUserBrain.timeVectors[bucket]
                    ?: ContentVector()
            val newBucketVec = learnOn(currentBucketVec, NeuroVectorMath.TIME_OF_DAY)
            val newBucketCounts =
                if (learningRate > 0 && !video.isShort) {
                    currentUserBrain.timeBucketCounts + (bucket to (currentUserBrain.timeBucketCounts[bucket] ?: 0) + 1)
                } else {
                    currentUserBrain.timeBucketCounts
                }

            // 3. Channel score
            val currentChScore =
                currentUserBrain.channelScores[video.channelId] ?: 0.5
            val outcome = if (learningRate > 0) 1.0 else 0.0
            val newChScore =
                if (interactionType == InteractionType.DISLIKED) {
                    (currentChScore * NeuroScoring.DISLIKE_CHANNEL_FACTOR).coerceAtLeast(0.01)
                } else {
                    (currentChScore * NeuroScoring.CHANNEL_EMA_DECAY) +
                        (outcome * NeuroScoring.CHANNEL_EMA_ALPHA)
                }
            var newChannelScores =
                if (video.channelId.isBlank()) {
                    currentUserBrain.channelScores
                } else {
                    currentUserBrain.channelScores + (video.channelId to newChScore)
                }

            // Channel pruning
            if (newChannelScores.size > NeuroScoring.MAX_CHANNEL_SCORES) {
                val sorted = newChannelScores.entries.sortedBy { it.value }
                val keepLow = sorted.take(NeuroScoring.CHANNEL_KEEP_LOW)
                val keepHigh = sorted.takeLast(NeuroScoring.CHANNEL_KEEP_HIGH)
                val keepSet = (keepLow + keepHigh).map { it.key }.toSet()
                newChannelScores =
                    newChannelScores
                        .filter { it.key in keepSet }
            }

            // 4. Consecutive skips. Boredom is passive skipping; an explicit rejection says what the
            // viewer does not want, which is no reason to make the next feed more random (#907).
            val newSkips =
                when (interactionType) {
                    InteractionType.CLICK, InteractionType.LIKED,
                    InteractionType.WATCHED, InteractionType.SAVED,
                    -> {
                        0
                    }

                    // A swiped-away Short is how Shorts are browsed, not a sign of boredom with the feed (#907).
                    InteractionType.SKIPPED -> {
                        if (video.isShort) {
                            currentUserBrain.consecutiveSkips
                        } else {
                            (currentUserBrain.consecutiveSkips + 1).coerceAtMost(NeuroScoring.MAX_CONSECUTIVE_SKIPS)
                        }
                    }

                    InteractionType.DISLIKED -> {
                        currentUserBrain.consecutiveSkips
                    }
                }
            val newRejectionPatterns =
                if (interactionType == InteractionType.DISLIKED) {
                    NeuroScoring.recordRejection(currentUserBrain.rejectionPatterns, videoVector, now)
                } else {
                    currentUserBrain.rejectionPatterns
                }

            // 5. Topic co-occurrence
            var newAffinities = currentUserBrain.topicAffinities
            if (learningRate > 0) {
                val topTopics =
                    videoVector.topics.entries
                        .sortedByDescending { it.value }
                        .take(3)
                        .map { NeuroScoring.stripDomainTag(it.key) }
                        .distinct()
                if (topTopics.size >= 2) {
                    val mutableAffinities = newAffinities.toMutableMap()
                    for (i in topTopics.indices) {
                        for (j in i + 1 until topTopics.size) {
                            val key =
                                NeuroScoring.makeAffinityKey(
                                    topTopics[i],
                                    topTopics[j],
                                )
                            val current = mutableAffinities[key] ?: 0.0
                            mutableAffinities[key] =
                                (current + NeuroScoring.AFFINITY_INCREMENT)
                                    .coerceAtMost(NeuroScoring.AFFINITY_MAX)
                        }
                    }
                    // No per-update value pruning: the old filter (> 0.05) deleted every
                    // newborn edge in the same update that created it (+0.01), so no pair
                    // could EVER accumulate organically. The size cap alone bounds growth —
                    // it evicts the weakest pairs first, which is the pruning we wanted.
                    newAffinities = mutableAffinities
                    if (newAffinities.size > NeuroScoring.AFFINITY_MAX_ENTRIES) {
                        newAffinities =
                            newAffinities.entries
                                .sortedByDescending { it.value }
                                .take(NeuroScoring.AFFINITY_KEEP_TOP)
                                .associate { it.key to it.value }
                    }
                }
            }

            // 5b. Tag-grounded knowledge: persist the tag-rich vector so this video
            // is scored on real content when it reappears as a bare-title candidate,
            // and record tag co-occurrence edges for interest clustering.
            var newTagAffinities = currentUserBrain.tagAffinities
            if (learningRate > 0 && video.tags.isNotEmpty()) {
                // Dart retains candidate metadata; this stateless learner opens no content store.

                val tagTokens =
                    video.tags
                        .asSequence()
                        .flatMap { tokenizer.tokenize(it) }
                        .distinct()
                        .take(NeuroScoring.TAG_AFFINITY_TOKENS)
                        .toList()
                if (tagTokens.size >= 2) {
                    val mutableTags = newTagAffinities.toMutableMap()
                    for (i in tagTokens.indices) {
                        for (j in i + 1 until tagTokens.size) {
                            val key = NeuroScoring.makeAffinityKey(tagTokens[i], tagTokens[j])
                            mutableTags[key] =
                                ((mutableTags[key] ?: 0.0) + NeuroScoring.TAG_AFFINITY_INCREMENT)
                                    .coerceAtMost(NeuroScoring.AFFINITY_MAX)
                        }
                    }
                    newTagAffinities =
                        if (mutableTags.size > NeuroScoring.TAG_AFFINITY_MAX_ENTRIES) {
                            mutableTags.entries
                                .sortedByDescending { it.value }
                                .take(NeuroScoring.TAG_AFFINITY_KEEP_TOP)
                                .associate { it.key to it.value }
                        } else {
                            mutableTags
                        }
                }
            }

            val topicEvidenceSignal =
                calculateTopicEvidenceSignal(
                    interactionType,
                    percentWatched,
                    video.isShort,
                )
            val positiveEvidence =
                updateTopicEvidence(
                    currentUserBrain.topicEvidence,
                    videoVector,
                    video,
                    signalScore = topicEvidenceSignal,
                    isWatchSignal =
                        interactionType == InteractionType.WATCHED &&
                            percentWatched >= 0.40f,
                    isExplicitSignal =
                        interactionType == InteractionType.LIKED ||
                            interactionType == InteractionType.SAVED,
                    now = now,
                )
            val newTopicEvidence =
                if (
                    interactionType == InteractionType.SKIPPED ||
                    interactionType == InteractionType.DISLIKED
                ) {
                    bumpNegativeEvidence(positiveEvidence, videoVector, now)
                } else {
                    positiveEvidence
                }

            // 6. Update IDF counters on interaction
            if (learningRate > 0 && countDocument(video.id) { tokenizer.documentTerms(video, videoVector) }) {
                compactIdfIfNeeded()

            }

            // 7. Persona tracking
            val rawPersona = getPersona(currentUserBrain)
            val lastPersonaName = currentUserBrain.lastPersona
            val newStability =
                if (rawPersona.name == lastPersonaName) {
                    (currentUserBrain.personaStability + 1)
                        .coerceAtMost(NeuroScoring.PERSONA_MAX_STABILITY)
                } else {
                    1
                }

            // Session topics/momentum and transient impression eviction remain
            // caller-owned; they do not change the learned profile equations.

            // 9. Channel topic profile update
            var newChannelProfiles = currentUserBrain.channelTopicProfiles
            if (learningRate > 0 && video.channelId.isNotBlank()) {
                val channelId = video.channelId
                val existingProfile =
                    newChannelProfiles[channelId]?.toMutableMap()
                        ?: mutableMapOf()

                videoVector.topics.forEach { (topic, weight) ->
                    val current = existingProfile[topic] ?: 0.0
                    existingProfile[topic] = current +
                        (weight - current) * NeuroScoring.CHANNEL_PROFILE_LEARNING_RATE
                }

                val profileIterator = existingProfile.iterator()
                while (profileIterator.hasNext()) {
                    val entry = profileIterator.next()
                    if (!videoVector.topics.containsKey(entry.key)) {
                        entry.setValue(entry.value * 0.98)
                    }
                    if (entry.value < NeuroScoring.CHANNEL_PROFILE_PRUNE_THRESHOLD) {
                        profileIterator.remove()
                    }
                }

                val pruned =
                    if (existingProfile.size > NeuroScoring.CHANNEL_PROFILE_MAX_TOPICS) {
                        existingProfile.entries
                            .sortedByDescending { it.value }
                            .take(NeuroScoring.CHANNEL_PROFILE_MAX_TOPICS)
                            .associate { it.key to it.value }
                    } else {
                        existingProfile.toMap()
                    }

                val mutableProfiles = newChannelProfiles.toMutableMap()
                mutableProfiles[channelId] = pruned

                if (mutableProfiles.size > NeuroScoring.CHANNEL_PROFILE_MAX_CHANNELS) {
                    val channelScoreMap = currentUserBrain.channelScores
                    val sorted =
                        mutableProfiles.entries.sortedBy { (id, _) ->
                            channelScoreMap[id] ?: 0.0
                        }
                    val toRemove =
                        sorted.take(
                            mutableProfiles.size - NeuroScoring.CHANNEL_PROFILE_MAX_CHANNELS,
                        )
                    toRemove.forEach { mutableProfiles.remove(it.key) }
                }

                newChannelProfiles = mutableProfiles
            }

            if (interactionType == InteractionType.WATCHED &&
                percentWatched > NeuroScoring.WATCHED_THRESHOLD_SAMPLED
            ) {
                val existing = watchHistory[video.id]
                if (existing == null ||
                    percentWatched > existing.percentWatched
                ) {
                    watchHistory[video.id] =
                        WatchEntry(
                            percentWatched,
                            now,
                        )
                    while (watchHistory.size > NeuroScoring.WATCH_HISTORY_MAX) {
                        val oldestKey = watchHistory.keys.first()
                        watchHistory.remove(oldestKey)
                    }
                }
            }

            val watchHistoryMap =
                watchHistory.mapValues { (_, entry) ->
                    entry.percentWatched
                }

            val profile = currentUserBrain.languageProfile ?: tokenizer.languageProfile
            val language =
                if (learningRate > 0 && interactionType == InteractionType.WATCHED) {
                    val firstLine =
                        video.description
                            .lineSequence()
                            .firstOrNull { it.isNotBlank() }
                            .orEmpty()
                    NeuroLanguages.vote(profile, currentUserBrain.languageVotes, NeuroLanguages.detectText("${video.title}\n$firstLine"))
                } else {
                    profile to currentUserBrain.languageVotes
                }
            if (language.first != profile) {
                tokenizer.languageProfile = language.first
            }

            currentUserBrain =
                currentUserBrain.copy(
                    globalVector = newGlobal,
                    recentVector = newRecent,
                    timeVectors =
                        currentUserBrain.timeVectors +
                            (bucket to newBucketVec),
                    timeBucketCounts = newBucketCounts,
                    channelScores = newChannelScores,
                    topicAffinities = newAffinities,
                    totalInteractions = currentUserBrain.totalInteractions + 1,
                    consecutiveSkips = newSkips,
                    lastPersona = rawPersona.name,
                    personaStability = newStability,
                    idfWordFrequency = idfWordFrequency.toMap(),
                    idfTotalDocuments = idfTotalDocuments,
                    watchHistoryMap = watchHistoryMap,
                    categoryAffinity =
                        if (categoryId != null && isStrongSignal && !video.isShort) {
                            NeuroCategories.learn(currentUserBrain.categoryAffinity, categoryId)
                        } else {
                            currentUserBrain.categoryAffinity
                        },
                    formatAffinity =
                        if (learningRate > 0 && !video.isShort) {
                            NeuroFormats.learn(currentUserBrain.formatAffinity, videoVector.formats)
                        } else {
                            currentUserBrain.formatAffinity
                        },
                    languageProfile = language.first,
                    languageVotes = language.second,
                    displayForms =
                        if (learningRate > 0) {
                            val keys = learningVector.topics.keys
                            val fromTitle =
                                NeuroDisplayForms.record(
                                    currentUserBrain.displayForms,
                                    NeuroDisplayForms.spellingsIn(video.title, keys, tokenizer),
                                ) { it in newGlobal.topics }
                            // Keys stemmed from tags or the channel name still read as written somewhere.
                            val elsewhere = (video.tags + video.channelName).joinToString(" | ")
                            NeuroDisplayForms.fillGaps(fromTitle, NeuroDisplayForms.spellingsIn(elsewhere, keys, tokenizer)) {
                                it in
                                    newGlobal.topics
                            }
                        } else {
                            currentUserBrain.displayForms
                        },
                    channelTopicProfiles = newChannelProfiles,
                    shortsVector = newShortsVector,
                    topicEvidence = newTopicEvidence,
                    tagAffinities = newTagAffinities,
                    rejectionPatterns = newRejectionPatterns,
                    channelMemory =
                        if (interactionType == InteractionType.DISLIKED && video.channelId.isNotBlank()) {
                            ChannelMemory.recordRejection(
                                currentUserBrain.channelMemory,
                                video.channelId,
                                video.channelName,
                                now,
                            )
                        } else {
                            currentUserBrain.channelMemory
                        },
                )

        }
        return currentUserBrain.copy(countedDocumentIds = countedDocuments)
    }

    /** Flow's explicit rejection path, distinct from a playback skip or dislike. */
    fun notInterested(
        brain: UserBrain,
        video: Video,
        tokenizer: NeuroTokenizer,
        now: Long,
    ): UserBrain {
        var currentUserBrain = brain
        val videoVector = tokenizer.extractFeatures(video, IdfSnapshot(brain.idfWordFrequency, brain.idfTotalDocuments))

        run {

            // 1. Hard-suppress this specific video
            val newSuppressedVideos = suppressVideo(currentUserBrain.suppressedVideoIds, video.id, now)

            // 2. Channel suppression — rolling, self-healing window. Inferred dislikes
            // never become a permanent block; only explicit blockChannel() does that,
            // so two mis-taps can no longer kill a channel forever.
            val newSuppressedChannels = currentUserBrain.suppressedChannels.toMutableMap()
            if (video.channelId.isNotBlank()) {
                newSuppressedChannels[video.channelId] = now
                if (newSuppressedChannels.size > MAX_SUPPRESSED_CHANNELS) {
                    val cutoff = now - (CHANNEL_SUPPRESSION_DAYS * 86_400_000L)
                    newSuppressedChannels.entries.removeAll { it.value < cutoff }
                    // The stateless bridge persists a bounded snapshot. Flow only
                    // prunes by age here; keep the newest marks if all are recent.
                    if (newSuppressedChannels.size > MAX_SUPPRESSED_CHANNELS) {
                        val newest = newSuppressedChannels.entries
                            .sortedByDescending { it.value }
                            .take(MAX_SUPPRESSED_CHANNELS)
                            .map { it.key }
                            .toSet()
                        newSuppressedChannels.keys.retainAll(newest)
                    }
                }
            }

            // 3. Update rejection pattern memory BEFORE vector adjustment
            val updatedPatterns = NeuroScoring.recordRejection(currentUserBrain.rejectionPatterns, videoVector, now)

            // 4. Aggressive vector adjustment — scales with rejection count
            val aggressionFactor =
                NeuroScoring.getRejectionAggressionFactor(
                    videoVector,
                    updatedPatterns,
                    now,
                )
            val newGlobal = adjustVectorByRejection(currentUserBrain.globalVector, videoVector, aggressionFactor)
            val newRecent = adjustVectorByRejection(currentUserBrain.recentVector, videoVector, aggressionFactor)

            // 5. Channel score — scales with rejection aggression
            val newChannelScores = currentUserBrain.channelScores.toMutableMap()
            if (video.channelId.isNotBlank()) {
                val currentScore = newChannelScores[video.channelId] ?: 0.5
                newChannelScores[video.channelId] =
                    (currentScore * aggressionFactor).coerceAtLeast(0.01)
            }

            // 6. Time bucket adjustment
            val bucket = timeBucketAt(now)
            val currentBucketVec = currentUserBrain.timeVectors[bucket] ?: ContentVector()
            val newBucketVec =
                NeuroVectorMath.adjustVector(
                    currentBucketVec,
                    videoVector,
                    NeuroScoring.NOT_INTERESTED_TIME_RATE,
                    pruneBelow = NeuroVectorMath.EVIDENCE_PRUNE_THRESHOLD,
                )

            currentUserBrain =
                currentUserBrain.copy(
                    globalVector = newGlobal,
                    recentVector = newRecent,
                    timeVectors = currentUserBrain.timeVectors + (bucket to newBucketVec),
                    channelScores = newChannelScores,
                    totalInteractions = currentUserBrain.totalInteractions + 1,
                    suppressedVideoIds = newSuppressedVideos,
                    suppressedChannels = newSuppressedChannels,
                    channelMemory = if (video.channelId.isNotBlank()) {
                        ChannelMemory.recordRejection(currentUserBrain.channelMemory, video.channelId, video.channelName, now)
                    } else {
                        currentUserBrain.channelMemory
                    },
                    rejectionPatterns = updatedPatterns,
                    topicEvidence = bumpNegativeEvidence(currentUserBrain.topicEvidence, videoVector, now),
                )
        }
        return currentUserBrain
    }

    private fun adjustVectorByRejection(
        current: ContentVector,
        target: ContentVector,
        aggressionFactor: Double,
    ): ContentVector {
        val newTopics = current.topics.toMutableMap()
        target.topics.forEach { (key, _) ->
            val currentVal = newTopics[key] ?: 0.0
            if (currentVal > 0) {
                newTopics[key] =
                    (currentVal * aggressionFactor)
                        .coerceAtMost(0.3)
            }
        }
        newTopics.entries.removeAll { (key, weight) -> key in target.topics && weight < NeuroVectorMath.TOPIC_PRUNE_THRESHOLD }
        return current.copy(topics = newTopics)
    }

    // Flow's FeedExclusions.suppressVideo, with the upstream 5,000-entry cap.
    private fun suppressVideo(suppressed: Map<String, Long>, videoId: String, now: Long): Map<String, Long> {
        val updated = suppressed + (videoId to now)
        if (updated.size <= 5000) return updated
        return updated.entries.sortedByDescending { it.value }.take(5000).associate { it.key to it.value }
    }

    private fun calculateTopicEvidenceSignal(
        interactionType: InteractionType,
        percentWatched: Float,
        isShort: Boolean,
    ): Double {
        val base =
            when (interactionType) {
                InteractionType.CLICK -> {
                    0.20
                }

                InteractionType.LIKED -> {
                    2.0
                }

                InteractionType.SAVED -> {
                    1.2
                }

                InteractionType.WATCHED -> {
                    when {
                        percentWatched >= NeuroScoring.WATCHED_THRESHOLD_FULL -> 1.5
                        percentWatched >= 0.40f -> 1.0
                        percentWatched >= NeuroScoring.WATCHED_THRESHOLD_SAMPLED -> 0.35
                        else -> 0.0
                    }
                }

                InteractionType.SKIPPED,
                InteractionType.DISLIKED,
                -> {
                    0.0
                }
            }
        return if (isShort) base * 0.35 else base
    }

    private fun updateTopicEvidence(
        current: Map<String, TopicEvidence>,
        videoVector: ContentVector,
        video: Video,
        signalScore: Double,
        isWatchSignal: Boolean,
        isExplicitSignal: Boolean,
        now: Long,
    ): Map<String, TopicEvidence> {
        if (signalScore <= 0.0) return current

        val topics =
            videoVector.topics.entries
                .sortedByDescending { it.value }
                .take(5)
                .map { NeuroScoring.stripDomainTag(it.key) }
                .filter(NeuroText::isTopicSized)
                .distinct()

        if (topics.isEmpty()) return current

        val updated = current.toMutableMap()
        topics.forEach { topic ->
            val existing = updated[topic]
            val nextVideoIds = cappedSet(existing?.videoIds.orEmpty(), video.id)
            val nextChannelIds = cappedSet(existing?.channelIds.orEmpty(), video.channelId)
            updated[topic] =
                TopicEvidence(
                    positiveSignals = (existing?.positiveSignals ?: 0) + 1,
                    watchSignals = (existing?.watchSignals ?: 0) + if (isWatchSignal) 1 else 0,
                    explicitSignals = (existing?.explicitSignals ?: 0) + if (isExplicitSignal) 1 else 0,
                    positiveScore = ((existing?.positiveScore ?: 0.0) + signalScore).coerceAtMost(TopicEvidence.MAX_SCORE),
                    videoIds = nextVideoIds,
                    channelIds = nextChannelIds,
                    firstSeenAt = existing?.firstSeenAt?.takeIf { it > 0L } ?: now,
                    lastSeenAt = now,
                )
        }

        return capEvidence(updated)
    }

    // Cap evidence entries, keeping the strongest signal of either valence.
    private fun capEvidence(map: MutableMap<String, TopicEvidence>): Map<String, TopicEvidence> =
        if (map.size <= TOPIC_EVIDENCE_MAX_ENTRIES) {
            map
        } else {
            map.entries
                .sortedWith(
                    compareByDescending<Map.Entry<String, TopicEvidence>> {
                        it.value.positiveScore + it.value.negativeSignals
                    }.thenByDescending { it.value.lastSeenAt },
                ).take(TOPIC_EVIDENCE_MAX_ENTRIES)
                .associate { it.key to it.value }
        }

    // Records a negative signal against a video's primary topics (skip/dislike/not-interested).
    private fun bumpNegativeEvidence(
        current: Map<String, TopicEvidence>,
        videoVector: ContentVector,
        now: Long,
    ): Map<String, TopicEvidence> {
        val topics =
            videoVector.topics.entries
                .sortedByDescending { it.value }
                .take(5)
                .map { NeuroScoring.stripDomainTag(it.key) }
                .filter(NeuroText::isTopicSized)
                .distinct()
        if (topics.isEmpty()) return current

        val updated = current.toMutableMap()
        topics.forEach { topic ->
            val existing = updated[topic]
            updated[topic] =
                (existing ?: TopicEvidence(firstSeenAt = now)).copy(
                    negativeSignals = (existing?.negativeSignals ?: 0) + 1,
                    lastSeenAt = now,
                )
        }
        return capEvidence(updated)
    }

    private fun cappedSet(
        existing: Set<String>,
        value: String,
    ): Set<String> {
        if (value.isBlank()) return existing
        if (value in existing) return existing
        return (existing.toList() + value).takeLast(TopicEvidence.MAX_IDS).toSet()
    }

    fun getPersona(brain: UserBrain): FlowPersona {
        if (brain.totalInteractions < 15) return FlowPersona.INITIATE

        val v = brain.globalVector

        val sortedTopics = v.topics.values.sortedDescending()
        val topScore = sortedTopics.firstOrNull() ?: 0.0
        val diversityIndex =
            if (sortedTopics.size >= 5 && topScore > 0) {
                sortedTopics[4] / topScore
            } else {
                0.0
            }

        val musicKeywords =
            setOf(
                "music",
                "song",
                "lyrics",
                "remix",
                "lofi",
                "playlist",
                "official audio",
            )
        val musicScore =
            v.topics.entries
                .filter {
                    musicKeywords.contains(it.key) ||
                        it.key.contains("feat")
                }.sumOf { it.value }
        val totalScore = v.topics.values.sum()

        fun mag(cv: ContentVector) = cv.topics.values.sum()
        val nightMag = (
            mag(
                brain.timeVectors[TimeBucket.WEEKDAY_NIGHT]
                    ?: ContentVector(),
            ) +
                mag(
                    brain.timeVectors[TimeBucket.WEEKEND_NIGHT]
                        ?: ContentVector(),
                )
        )
        val morningMag = (
            mag(
                brain.timeVectors[TimeBucket.WEEKDAY_MORNING]
                    ?: ContentVector(),
            ) +
                mag(
                    brain.timeVectors[TimeBucket.WEEKEND_MORNING]
                        ?: ContentVector(),
                )
        )
        val isNocturnal = nightMag > (morningMag * 1.5) && nightMag > 5.0

        val rawPersona =
            when {
                totalScore > 0 &&
                    musicScore > (totalScore * 0.4) -> FlowPersona.AUDIOPHILE

                v.isLive > 0.6 -> FlowPersona.LIVEWIRE

                isNocturnal -> FlowPersona.NIGHT_OWL

                brain.totalInteractions > 500 &&
                    v.pacing > 0.65 -> FlowPersona.BINGER

                v.complexity > 0.75 -> FlowPersona.SCHOLAR

                v.duration > 0.70 -> FlowPersona.DEEP_DIVER

                v.duration < 0.35 &&
                    v.pacing > 0.60 -> FlowPersona.SKIMMER

                diversityIndex < 0.25 -> FlowPersona.SPECIALIST

                else -> FlowPersona.EXPLORER
            }

        val lastPersona =
            brain.lastPersona?.let { name ->
                FlowPersona.entries.find { it.name == name }
            }

        return if (lastPersona != null &&
            rawPersona != lastPersona &&
            brain.personaStability < NeuroScoring.PERSONA_STABILITY_THRESHOLD
        ) {
            lastPersona
        } else {
            rawPersona
        }
    }

    private fun timeBucketAt(now: Long): TimeBucket {
        val cal = Calendar.getInstance().apply { timeInMillis = now }
        val hour = cal.get(Calendar.HOUR_OF_DAY)
        val day = cal.get(Calendar.DAY_OF_WEEK)
        val weekend = day == Calendar.SATURDAY || day == Calendar.SUNDAY
        return when {
            weekend && hour in 6..11 -> TimeBucket.WEEKEND_MORNING
            weekend && hour in 12..17 -> TimeBucket.WEEKEND_AFTERNOON
            weekend && hour in 18..23 -> TimeBucket.WEEKEND_EVENING
            weekend -> TimeBucket.WEEKEND_NIGHT
            hour in 6..11 -> TimeBucket.WEEKDAY_MORNING
            hour in 12..17 -> TimeBucket.WEEKDAY_AFTERNOON
            hour in 18..23 -> TimeBucket.WEEKDAY_EVENING
            else -> TimeBucket.WEEKDAY_NIGHT
        }
    }
}
