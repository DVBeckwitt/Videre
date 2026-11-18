/*
 * Copyright (C) 2025-2026 Flow | A-EDev
 * Copyright (C) 2026 Videre contributors
 * Adapted from Flow Android Client FlowNeuroEngine.interestChips and
 * HomeChipPolicies.interestQueries at 565d1f7a3da4ca8e54463b029f151ef87415858a.
 * https://github.com/Flow-Tube/Flow
 * SPDX-License-Identifier: GPL-3.0-only
 */
package com.github.dvbeckwitt.videre.recommendations.video

internal fun interestChips(
    brain: UserBrain,
    tokenizer: NeuroTokenizer,
    now: Long,
    categoryOf: (String) -> ChannelCategory?,
    channelEdges: Map<String, Double>,
): Pair<InterestChipSet, List<Map<String, Any?>>> {
    val clusters = NeuroClusters.buildClusters(
        topicScores = brain.interests.topics,
        affinities = brain.topicAffinities,
        channelTopicProfiles = brain.channelTopicProfiles,
        categories = NeuroTopicCatalog.TOPIC_CATEGORIES,
        normalizeLemma = tokenizer::keyOf,
        tagAffinities = brain.tagAffinities,
        channelEdges = channelEdges,
    )
    val picks = brain.preferredTopics.flatMapTo(HashSet(), tokenizer::keysOf)
    val hasEvidence = { cluster: NeuroClusters.TopicCluster ->
        cluster.topics.size >= 2 ||
            cluster.topics.any { it in picks } ||
            brain.topicEvidence[cluster.representative]?.let {
                it.watchSignals >= 2 || it.explicitSignals > 0 || it.positiveScore >= 1.2
            } == true
    }
    val groups = InterestChips.groups(clusters, hasEvidence) { cluster ->
        NeuroCategories.clusterCategory(cluster.topics, brain.channelTopicProfiles, categoryOf)
    }
    val set = InterestChips.stable(brain.interestChips, groups, now)
    val chips = InterestChips.chips(set, groups, brain.displayForms, tokenizer::specificity) { key ->
        brain.topicEvidence[key]?.let { it.watchSignals + it.explicitSignals } ?: 0
    }
    return set to chips.map { chip ->
        mapOf(
            "id" to chip.representative,
            "label" to chip.label,
            "category" to chip.category,
            "topics" to chip.topics.take(5),
            "queries" to interestQueries(chip).map { NeuroDisplayForms.searchText(brain.displayForms, it) },
        )
    }
}

/**
 * Searches for an interest chip: its own phrases first, a lone word qualified by one of them. A theme
 * chip searches each of its interests in turn.
 */
private fun interestQueries(
    interest: InterestChip,
    max: Int = 3,
): List<String> {
    if (interest.parts.isNotEmpty()) {
        val perPart = interest.parts.map { interestQueries(it, max) }
        return (0 until max)
            .flatMap { round -> perPart.mapNotNull { it.getOrNull(round) } }
            .distinct()
            .take(max)
    }
    val rep = NeuroScoring.stripDomainTag(interest.representative)
    val members = interest.topics.map(NeuroScoring::stripDomainTag).filter { it != rep }

    fun qualified(member: String) = if (rep in member.split(' ')) member else "$rep $member"
    val queries = LinkedHashSet<String>()
    if (' ' in rep) queries += rep
    members.filter { ' ' in it }.forEach { queries += qualified(it) }
    members.filter { ' ' !in it }.forEach { queries += qualified(it) }
    if (queries.isEmpty()) queries += rep
    return queries.take(max)
}

/** Pure index rules from Flow Android Client NeuroCategoryStore. */
internal object NeuroCategoryIndex {
    const val MAX_CHANNELS = 1000

    data class Channel(val counts: Map<String, Int>, val at: Long)

    fun categoryOf(channels: Map<String, Channel>, channelId: String): ChannelCategory? {
        val counts = channels[channelId]?.counts ?: return null
        val top = counts.maxByOrNull { it.value } ?: return null
        return ChannelCategory(top.key, top.value / (counts.values.sumOf(Int::toLong) + 1.0))
    }

    fun record(
        channels: Map<String, Channel>,
        channelId: String,
        categoryId: String,
        now: Long,
    ): Map<String, Channel> {
        val existing = channels[channelId]?.counts.orEmpty()
        val count = ((existing[categoryId] ?: 0) + 1).coerceAtMost(VideoStateCodec.MAX_COUNTER)
        val updated = channels + (channelId to Channel(existing + (categoryId to count), now))
        return if (updated.size <= MAX_CHANNELS) updated else updated.entries
            .sortedByDescending { it.value.at }.take(MAX_CHANNELS).associate { it.key to it.value }
    }
}
