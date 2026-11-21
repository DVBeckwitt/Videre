package com.github.dvbeckwitt.videre.proxy

import java.io.IOException
import okhttp3.Headers
import okhttp3.HttpUrl
import okhttp3.HttpUrl.Companion.toHttpUrlOrNull
import okhttp3.Request

/** A stable account can move between distinct frontend base paths on the same authority. */
internal data class MediaCompanionAccount(val gateway: GatewayContext, val instanceBase: HttpUrl)

/** User-approved destinations for one remote media source. Never parsed from HTTP headers. */
internal class MediaCompanions private constructor(val account: MediaCompanionAccount, private val origins: Set<HttpUrl>) {
    val gateway get() = account.gateway
    val origin get() = gateway.origin

    fun permitsCompanion(url: HttpUrl): Boolean =
        url.isHttps && url.username.isEmpty() && url.password.isEmpty() && origins.any { sameOrigin(it, url) }

    fun requireDestination(url: HttpUrl, mediaRequest: Boolean = true) {
        MediaCompanionGrants.requireCurrent(this)
        if (url.username.isNotEmpty() || url.password.isNotEmpty()) throw SelectedOriginBlocked()
        if (!permitsCompanion(url)) requireSelectedOrigin(origin, url, media = mediaRequest)
    }

    fun includes(source: MediaCompanions): Boolean =
        source.account == account && origins.containsAll(source.origins)

    /** OkHttp calls this network boundary on each redirect as well as on initial track requests.
     * Rebuild the foreign request headers, including Host, without forwarding caller values. */
    fun prepareRequest(request: Request, instanceHeaderNames: Set<String>): Request {
        requireDestination(request.url)
        if (sameOrigin(origin, request.url)) return request
        if (request.method !in setOf("GET", "HEAD") || request.body != null) throw SelectedOriginBlocked()
        val url = request.url
        val headers = Headers.Builder()
            .add("Host", if (url.port == 443) url.host else "${url.host}:${url.port}")
            .add("User-Agent", "Videre")
            .add("Accept-Encoding", "identity")
        // Media3 uses single byte ranges for reads/seeks. A configured instance
        // header with that name is still an account-owned value.
        val range = request.headers.values("Range").singleOrNull()
        if (range != null && range.matches(byteRange) && instanceHeaderNames.none { it.equals("Range", true) }) {
            headers.add("Range", range)
        }
        return request.newBuilder().headers(headers.build())
            .tag(GatewayRequestScope::class.java, null)
            .tag(NerdVpnRequestRevision::class.java, null)
            .tag(NerdVpnExpectedIntent::class.java, null)
            .build()
    }

    companion object {
        private val authority = Regex("""https://([a-zA-Z0-9.-]+)(?::([0-9]{1,5}))?/?""")
        private val dnsLabel = Regex("""[a-z0-9](?:[a-z0-9-]{0,61}[a-z0-9])?""")
        private val localSuffixes = listOf("onion", "local", "localhost", "localdomain", "lan", "internal", "home.arpa", "home")
        private val byteRange = Regex("""bytes=[0-9]{1,19}-[0-9]{0,19}""")

        private fun parseOrigin(value: Any?): HttpUrl {
            val match = (value as? String)?.takeIf { it.length <= 270 }?.let(authority::matchEntire)
                ?: throw IllegalArgumentException("Invalid media companion origin.")
            val host = match.groupValues[1].lowercase()
            val labels = host.split('.')
            require(host.length <= 253 && labels.size >= 2 && labels.all(dnsLabel::matches) &&
                labels.last().first() in 'a'..'z' && !isOfficialYoutubeHost(host) &&
                localSuffixes.none { host == it || host.endsWith(".$it") }) { "Invalid media companion host." }
            val port = match.groupValues[2].takeIf { it.isNotEmpty() }?.toInt() ?: 443
            require(port in 1..65535) { "Invalid media companion port." }
            return HttpUrl.Builder().scheme("https").host(host).port(port).build()
        }

        fun fromSettings(values: Map<*, *>): MediaCompanions {
            val origin = parseOrigin(values["origin"])
            val list = values["origins"] as? List<*> ?: throw IllegalArgumentException("Missing media companions.")
            require(list.size <= 8) { "Invalid media companion count." }
            val origins = list.map(::parseOrigin).toSet()
            require(origin !in origins) { "The instance is already trusted." }
            val encoded = values["gatewayContext"] as? String ?: throw IllegalArgumentException("Missing media account context.")
            val gateway = GatewayContext.parse(encoded)
            require(gateway.allows(origin)) { "Media account origin does not match." }
            // Earlier root-only callers did not pass a base path. Credentials
            // remain scoped to the gateway independently of this grant key.
            val base = if ("instanceBase" in values) {
                (values["instanceBase"] as? String)?.toHttpUrlOrNull()
                    ?: throw IllegalArgumentException("Invalid media instance address.")
            } else origin
            require(sameOrigin(base, origin) && base.username.isEmpty() && base.password.isEmpty() &&
                base.query == null && base.fragment == null) { "Invalid media instance address." }
            return MediaCompanions(MediaCompanionAccount(gateway, base), origins)
        }

        fun parse(values: Map<*, *>, sourceUri: String?): MediaCompanions {
            val result = fromSettings(values)
            require(result.origins.isNotEmpty()) { "Expected an approved media companion." }
            val source = sourceUri?.toHttpUrlOrNull() ?: throw IllegalArgumentException("Expected an HTTPS media source.")
            require(source.username.isEmpty() && source.password.isEmpty() &&
                (sameOrigin(result.origin, source) || result.permitsCompanion(source))) { "Unapproved media source." }
            MediaCompanionGrants.requireCurrent(result)
            return result
        }
    }
}

/** The profile database owns persistent consent. During this process, an edit fences
 * off active readers and delayed source DTOs created before the user's revocation. */
internal object MediaCompanionGrants {
    private val updated = mutableMapOf<MediaCompanionAccount, MediaCompanions>()

    @Synchronized fun update(values: Map<*, *>): Set<MediaCompanionAccount> {
        // The profile database identifies all accounts sharing this instance.
        // Validate the entire edit before changing admission for any reader.
        val entries = if ("accounts" in values) {
            values["accounts"] as? List<*> ?: throw IllegalArgumentException("Invalid media account list.")
        } else listOf(values)
        require(entries.isNotEmpty()) { "Missing media accounts." }
        val changes = entries.map {
            MediaCompanions.fromSettings(it as? Map<*, *> ?: throw IllegalArgumentException("Invalid media account."))
        }.associateBy { it.account }
        require(changes.size == entries.size) { "Repeated media account." }
        updated.putAll(changes)
        return changes.keys
    }

    @Synchronized fun isCurrent(source: MediaCompanions): Boolean =
        updated[source.account]?.includes(source) != false

    fun requireCurrent(source: MediaCompanions) {
        if (!isCurrent(source)) throw IOException("Media companion permission changed.")
    }
}
