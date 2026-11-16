package com.github.dvbeckwitt.videre

import com.github.dvbeckwitt.videre.proxy.GatewayContext
import com.github.dvbeckwitt.videre.proxy.NerdVpnPkce
import java.util.UUID
import okhttp3.HttpUrl

/** Memory-only authorization state. A cold callback cannot recover an attempt. */
internal class NerdVpnBrowserAttempt private constructor(
    val context: GatewayContext,
    val server: HttpUrl,
    val pkce: NerdVpnPkce,
    private val expiresAt: Long,
) {
    private var launched = false
    private var exchanging = false
    private var finished = false

    fun expired(now: Long): Boolean = now >= expiresAt

    fun launch(now: Long): Boolean {
        if (finished || launched || expired(now)) return false
        launched = true
        return true
    }

    fun takeCode(callback: String, now: Long): String? {
        if (!launched || finished || exchanging || expired(now)) return null
        val code = pkce.codeFromCallback(callback) ?: return null
        exchanging = true
        return code
    }

    fun close() { finished = true }

    companion object {
        const val TIMEOUT_MILLIS = 10 * 60 * 1000L

        fun create(context: GatewayContext, server: HttpUrl, persistSession: Boolean,
            proxyEnabled: Boolean, now: Long, nonce: String = UUID.randomUUID().toString()): NerdVpnBrowserAttempt? {
            if (persistSession || proxyEnabled || !context.allows(server) || now < 0 ||
                now > Long.MAX_VALUE - TIMEOUT_MILLIS) return null
            val pkce = NerdVpnPkce.forExternalBrowser(server, nonce) ?: return null
            return NerdVpnBrowserAttempt(context, server, pkce, now + TIMEOUT_MILLIS)
        }

        // Consume even malformed callbacks for our scheme rather than expose
        // grant values to URL sharing, Dart navigation, or application logs.
        fun ownsCallback(value: String?): Boolean = value?.substringBefore(':', "")
            ?.equals(NerdVpnPkce.EXTERNAL_CALLBACK_SCHEME, ignoreCase = true) == true
    }
}
