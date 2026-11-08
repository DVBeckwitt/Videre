package com.github.dvbeckwitt.videre.proxy

import okhttp3.HttpUrl.Companion.toHttpUrl
import org.junit.Assert.*
import org.junit.Test

class NerdVpnPkceTest {
    private val server = "https://invidious.nerdvpn.de".toHttpUrl()

    @Test fun `S256 matches RFC 7636 vector`() {
        assertEquals("E9Melhoa2OwvFrEMTJguCHaoeK1t8URWbuGJSstw-cM",
            NerdVpnPkce.challengeFor("dBjftJeZ4CVP-mB92K27uhbUJU1p1r_wW1gFWFOEjXk"))
    }

    @Test fun `authorization requests use distinct private verifiers and exact callback`() {
        val first = NerdVpnPkce.forServer(server, "first-nonce")!!
        val second = NerdVpnPkce.forServer(server, "second-nonce")!!
        assertTrue(Regex("^[A-Za-z0-9_-]{43}$").matches(first.verifier))
        assertNotEquals(first.verifier, second.verifier)
        val url = first.authorizationUrl(server).toHttpUrl()
        assertEquals("/authorize_token", url.encodedPath)
        assertEquals(":feed,:subscriptions*,:playlists*,:history*,:api_key", url.queryParameter("scopes"))
        assertEquals(first.callbackUrl, url.queryParameter("callback_url"))
        assertEquals("S256", url.queryParameter("code_challenge_method"))
        assertEquals(NerdVpnPkce.challengeFor(first.verifier), url.queryParameter("code_challenge"))
        assertFalse(url.toString().contains(first.verifier))
    }

    @Test fun `PKCE extension applies only to the approved root origin`() {
        for (url in listOf("http://invidious.nerdvpn.de", "https://www.invidious.nerdvpn.de",
            "https://invidious.nerdvpn.de:8443", "https://invidious.nerdvpn.de/another-instance",
            "https://invidious.nerdvpn.de.attacker.example", "https://user@invidious.nerdvpn.de",
            "https://invidious.nerdvpn.de/?query=yes", "https://invidious.nerdvpn.de/#fragment")) {
            assertNull(url, NerdVpnPkce.forServer(url.toHttpUrl(), "nonce"))
        }
    }

    @Test fun `callback requires the attempt nonce and one code without a token downgrade`() {
        val attempt = NerdVpnPkce.forServer(server, "nonce")!!
        assertEquals("code/with+encoding", attempt.codeFromCallback("${attempt.callbackUrl}?code=code%2Fwith%2Bencoding"))
        for (callback in listOf("videre-gateway://callback/other?code=secret",
            "videre-gateway://callback:443/nonce?code=secret", "videre-gateway://user@callback/nonce?code=secret",
            "videre-gateway://callback/nonce?code=secret#fragment", "videre-gateway://callback/nonce?token=secret",
            "videre-gateway://callback/nonce?code=one&code=two", "videre-gateway://callback/nonce?code=secret&token=token",
            "videre-gateway://callback/nonce?code=", "videre-gateway://callback/nonce?code=%00%")) {
            assertNull(callback, attempt.codeFromCallback(callback))
        }
    }
}
