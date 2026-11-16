package com.github.dvbeckwitt.videre

import com.github.dvbeckwitt.videre.proxy.GatewayContext
import okhttp3.HttpUrl.Companion.toHttpUrl
import org.junit.Assert.*
import org.junit.Test
import java.net.URI
import java.security.MessageDigest
import java.util.Base64

class NerdVpnBrowserAttemptTest {
    private val server = "https://invidious.nerdvpn.de/".toHttpUrl()
    private val context = GatewayContext("fixture-account", server)
    private val now = 10_000L
    private val code = "A".repeat(43)
    private val scheme = "com.github.dvbeckwitt.videre.auth"

    private fun attempt(nonce: String = "attempt-nonce") = checkNotNull(
        NerdVpnBrowserAttempt.create(context, server, persistSession = false,
            proxyEnabled = false, now = now, nonce = nonce)
    )

    private fun callback(attempt: NerdVpnBrowserAttempt, value: String = code) =
        "${attempt.pkce.callbackUrl}?code=$value"

    @Test fun directTokenAttemptPinsTheRequestedAccountAndCanonicalOrigin() {
        val pending = attempt()
        assertEquals(context, pending.context)
        assertEquals(server, pending.server)
        assertEquals("$scheme://callback/attempt-nonce", pending.pkce.callbackUrl)
        assertFalse(pending.expired(now))
    }

    @Test fun protectedSessionsAndConfiguredProxyNeverOfferExternalAuthentication() {
        for ((persist, proxy) in listOf(true to false, false to true, true to true)) {
            assertNull(NerdVpnBrowserAttempt.create(context, server,
                persistSession = persist, proxyEnabled = proxy, now = now))
        }
    }

    @Test fun externalAuthenticationRejectsOnionAliasesAndNonRootAddresses() {
        val onion = "nerdvpneaggggfdiurknszkbmhvjndks5z5k3g5yp4nhphflh3n3boad.onion"
        for (address in listOf(
            "http://invidious.nerdvpn.de/",
            "https://www.invidious.nerdvpn.de/",
            "https://invidious.nerdvpn.de:8443/",
            "https://invidious.nerdvpn.de.attacker.example/",
            "https://another.example/",
            "http://$onion/",
            "https://$onion/",
            "https://invidious.nerdvpn.de/path",
            "https://invidious.nerdvpn.de/?query=yes",
            "https://invidious.nerdvpn.de/#fragment",
            "https://user@invidious.nerdvpn.de/",
            "https://user:password@invidious.nerdvpn.de/",
        )) {
            val candidate = address.toHttpUrl()
            val candidateContext = GatewayContext("fixture-account", candidate)
            assertNull(address, NerdVpnBrowserAttempt.create(candidateContext, candidate,
                persistSession = false, proxyEnabled = false, now = now))
        }
    }

    @Test fun accountContextCannotAuthorizeAnotherOrigin() {
        for (origin in listOf("https://different.example/", "https://invidious.nerdvpn.de:8443/")) {
            val differentOrigin = GatewayContext(context.key, origin.toHttpUrl())
            assertNull(NerdVpnBrowserAttempt.create(differentOrigin, server,
                persistSession = false, proxyEnabled = false, now = now))
        }
    }

    @Test fun authorizationUsesS256AndApiKeyScopeWithoutExposingVerifier() {
        val pending = attempt()
        val url = pending.pkce.authorizationUrl(server).toHttpUrl()
        val digest = MessageDigest.getInstance("SHA-256")
            .digest(pending.pkce.verifier.toByteArray(Charsets.US_ASCII))
        val expectedChallenge = Base64.getUrlEncoder().withoutPadding().encodeToString(digest)

        assertEquals(server.scheme, url.scheme)
        assertEquals(server.host, url.host)
        assertEquals(server.port, url.port)
        assertEquals("/authorize_token", url.encodedPath)
        assertEquals(":feed,:subscriptions*,:playlists*,:history*,:api_key", url.queryParameter("scopes"))
        assertEquals("S256", url.queryParameter("code_challenge_method"))
        assertEquals(expectedChallenge, url.queryParameter("code_challenge"))
        assertEquals(pending.pkce.callbackUrl, url.queryParameter("callback_url"))
        assertFalse(url.toString().contains(pending.pkce.verifier))
        assertEquals(scheme, URI(pending.pkce.callbackUrl).scheme)
    }

    @Test fun independentAttemptsGenerateDistinctCallbacksAndPrivateVerifiers() {
        val first = checkNotNull(NerdVpnBrowserAttempt.create(context, server,
            persistSession = false, proxyEnabled = false, now = now))
        val second = checkNotNull(NerdVpnBrowserAttempt.create(context, server,
            persistSession = false, proxyEnabled = false, now = now))
        assertNotEquals(first.pkce.callbackUrl, second.pkce.callbackUrl)
        assertNotEquals(first.pkce.verifier, second.pkce.verifier)
    }

    @Test fun callbackCannotStartExchangeBeforeTheUserLaunchesTheBrowser() {
        val pending = attempt()
        assertNull(pending.takeCode(callback(pending), now))
        assertTrue(pending.launch(now))
        assertEquals(code, pending.takeCode(callback(pending), now))
    }

    @Test fun oneLaunchAndOneAcceptedCallbackCannotExchangeTwice() {
        val pending = attempt()
        assertTrue(pending.launch(now))
        assertFalse(pending.launch(now + 1))
        assertEquals(code, pending.takeCode(callback(pending), now + 1))
        assertNull(pending.takeCode(callback(pending), now + 2))
        assertNull(pending.takeCode(callback(pending, "B".repeat(43)), now + 2))
    }

    @Test fun invalidCallbacksDoNotConsumeTheLiveAttempt() {
        val pending = attempt()
        assertTrue(pending.launch(now))
        val base = pending.pkce.callbackUrl
        for (incoming in listOf(
            "videre-gateway://callback/attempt-nonce?code=$code",
            "$scheme://other/attempt-nonce?code=$code",
            "$scheme://callback.attacker.example/attempt-nonce?code=$code",
            "$scheme://user@callback/attempt-nonce?code=$code",
            "$scheme://callback:443/attempt-nonce?code=$code",
            "$scheme://callback/another-nonce?code=$code",
            "$scheme://callback/attempt%2Dnonce?code=$code",
            "$base?code=$code#fragment",
            "$base?code=$code#",
            "$base?code=$code&code=$code",
            "$base?code=$code&%63ode=$code",
            "$base?code=$code&token=fixture-token",
            "$base?token=fixture-token",
            "$base?code=",
            "$base?code=%",
            "$base?code=${"A".repeat(8193)}",
            base,
        )) {
            assertNull(incoming, pending.takeCode(incoming, now + 1))
        }
        assertEquals(code, pending.takeCode(callback(pending), now + 2))
    }

    @Test fun attemptDeadlineAppliesBeforeLaunchAndBeforeCallback() {
        val deadline = now + NerdVpnBrowserAttempt.TIMEOUT_MILLIS
        val unlaunched = attempt("unlaunched")
        assertFalse(unlaunched.expired(deadline - 1))
        assertTrue(unlaunched.expired(deadline))
        assertFalse(unlaunched.launch(deadline))

        val expiredAfterLaunch = attempt("launched")
        assertTrue(expiredAfterLaunch.launch(now))
        assertNull(expiredAfterLaunch.takeCode(callback(expiredAfterLaunch), deadline))

        val stillCurrent = attempt("still-current")
        assertTrue(stillCurrent.launch(now))
        assertEquals(code, stillCurrent.takeCode(callback(stillCurrent), deadline - 1))
    }

    @Test fun cancellationBeforeOrAfterLaunchRejectsLateCallbacks() {
        val unlaunched = attempt("cancelled-choice")
        unlaunched.close()
        unlaunched.close()
        assertFalse(unlaunched.launch(now))
        assertNull(unlaunched.takeCode(callback(unlaunched), now))

        val launched = attempt("cancelled-browser")
        assertTrue(launched.launch(now))
        launched.close()
        assertNull(launched.takeCode(callback(launched), now + 1))
    }

    @Test fun cancelledAttemptCannotConsumeAReplacementAttemptsCallback() {
        val previous = attempt("previous")
        assertTrue(previous.launch(now))
        previous.close()
        val replacement = attempt("replacement")
        assertTrue(replacement.launch(now + 1))

        assertNull(previous.takeCode(callback(replacement), now + 2))
        assertNull(replacement.takeCode(callback(previous), now + 2))
        previous.close()
        assertEquals(code, replacement.takeCode(callback(replacement), now + 2))
    }

    @Test fun ownedCallbackSchemeIsConsumedEvenWhenMalformedOrUnknown() {
        for (incoming in listOf(
            "$scheme://callback/unknown?code=$code",
            "$scheme://wrong-host/unknown?code=$code",
            "$scheme:not a valid callback",
            "$scheme:",
            "${scheme.uppercase()}://callback/unknown?code=$code",
        )) {
            assertTrue(incoming, NerdVpnBrowserAttempt.ownsCallback(incoming))
        }
        for (incoming in listOf(null, "", "https://example.test/", "videre-gateway://callback/nonce",
            "$scheme.extra://callback/nonce", "https://$scheme/callback/nonce")) {
            assertFalse(incoming, NerdVpnBrowserAttempt.ownsCallback(incoming))
        }
    }
}
