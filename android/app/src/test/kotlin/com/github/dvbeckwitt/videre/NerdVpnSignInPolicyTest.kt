package com.github.dvbeckwitt.videre

import com.github.dvbeckwitt.videre.proxy.GatewayContext
import com.github.dvbeckwitt.videre.proxy.NERDVPN_ONION_HOST
import okhttp3.HttpUrl.Companion.toHttpUrl
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Test

class NerdVpnSignInPolicyTest {
    private val server = "https://invidious.nerdvpn.de/".toHttpUrl()
    private val context = GatewayContext("fixture-account", server)

    @Test fun directTokenSignInAllowsOnlyTheCanonicalOrigin() {
        assertEquals(server, nerdVpnJavaScriptOrigin(context, server,
            persistSession = false, proxyEnabled = false))
        // HttpUrl canonicalizes case and an explicit default HTTPS port.
        val canonical = "https://INVIDIOUS.NERDVPN.DE:443/".toHttpUrl()
        assertEquals(server, nerdVpnJavaScriptOrigin(context, canonical,
            persistSession = false, proxyEnabled = false))
    }

    @Test fun proxyAndPersistentGatewaySessionsRemainScriptless() {
        for ((persist, proxy) in listOf(true to false, false to true, true to true)) {
            assertNull(nerdVpnJavaScriptOrigin(context, server,
                persistSession = persist, proxyEnabled = proxy))
        }
    }

    @Test fun aliasesCredentialsOnionAndNonRootServersRemainScriptless() {
        for (address in listOf(
            "http://invidious.nerdvpn.de/",
            "https://invidious.nerdvpn.de./",
            "https://invidious.nerdvpn.de:8443/",
            "https://www.invidious.nerdvpn.de/",
            "https://invidious.nerdvpn.de.attacker.example/",
            "https://another.example/",
            "http://$NERDVPN_ONION_HOST/",
            "https://$NERDVPN_ONION_HOST/",
            "https://invidious.nerdvpn.de/path",
            "https://invidious.nerdvpn.de/?query=yes",
            "https://invidious.nerdvpn.de/#fragment",
            "https://user@invidious.nerdvpn.de/",
            "https://user:password@invidious.nerdvpn.de/",
        )) {
            val candidate = address.toHttpUrl()
            assertNull(address, nerdVpnJavaScriptOrigin(GatewayContext(context.key, candidate), candidate,
                persistSession = false, proxyEnabled = false))
        }
    }

    @Test fun anotherAccountOriginCannotEnableScriptsForThisServer() {
        for (address in listOf("https://other.example/", "https://invidious.nerdvpn.de:8443/")) {
            assertNull(nerdVpnJavaScriptOrigin(GatewayContext(context.key, address.toHttpUrl()), server,
                persistSession = false, proxyEnabled = false))
        }
    }
}
