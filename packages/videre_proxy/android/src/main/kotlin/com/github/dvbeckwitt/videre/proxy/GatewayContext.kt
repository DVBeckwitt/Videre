package com.github.dvbeckwitt.videre.proxy

import java.io.IOException
import okhttp3.HttpUrl
import okhttp3.HttpUrl.Companion.toHttpUrlOrNull
import okio.ByteString.Companion.decodeBase64

const val GATEWAY_CONTEXT_HEADER = "X-Videre-Gateway-Context"

/** Non-secret account identity, consumed locally and never sent over HTTP. */
data class GatewayContext(val key: String, val origin: HttpUrl) {
    val profileName: String get() = "videre_gateway_$key"

    fun allows(url: HttpUrl): Boolean = url.isHttps && url.username.isEmpty() &&
        url.password.isEmpty() && origin.scheme == url.scheme &&
        origin.host == url.host && origin.port == url.port

    companion object {
        private val keyPattern = Regex("^[0-9a-f]{8}-[0-9a-f]{4}-5[0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$")

        fun parse(value: String): GatewayContext {
            require(value.length <= 2048) { "Invalid protected server context." }
            val parts = value.split('.')
            require(parts.size == 3 && parts[0] == "v1" && keyPattern.matches(parts[1])) {
                "Invalid protected server context."
            }
            val origin = parts[2].decodeBase64()?.utf8()?.toHttpUrlOrNull()
            require(origin != null && origin.isHttps && origin.username.isEmpty() &&
                origin.password.isEmpty() && origin.encodedPath == "/" &&
                origin.query == null && origin.fragment == null) { "Invalid protected server origin." }
            return GatewayContext(parts[1], origin)
        }
    }
}

data class GatewayCookies(
    val enabled: Boolean, val needsSignIn: Boolean,
    val cookies: String? = null, val revision: Long? = null,
)

class GatewayAuthenticationRequired : IOException("Sign in again to the protected server.")
class GatewaySessionUnavailable : IOException("The protected server session is unavailable.")

interface GatewayCookieAccess {
    fun resolve(context: GatewayContext, url: HttpUrl): GatewayCookies
    fun ingest(context: GatewayContext, url: HttpUrl, cookies: List<String>,
        statusCode: Int, contentType: String?, location: String?, revision: Long?): Boolean
}

/** Provider initialized by the plugin, including background Flutter engines. */
object GatewayCookieAccessRegistry {
    @Volatile var provider: GatewayCookieAccess? = null
}

/** Preserve the explicit Invidious SID over a browser's optional Invidious SID. */
internal fun mergeGatewayCookies(gateway: String?, explicit: String?): String? {
    val result = linkedMapOf<String, String>()
    for (header in listOf(gateway, explicit)) {
        header?.split(';')?.forEach { part ->
            val separator = part.indexOf('=')
            if (separator > 0) {
                val name = part.substring(0, separator).trim()
                if (name.isNotEmpty()) result[name] = part.substring(separator + 1).trim()
            }
        }
    }
    return result.takeIf { it.isNotEmpty() }?.entries?.joinToString("; ") { "${it.key}=${it.value}" }
}
