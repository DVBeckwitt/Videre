/*
 * Copyright (C) 2025-2026 Flow | A-EDev
 * Copyright (C) 2026 Videre contributors
 * Adapted from FlowNeuroEngine.bootstrapFromSubscriptions at
 * 565d1f7a3da4ca8e54463b029f151ef87415858a.
 * https://github.com/Flow-Tube/Flow
 * SPDX-License-Identifier: GPL-3.0-only
 */
package com.github.dvbeckwitt.videre.recommendations.video

/** The bootstrap applies to a temporary ranking view of real learned state. */
internal object VideoSubscriptionPrior {
    private const val SEED_WEIGHT = 0.25
    private const val SEED_CAP = NeuroVectorMath.ESTABLISHED_TOPIC_THRESHOLD - 0.01

    fun apply(brain: UserBrain, channelNames: List<String>, tokenizer: NeuroTokenizer): UserBrain {
        if (channelNames.isEmpty() || (brain.totalInteractions > 5 && brain.globalVector.topics.isNotEmpty())) {
            return brain
        }

        val mentions = mutableMapOf<String, Int>()
        for (name in channelNames) {
            for (token in tokenizer.tokenize(name)) {
                mentions[token] = (mentions[token] ?: 0) + 1
            }
        }
        if (mentions.isEmpty()) return brain

        val topics = brain.globalVector.topics.toMutableMap()
        for ((key, count) in mentions) {
            val weight = (count * SEED_WEIGHT).coerceAtMost(SEED_CAP)
            topics[key] = maxOf(topics[key] ?: 0.0, weight)
        }
        val top = mentions.entries.sortedByDescending { it.value }.take(15).map { it.key }
        val affinities = brain.topicAffinities.toMutableMap()
        for (i in top.indices) {
            for (j in i + 1 until top.size) {
                val key = NeuroScoring.makeAffinityKey(top[i], top[j])
                affinities[key] = ((affinities[key] ?: 0.0) + 0.15).coerceAtMost(NeuroScoring.AFFINITY_MAX)
            }
        }
        return brain.copy(
            globalVector = brain.globalVector.copy(topics = topics),
            topicAffinities = affinities,
            hasCompletedOnboarding = true,
        )
    }
}
