package com.github.dvbeckwitt.videre.proxy

import java.io.IOException
import java.security.MessageDigest
import okhttp3.HttpUrl
import okhttp3.HttpUrl.Companion.toHttpUrlOrNull

/** Transient source DTO. Only digests of scoped representation identities reach disk. */
internal class PlaybackCacheIdentity private constructor(
    private val origin: HttpUrl,
    val profileId: String,
    val contentId: String,
    val profileKey: String,
    val gateway: GatewayContext?,
    private val scope: String,
    private val session: String,
    private val resources: Map<String, Resource>,
) {
    private data class Resource(val key: String, val persistent: Boolean, val manifest: Boolean)

    fun knownMediaResource(value: String): Boolean = resources[value]?.manifest == false

    fun requireDestination(value: String): HttpUrl {
        val target = value.toHttpUrlOrNull() ?: throw IOException("Invalid cached media destination.")
        if (target.username.isNotEmpty() || target.password.isNotEmpty() ||
            isOfficialYoutubeUrl(target) || target.scheme != origin.scheme ||
            target.host != origin.host || target.port != origin.port) throw SelectedOriginBlocked()
        return target
    }

    /** Unknown adaptive children remain distinct and cannot survive their source session. */
    fun key(value: String): String? {
        val target = requireDestination(value)
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

        fun parse(values: Map<*, *>, sourceUri: String?): PlaybackCacheIdentity {
            require((values["version"] as? Number)?.toDouble() == 1.0) { "Unsupported playback cache identity." }
            fun text(name: String): String = (values[name] as? String)
                ?.takeIf { it.isNotEmpty() && it.length <= 4096 }
                ?: throw IllegalArgumentException("Invalid playback cache identity.")
            val origin = text("origin").toHttpUrlOrNull()
                ?: throw IllegalArgumentException("Invalid playback cache origin.")
            require(origin.encodedPath == "/" && origin.query == null && origin.fragment == null &&
                origin.username.isEmpty() && origin.password.isEmpty() && !isOfficialYoutubeUrl(origin))
            // Length prefixing prevents delimiter collisions across user-owned identifiers.
            val scope = listOf("1", text("profileId"), text("accountId"), origin.toString(), text("contentId"))
                .joinToString("") { "${it.length}:$it" }
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
            val gateway = (values["gatewayContext"] as? String)?.let(GatewayContext::parse)
            require(gateway == null || gateway.allows(origin))
            require(!isNerdVpnOrigin(origin) || gateway != null)
            return PlaybackCacheIdentity(origin, text("profileId"), text("contentId"), digest(text("profileId")), gateway, digest(scope), text("sessionId"), resources).also {
                sourceUri?.let(it::requireDestination)
                resources.keys.forEach(it::requireDestination)
            }
        }
    }
}
