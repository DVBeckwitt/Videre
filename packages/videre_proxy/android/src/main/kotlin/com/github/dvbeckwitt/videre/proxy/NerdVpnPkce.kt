package com.github.dvbeckwitt.videre.proxy

import java.net.URI
import java.net.URLDecoder
import java.security.SecureRandom
import okhttp3.HttpUrl
import okio.ByteString.Companion.encodeUtf8
import okio.ByteString.Companion.toByteString

/** One browser authorization attempt. The verifier is never placed in a URL. */
class NerdVpnPkce private constructor(val verifier: String, val callbackUrl: String) {
    fun authorizationUrl(server: HttpUrl): String = server.newBuilder()
        .encodedPath("/authorize_token")
        .addQueryParameter("scopes", ":feed,:subscriptions*,:playlists*,:history*,:api_key")
        .addQueryParameter("callback_url", callbackUrl)
        .addQueryParameter("code_challenge", challengeFor(verifier))
        .addQueryParameter("code_challenge_method", "S256")
        .build().toString()

    fun codeFromCallback(value: String): String? = runCatching {
        if (value.length > 8192) return@runCatching null
        val received = URI(value)
        val expected = URI(callbackUrl)
        if (received.scheme != expected.scheme || received.rawAuthority != expected.rawAuthority ||
            received.rawPath != expected.rawPath || received.rawFragment != null) return@runCatching null
        val query = received.rawQuery?.split('&')?.map {
            val parts = it.split('=', limit = 2)
            URLDecoder.decode(parts[0], "UTF-8") to URLDecoder.decode(parts.getOrElse(1) { "" }, "UTF-8")
        } ?: return@runCatching null
        if (query.any { it.first == "token" }) return@runCatching null
        val codes = query.filter { it.first == "code" }
        codes.singleOrNull()?.second?.takeIf { it.isNotBlank() && it.length <= 4096 }
    }.getOrNull()

    companion object {
        private val random = SecureRandom()

        fun forServer(server: HttpUrl, nonce: String): NerdVpnPkce? {
            if (!isNerdVpnOrigin(server) || server.encodedPath != "/" ||
                server.query != null || server.fragment != null) return null
            require(Regex("^[a-zA-Z0-9-]+$").matches(nonce))
            val bytes = ByteArray(32).also(random::nextBytes)
            return NerdVpnPkce(bytes.toByteString().base64Url().trimEnd('='), "videre-gateway://callback/$nonce")
        }

        internal fun challengeFor(verifier: String): String =
            verifier.encodeUtf8().sha256().base64Url().trimEnd('=')
    }
}
