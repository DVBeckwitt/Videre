package com.github.dvbeckwitt.videre.recommendations.video

/** Videre's versioned primitive-map format, independent of Flow's Android DataStore. */
internal object VideoStateCodec {
    /** Canonical persisted fields; unknown fields must not pass through backups. */
    val allowedKeys = setOf(
        "schemaVersion", "domain", "timeVectors", "timeBucketCounts", "globalVector", "recentVector", "shortsVector",
        "channelScores", "topicAffinities", "totalInteractions", "consecutiveSkips", "blockedTopics", "blockedChannels",
        "preferredTopics", "hasCompletedOnboarding", "lastPersona", "personaStability", "idfWordFrequency", "idfTotalDocuments",
        "countedDocumentIds", "watchHistoryMap", "seenShortsHistory", "channelTopicProfiles", "suppressedVideoIds",
        "suppressedChannels", "rejectionPatterns", "feedHistory", "recentQueryTokens", "topicEvidence", "recentRelatedSeeds",
        "staleQueries", "clusterRotation", "tagAffinities", "recentShortsSeeds", "channelMemory", "interestChips",
        "displayForms", "formatAffinity", "categoryAffinity", "languageProfile", "languageVotes", "keyLanguage",
        "processedEventIds", "session", "coWatchSources", "channelCategories",
    )
    // A batch contains at most 1000 events. Leave room for increments and merges.
    const val MAX_COUNTER = Int.MAX_VALUE - 2000
    private const val MAX_TIMESTAMP = 253402300799999.0
    private val channelIdPattern = Regex("^UC[A-Za-z0-9_-]{22}$")
    private val videoIdPattern = Regex("^[A-Za-z0-9_-]{11}$")
    fun isChannelId(value: String) = channelIdPattern.matches(value)
    fun isVideoId(value: String) = videoIdPattern.matches(value)

    /**
     * Persisted data is strict. The permissive helpers below are also used for
     * incomplete server candidates, so validate state before decoding instead
     * of changing those candidate semantics or silently repairing user data.
     */
    fun validate(state: Map<String, Any?>) {
        objectFields(state, allowedKeys)
        if (state.containsKey("schemaVersion")) numeric(state["schemaVersion"], 1.0, 1.0, true)
        if (state.containsKey("domain")) require(state["domain"] == "video") { "Invalid video state domain" }
        fieldMap(state, "coWatchSources", NeuroCoWatchStore.MAX_SOURCES).forEach { (id, value) ->
            val row = objectValue(value)
            objectFields(row, setOf("channelId", "related", "at"))
            require(isVideoId(id) && isChannelId(text(row["channelId"]))) { "Invalid co-watch source" }
            require(array(row["related"], NeuroCoWatchStore.CHANNELS_PER_SOURCE).all {
                it is String && isChannelId(it)
            }) { "Invalid co-watch neighbours" }
            timestampField(row, "at")
        }
        fieldMap(state, "channelCategories", NeuroCategoryIndex.MAX_CHANNELS).forEach { (id, value) ->
            val row = objectValue(value)
            objectFields(row, setOf("counts", "at"))
            require(isChannelId(id)) { "Invalid category channel" }
            numericMap(row, "counts", 15, MAX_COUNTER.toDouble(), integral = true)
            require(map(row["counts"]).keys.all(NeuroCategories::isKnown)) { "Invalid channel category" }
            timestampField(row, "at")
        }
        val buckets = TimeBucket.entries.map { it.name }.toSet()
        fieldMap(state, "timeVectors", buckets.size).forEach { (key, value) ->
            require(key in buckets) { "Invalid video time bucket" }
            validateVector(objectValue(value))
        }
        fieldMap(state, "timeBucketCounts", buckets.size).forEach { (key, value) ->
            require(key in buckets) { "Invalid video time bucket" }
            counter(value)
        }
        listOf("globalVector", "recentVector", "shortsVector").forEach { key ->
            if (state.containsKey(key)) validateVector(objectValue(state[key]))
        }
        numericMap(state, "channelScores", 500, 1.0)
        numericMap(state, "topicAffinities", 500, 1.0)
        counterField(state, "totalInteractions")
        counterField(state, "consecutiveSkips", 30)
        listOf("blockedTopics", "blockedChannels", "preferredTopics").forEach { stringList(state, it, 1000) }
        boolField(state, "hasCompletedOnboarding")
        textField(state, "lastPersona", 512, nullable = true)
        counterField(state, "personaStability", 10)
        numericMap(state, "idfWordFrequency", 20_000, 1.0e9, integral = true)
        counterField(state, "idfTotalDocuments")
        stringList(state, "countedDocumentIds", 500)
        numericMap(state, "watchHistoryMap", 2000, 1.0)
        timestampMap(state, "seenShortsHistory", 3000)
        fieldMap(state, "channelTopicProfiles", 200).forEach { (_, value) ->
            dictionary(value, 15).values.forEach { numeric(it, 0.0, 1.0e9) }
        }
        timestampMap(state, "suppressedVideoIds", 5000)
        timestampMap(state, "suppressedChannels", 100)
        fieldMap(state, "rejectionPatterns", 500).forEach { (_, value) ->
            val row = objectValue(value)
            objectFields(row, setOf("count", "lastRejectedAt"))
            counterField(row, "count")
            timestampField(row, "lastRejectedAt")
        }
        fieldMap(state, "feedHistory", 3000).forEach { (_, value) ->
            val row = objectValue(value)
            objectFields(row, setOf("lastShown", "showCount"))
            timestampField(row, "lastShown")
            counterField(row, "showCount")
        }
        if (state.containsKey("recentQueryTokens")) {
            array(state["recentQueryTokens"], 100).forEach { stringsValue(it, 100) }
        }
        fieldMap(state, "topicEvidence", 500).forEach { (_, value) ->
            val row = objectValue(value)
            objectFields(row, setOf("positiveSignals", "negativeSignals", "watchSignals", "explicitSignals", "positiveScore", "videoIds", "channelIds", "firstSeenAt", "lastSeenAt"))
            listOf("positiveSignals", "negativeSignals", "watchSignals", "explicitSignals").forEach { counterField(row, it) }
            numberField(row, "positiveScore", 50.0)
            stringList(row, "videoIds", 6)
            stringList(row, "channelIds", 6)
            timestampField(row, "firstSeenAt")
            timestampField(row, "lastSeenAt")
        }
        timestampMap(state, "recentRelatedSeeds", 60)
        timestampMap(state, "staleQueries", 40)
        timestampMap(state, "clusterRotation", 40)
        numericMap(state, "tagAffinities", 2000, 1.0)
        timestampMap(state, "recentShortsSeeds", 60)
        if (state.containsKey("channelMemory")) {
            val memory = objectValue(state["channelMemory"])
            objectFields(memory, setOf("entries", "clearedAt"))
            timestampField(memory, "clearedAt")
            fieldMap(memory, "entries", 200).forEach { (_, value) ->
                val row = objectValue(value)
                objectFields(row, setOf("name", "rejectedAt", "forgottenAt"))
                textField(row, "name")
                timestampField(row, "rejectedAt")
                timestampField(row, "forgottenAt")
            }
        }
        if (state.containsKey("interestChips")) {
            val row = objectValue(state["interestChips"])
            objectFields(row, setOf("masses", "computedAt"))
            numericMap(row, "masses", 4, 1.0e9)
            timestampField(row, "computedAt")
        }
        fieldMap(state, "displayForms", 2000).forEach { (_, value) ->
            val row = objectValue(value)
            objectFields(row, setOf("form", "votes"))
            textField(row, "form")
            if (row.containsKey("votes")) numeric(row["votes"], 1.0, 20.0, true)
        }
        numericMap(state, "formatAffinity", 100, 1.0)
        // Category affinity is evidence count, not a probability (upstream halves above 400).
        numericMap(state, "categoryAffinity", 100, 400.0)
        textField(state, "languageProfile", 20, nullable = true)
        numericMap(state, "languageVotes", 20_000, 1.0e9, integral = true)
        textField(state, "keyLanguage", 20, nullable = true)
        stringList(state, "processedEventIds", 1000)
        if (state.containsKey("session")) validateSession(objectValue(state["session"]))
    }

    private fun validateVector(row: Map<String, Any?>) {
        objectFields(row, setOf("topics", "duration", "pacing", "complexity", "isLive", "formats"))
        numericMap(row, "topics", 1000, 1.0e9)
        listOf("duration", "pacing", "complexity", "isLive").forEach { numberField(row, it, 1.0) }
        stringList(row, "formats", 100)
    }

    private fun validateSession(row: Map<String, Any?>) {
        objectFields(row, setOf("startedAt", "lastAt", "videoCount", "topics", "momentum", "impressions"))
        timestampField(row, "startedAt")
        timestampField(row, "lastAt")
        counterField(row, "videoCount")
        stringList(row, "topics", 50)
        if (row.containsKey("momentum")) array(row["momentum"], 10).forEach { value ->
            val entry = objectValue(value)
            objectFields(entry, setOf("topic", "positive"))
            textField(entry, "topic")
            boolField(entry, "positive")
        }
        fieldMap(row, "impressions", 500).forEach { (_, value) ->
            val entry = objectValue(value)
            objectFields(entry, setOf("count", "lastSeen"))
            counterField(entry, "count")
            timestampField(entry, "lastSeen")
        }
    }

    private fun objectValue(value: Any?): Map<String, Any?> = dictionary(value, 100)
    private fun dictionary(value: Any?, max: Int): Map<String, Any?> {
        require(value is Map<*, *> && value.size <= max) { "Invalid or oversized video state map" }
        require(value.keys.all { it is String && it.length <= 512 }) { "Invalid video state key" }
        @Suppress("UNCHECKED_CAST")
        return value as Map<String, Any?>
    }
    private fun objectFields(row: Map<String, Any?>, allowed: Set<String>) {
        require(row.keys.all { it in allowed }) { "Unknown video state field" }
    }
    private fun fieldMap(row: Map<String, Any?>, key: String, max: Int): Map<String, Any?> =
        if (row.containsKey(key)) dictionary(row[key], max) else emptyMap()
    private fun array(value: Any?, max: Int): List<*> {
        require(value is List<*> && value.size <= max) { "Invalid or oversized video state list" }
        return value
    }
    private fun stringsValue(value: Any?, max: Int) {
        require(array(value, max).all { it is String && it.length <= 512 }) { "Invalid video state string list" }
    }
    private fun stringList(row: Map<String, Any?>, key: String, max: Int) {
        if (row.containsKey(key)) stringsValue(row[key], max)
    }
    private fun numeric(value: Any?, min: Double, max: Double, integral: Boolean = false) {
        require(value is Number) { "Invalid video state number" }
        val number = value.toDouble()
        require(number.isFinite() && number in min..max && (!integral || number == number.toLong().toDouble())) { "Video state number is out of range" }
    }
    private fun counter(value: Any?, max: Int = MAX_COUNTER) = numeric(value, 0.0, max.toDouble(), true)
    private fun counterField(row: Map<String, Any?>, key: String, max: Int = MAX_COUNTER) {
        if (row.containsKey(key)) counter(row[key], max)
    }
    private fun numberField(row: Map<String, Any?>, key: String, max: Double) {
        if (row.containsKey(key)) numeric(row[key], 0.0, max)
    }
    private fun numericMap(row: Map<String, Any?>, key: String, maxEntries: Int, max: Double, integral: Boolean = false) {
        fieldMap(row, key, maxEntries).values.forEach { numeric(it, 0.0, max, integral) }
    }
    private fun timestampField(row: Map<String, Any?>, key: String) {
        if (row.containsKey(key)) numeric(row[key], 0.0, MAX_TIMESTAMP, true)
    }
    private fun timestampMap(row: Map<String, Any?>, key: String, max: Int) = numericMap(row, key, max, MAX_TIMESTAMP, true)
    private fun textField(row: Map<String, Any?>, key: String, max: Int = 512, nullable: Boolean = false) {
        if (!row.containsKey(key)) return
        val value = row[key]
        require((nullable && value == null) || (value is String && value.length <= max)) { "Invalid video state text" }
    }
    private fun boolField(row: Map<String, Any?>, key: String) {
        if (row.containsKey(key)) require(row[key] is Boolean) { "Invalid video state boolean" }
    }
    fun map(value: Any?): Map<String, Any?> {
        if (value !is Map<*, *>) return emptyMap()
        return value.entries.filter { it.key is String }.associate { it.key as String to it.value }
    }
    fun number(value: Any?, default: Double = 0.0): Double =
        (value as? Number)?.toDouble()?.takeIf { it.isFinite() } ?: default
    fun text(value: Any?, limit: Int = 512): String = (value as? String).orEmpty().take(limit)
    fun coWatchSources(state: Map<String, Any?>): Map<String, NeuroCoWatchStore.Source> =
        map(state["coWatchSources"]).mapValues { (_, value) ->
            val row = map(value)
            NeuroCoWatchStore.Source(text(row["channelId"]), strings(row["related"], 10).toList(), number(row["at"]).toLong())
        }

    fun channelCategories(state: Map<String, Any?>): Map<String, NeuroCategoryIndex.Channel> =
        map(state["channelCategories"]).mapValues { (_, value) ->
            val row = map(value)
            NeuroCategoryIndex.Channel(ints(row["counts"]), number(row["at"]).toLong())
        }
    fun strings(value: Any?, limit: Int = 5000): Set<String> =
        (value as? List<*>).orEmpty().asSequence().filterIsInstance<String>().map { it.take(512) }.take(limit).toCollection(LinkedHashSet())
    private fun doubles(value: Any?, cap: Int = 20_000): Map<String, Double> =
        map(value).entries.take(cap).associate { it.key.take(512) to number(it.value).coerceIn(0.0, 1.0e9) }
    private fun longs(value: Any?, cap: Int = 5000): Map<String, Long> =
        map(value).entries.take(cap).associate { it.key.take(512) to number(it.value).coerceIn(0.0, 9.0e15).toLong() }
    private fun ints(value: Any?): Map<String, Int> = doubles(value).mapValues { it.value.coerceAtMost(Int.MAX_VALUE.toDouble()).toInt() }
    private fun vector(value: Any?): ContentVector {
        val fields = map(value)
        return ContentVector(
            topics = doubles(fields["topics"], 1000),
            duration = number(fields["duration"], 0.5).coerceIn(0.0, 1.0),
            pacing = number(fields["pacing"], 0.5).coerceIn(0.0, 1.0),
            complexity = number(fields["complexity"], 0.5).coerceIn(0.0, 1.0),
            isLive = number(fields["isLive"]).coerceIn(0.0, 1.0),
            formats = strings(fields["formats"], 100),
        )
    }
    private fun encodeVector(value: ContentVector): Map<String, Any?> = mapOf(
        "topics" to value.topics, "duration" to value.duration, "pacing" to value.pacing,
        "complexity" to value.complexity, "isLive" to value.isLive, "formats" to value.formats.toList(),
    )
    fun decode(state: Map<String, Any?>): UserBrain {
        validate(state)
        return UserBrain(
        timeVectors = map(state["timeVectors"]).mapNotNull { (key, value) -> TimeBucket.entries.find { it.name == key }?.let { it to vector(value) } }.toMap(),
        timeBucketCounts = map(state["timeBucketCounts"]).mapNotNull { (key, value) -> TimeBucket.entries.find { it.name == key }?.let { it to number(value).toInt().coerceAtLeast(0) } }.toMap(),
        globalVector = vector(state["globalVector"]),
        recentVector = vector(state["recentVector"]),
        shortsVector = vector(state["shortsVector"]),
        channelScores = doubles(state["channelScores"], 500),
        topicAffinities = doubles(state["topicAffinities"], 500),
        totalInteractions = number(state["totalInteractions"]).toInt().coerceAtLeast(0),
        consecutiveSkips = number(state["consecutiveSkips"]).toInt().coerceIn(0, 30),
        blockedTopics = strings(state["blockedTopics"], 1000),
        blockedChannels = strings(state["blockedChannels"], 1000),
        preferredTopics = strings(state["preferredTopics"], 1000),
        hasCompletedOnboarding = state["hasCompletedOnboarding"] == true,
        lastPersona = state["lastPersona"] as? String,
        personaStability = number(state["personaStability"]).toInt().coerceIn(0, 10),
        idfWordFrequency = ints(state["idfWordFrequency"]),
        idfTotalDocuments = number(state["idfTotalDocuments"]).toInt().coerceAtLeast(0),
        countedDocumentIds = strings(state["countedDocumentIds"], 500),
        watchHistoryMap = doubles(state["watchHistoryMap"], 2000).mapValues { it.value.coerceIn(0.0, 1.0).toFloat() },
        seenShortsHistory = longs(state["seenShortsHistory"], 3000),
        channelTopicProfiles = map(state["channelTopicProfiles"]).entries.take(200).associate { it.key to doubles(it.value, 15) },
        suppressedVideoIds = longs(state["suppressedVideoIds"], 5000),
        suppressedChannels = longs(state["suppressedChannels"], 100),
        rejectionPatterns = map(state["rejectionPatterns"]).entries.take(500).associate { (key, value) -> val m=map(value); key to RejectionSignal(number(m["count"]).toInt().coerceAtLeast(0), number(m["lastRejectedAt"]).toLong().coerceAtLeast(0)) },
        feedHistory = map(state["feedHistory"]).entries.take(3000).associate { (key, value) -> val m=map(value); key to FeedEntry(number(m["lastShown"]).toLong().coerceAtLeast(0), number(m["showCount"]).toInt().coerceAtLeast(0)) },
        recentQueryTokens = (state["recentQueryTokens"] as? List<*>).orEmpty().takeLast(100).map { strings(it, 100) },
        topicEvidence = map(state["topicEvidence"]).entries.take(500).associate { (key, value) -> key to decodeEvidence(map(value)) },
        recentRelatedSeeds = longs(state["recentRelatedSeeds"], 60),
        staleQueries = longs(state["staleQueries"], 40),
        clusterRotation = longs(state["clusterRotation"], 40),
        tagAffinities = doubles(state["tagAffinities"], 2000),
        recentShortsSeeds = longs(state["recentShortsSeeds"], 60),
        channelMemory = decodeChannelMemory(map(state["channelMemory"])),
        interestChips = map(state["interestChips"]).let { InterestChipSet(doubles(it["masses"], 4), number(it["computedAt"]).toLong().coerceAtLeast(0)) },
        displayForms = map(state["displayForms"]).entries.take(2000).associate { (key, value) -> val m=map(value); key to DisplayForm(text(m["form"]), number(m["votes"], 1.0).toInt().coerceIn(1,20)) },
        formatAffinity = doubles(state["formatAffinity"], 100),
        categoryAffinity = doubles(state["categoryAffinity"], 100),
        languageProfile = (state["languageProfile"] as? String)?.take(20),
        languageVotes = ints(state["languageVotes"]),
        keyLanguage = (state["keyLanguage"] as? String)?.take(20),
        )
    }
    private fun decodeEvidence(m: Map<String, Any?>) = TopicEvidence(
        positiveSignals=number(m["positiveSignals"]).toInt().coerceAtLeast(0), negativeSignals=number(m["negativeSignals"]).toInt().coerceAtLeast(0),
        watchSignals=number(m["watchSignals"]).toInt().coerceAtLeast(0), explicitSignals=number(m["explicitSignals"]).toInt().coerceAtLeast(0),
        positiveScore=number(m["positiveScore"]).coerceIn(0.0,50.0), videoIds=strings(m["videoIds"],6), channelIds=strings(m["channelIds"],6),
        firstSeenAt=number(m["firstSeenAt"]).toLong().coerceAtLeast(0),lastSeenAt=number(m["lastSeenAt"]).toLong().coerceAtLeast(0),
    )
    private fun decodeChannelMemory(m: Map<String, Any?>) = ChannelMemoryState(
        entries=map(m["entries"]).entries.take(200).associate { (key,value) -> val row=map(value); key to ChannelMemoryEntry(name=text(row["name"]), rejectedAt=number(row["rejectedAt"]).toLong().coerceAtLeast(0), forgottenAt=number(row["forgottenAt"]).toLong().coerceAtLeast(0)) },
        clearedAt=number(m["clearedAt"]).toLong().coerceAtLeast(0),
    )
    fun encode(
        b: UserBrain,
        coWatchSources: Map<String, NeuroCoWatchStore.Source> = emptyMap(),
        channelCategories: Map<String, NeuroCategoryIndex.Channel> = emptyMap(),
    ): Map<String, Any?> = linkedMapOf(
        "coWatchSources" to coWatchSources.mapValues { (_, source) ->
            mapOf("channelId" to source.channelId, "related" to source.related, "at" to source.at)
        },
        "channelCategories" to channelCategories.mapValues { (_, channel) ->
            mapOf("counts" to channel.counts, "at" to channel.at)
        },
        "schemaVersion" to 1, "domain" to "video",
        "timeVectors" to b.timeVectors.mapKeys { it.key.name }.mapValues { encodeVector(it.value) },
        "timeBucketCounts" to b.timeBucketCounts.mapKeys { it.key.name },
        "globalVector" to encodeVector(b.globalVector), "recentVector" to encodeVector(b.recentVector), "shortsVector" to encodeVector(b.shortsVector),
        "channelScores" to b.channelScores, "topicAffinities" to b.topicAffinities, "totalInteractions" to b.totalInteractions,
        "consecutiveSkips" to b.consecutiveSkips, "blockedTopics" to b.blockedTopics.toList(), "blockedChannels" to b.blockedChannels.toList(),
        "preferredTopics" to b.preferredTopics.toList(), "hasCompletedOnboarding" to b.hasCompletedOnboarding,
        "lastPersona" to b.lastPersona, "personaStability" to b.personaStability, "idfWordFrequency" to b.idfWordFrequency,
        "idfTotalDocuments" to b.idfTotalDocuments, "countedDocumentIds" to b.countedDocumentIds.toList(),
        "watchHistoryMap" to b.watchHistoryMap.mapValues { it.value.toDouble() }, "seenShortsHistory" to b.seenShortsHistory,
        "channelTopicProfiles" to b.channelTopicProfiles, "suppressedVideoIds" to b.suppressedVideoIds, "suppressedChannels" to b.suppressedChannels,
        "rejectionPatterns" to b.rejectionPatterns.mapValues { mapOf("count" to it.value.count, "lastRejectedAt" to it.value.lastRejectedAt) },
        "feedHistory" to b.feedHistory.mapValues { mapOf("lastShown" to it.value.lastShown, "showCount" to it.value.showCount) },
        "recentQueryTokens" to b.recentQueryTokens.map { it.toList() },
        "topicEvidence" to b.topicEvidence.mapValues { (_,e) -> mapOf("positiveSignals" to e.positiveSignals,"negativeSignals" to e.negativeSignals,"watchSignals" to e.watchSignals,"explicitSignals" to e.explicitSignals,"positiveScore" to e.positiveScore,"videoIds" to e.videoIds.toList(),"channelIds" to e.channelIds.toList(),"firstSeenAt" to e.firstSeenAt,"lastSeenAt" to e.lastSeenAt) },
        "recentRelatedSeeds" to b.recentRelatedSeeds, "staleQueries" to b.staleQueries, "clusterRotation" to b.clusterRotation,
        "tagAffinities" to b.tagAffinities, "recentShortsSeeds" to b.recentShortsSeeds,
        "channelMemory" to mapOf("clearedAt" to b.channelMemory.clearedAt,"entries" to b.channelMemory.entries.mapValues { (_,e) -> mapOf("name" to e.name,"rejectedAt" to e.rejectedAt,"forgottenAt" to e.forgottenAt) }),
        "interestChips" to mapOf("masses" to b.interestChips.masses,"computedAt" to b.interestChips.computedAt),
        "displayForms" to b.displayForms.mapValues { mapOf("form" to it.value.form,"votes" to it.value.votes) },
        "formatAffinity" to b.formatAffinity, "categoryAffinity" to b.categoryAffinity,
        "languageProfile" to b.languageProfile, "languageVotes" to b.languageVotes, "keyLanguage" to b.keyLanguage,
    ).also(::validate)
}
