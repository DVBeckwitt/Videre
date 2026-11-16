package com.github.dvbeckwitt.videre

import com.github.dvbeckwitt.videre.proxy.GatewayContext
import okhttp3.HttpUrl

/** Page scripts can bypass an HTTP proxy using WebRTC. This exception therefore
 * belongs only to a temporary, direct sign-in at the canonical HTTPS origin. */
internal fun nerdVpnJavaScriptOrigin(context: GatewayContext, server: HttpUrl,
    persistSession: Boolean, proxyEnabled: Boolean): HttpUrl? {
    if (persistSession || proxyEnabled || !context.allows(server) || !server.isHttps ||
        server.host != "invidious.nerdvpn.de" || server.port != 443 ||
        server.encodedPath != "/" || server.query != null || server.fragment != null) return null
    return server
}
