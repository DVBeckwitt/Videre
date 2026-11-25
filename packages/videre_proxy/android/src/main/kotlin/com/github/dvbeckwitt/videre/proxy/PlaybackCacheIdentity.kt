package com.github.dvbeckwitt.videre.proxy

import java.io.IOException
import java.security.MessageDigest
import okhttp3.HttpUrl
import okhttp3.HttpUrl.Companion.toHttpUrlOrNull

internal class PlaybackCacheOwner private constructor(
    val profileId: String,
    private val accountId: String,
    val origin: HttpUrl,
    val gateway: GatewayContext?,
) {
    val profileKey = PlaybackCacheIdentity.digest(profileId)
    val catalogKey = scopedDigest("music-v1", gateway?.key.orEmpty())

    fun scope(contentId: String) = scopedDigest("1", contentId)

    fun persistentKey(contentId: String, rendition: String) =
        "p:$profileKey:${scope(contentId)}:$rendition"

    private fun scopedDigest(version: String, value: String) = PlaybackCacheIdentity.digest(
        listOf(version, profileId, accountId, origin.toString(), value)
            .joinToString("") { "${it.length}:$it" },
    )

    companion object {
        fun parse(values: Map<*, *>): PlaybackCacheOwner {
            val origin = values.cacheIdentityText("origin").toHttpUrlOrNull()
                ?: throw IllegalArgumentException("Invalid playback cache origin.")
            require(origin.encodedPath == "/" && origin.query == null && origin.fragment == null &&
                origin.username.isEmpty() && origin.password.isEmpty() && !isOfficialYoutubeUrl(origin))
            val gateway = (values["gatewayContext"] as? String)?.let(GatewayContext::parse)
            require(gateway == null || gateway.allows(origin))
            require(!isNerdVpnOrigin(origin) || gateway != null)
            return PlaybackCacheOwner(values.cacheIdentityText("profileId"),
                values.cacheIdentityText("accountId"), origin, gateway)
        }
    }
}

private fun Map<*, *>.cacheIdentityText(name: String): String = (get(name) as? String)
    ?.takeIf { it.isNotEmpty() && it.length <= 4096 }
    ?: throw IllegalArgumentException("Invalid playback cache identity.")

/** Transient source DTO. Only digests of scoped representation identities reach disk. */
internal class PlaybackCacheIdentity private constructor(
    val owner: PlaybackCacheOwner,
    val contentId: String,
    private val session: String,
    private val resources: Map<String, Resource>,
) {
    private data class Resource(val key: String, val persistent: Boolean, val manifest: Boolean)
    val profileId get() = owner.profileId
    val profileKey get() = owner.profileKey
    val gateway get() = owner.gateway
    private val scope = owner.scope(contentId)

    fun knownMediaResource(value: String): Boolean = resources[value]?.manifest == false

    fun persistentRepresentation(value: String): String? = resources[value]
        ?.takeIf { it.persistent && !it.manifest && key(value)?.startsWith("p:") == true }?.key

    private fun requireDestination(value: String, mediaRequest: Boolean = false): HttpUrl {
        val target = value.toHttpUrlOrNull() ?: throw IOException("Invalid cached media destination.")
        if (target.username.isNotEmpty() || target.password.isNotEmpty() ||
            isOfficialYoutubeUrl(target)) throw SelectedOriginBlocked()
        requireSelectedOrigin(owner.origin, target, media = mediaRequest)
        return target
    }

    /** Unknown adaptive children remain distinct and cannot survive their source session. */
    fun key(value: String): String? {
        val target = requireDestination(value, mediaRequest = true)
        val resource = resources[value]
        val path = target.encodedPath.lowercase()
        if (resource?.manifest == true || path.endsWith(".mpd") || path.endsWith(".m3u8") || path.endsWith(".m3u") ||
            path.contains("/api/manifest/") || path.contains("/manifest/")) return null
        return if (resource?.persistent == true) {
            "p:$profileKey:$scope:${digest(resource.key)}"
        } else {
            "s:$profileKey:$scope:${digest(session + ":" + (resource?.key ?: digest(value)))}"
        }
    }

    companion object {
        internal fun digest(value: String): String = MessageDigest.getInstance("SHA-256")
            .digest(value.toByteArray(Charsets.UTF_8)).joinToString("") { "%02x".format(it) }

        fun parse(values: Map<*, *>, sourceUri: String?, companions: MediaCompanions? = null): PlaybackCacheIdentity {
            require((values["version"] as? Number)?.toDouble() == 1.0) { "Unsupported playback cache identity." }
            val owner = PlaybackCacheOwner.parse(values)
            val resources = LinkedHashMap<String, Resource>()
            val rawResources = values["resources"] as? List<*> ?: throw IllegalArgumentException()
            require(rawResources.size <= 512)
            for (entry in rawResources) {
                val item = entry as? Map<*, *> ?: throw IllegalArgumentException()
                val url = item["url"] as? String ?: throw IllegalArgumentException()
                val key = item["key"] as? String ?: throw IllegalArgumentException()
                require(url.length <= 32768 && key.isNotEmpty() && key.length <= 8192)
                resources[url] = Resource(key, item["persistent"] == true, item["manifest"] == true)
            }
            require(companions == null || companions.gateway == owner.gateway) { "Media account context does not match." }
            return PlaybackCacheIdentity(owner, values.cacheIdentityText("contentId"),
                values.cacheIdentityText("sessionId"), resources).also {
                if (companions == null) {
                    sourceUri?.let(it::requireDestination)
                    resources.keys.forEach(it::requireDestination)
                } else {
                    for (value in listOfNotNull(sourceUri) + resources.keys) {
                        companions.requireDestination(value.toHttpUrlOrNull() ?: throw SelectedOriginBlocked(), mediaRequest = false)
                    }
                }
            }
        }
    }
}
