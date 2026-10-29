package com.github.dvbeckwitt.videre.proxy

import okhttp3.Headers
import okhttp3.HttpUrl.Companion.toHttpUrl
import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Test

class GatewayCookieTest {
    private val origin = "http://${"a".repeat(56)}.onion"
    private val stats = "$origin/api/v1/stats".toHttpUrl()

    private fun gateway() = OnionVerificationGateway(
        origin,
        ProxyPolicy(true),
        "test_only_gate_123456789",
        object : OnionVerificationGateway.Listener {
            override fun onEvent(safe: String) = Unit
            override fun onVerified(requestHeaders: Map<String, String>, expiresAt: Long) = Unit
        },
    )

    @Test
    fun `successful request snapshot survives cookies added and rotated by its response`() {
        gateway().use { gateway ->
            gateway.saveCookies(stats, Headers.Builder()
                .add("Set-Cookie", "gandalf=verified-test-only; Path=/; Secure; HttpOnly; Max-Age=3600")
                .build())
            val sent = gateway.cookiesForRequest(stats)
            val expiry = sent.expiresAt
            assertEquals("gandalf=verified-test-only", sent.header)
            assertTrue(expiry > System.currentTimeMillis())

            gateway.saveCookies(stats, Headers.Builder()
                .add("Set-Cookie", "SID=anonymous-test-only; Path=/; Secure; HttpOnly")
                .add("Set-Cookie", "gandalf=rotated-test-only; Path=/; Secure; Max-Age=7200")
                .build())

            assertEquals("gandalf=verified-test-only", sent.header)
            assertEquals(expiry, sent.expiresAt)
            assertEquals("gandalf=rotated-test-only; SID=anonymous-test-only", gateway.cookiesForRequest(stats).header)
        }
    }

    @Test
    fun `unrelated cookie path is not exported and does not invalidate root session`() {
        gateway().use { gateway ->
            gateway.saveCookies(stats, Headers.Builder()
                .add("Set-Cookie", "gandalf=root-test-only; Path=/; Secure; Max-Age=3600")
                .add("Set-Cookie", "challenge=path-test-only; Path=/.gandalf; Secure; Max-Age=3600")
                .build())
            val sent = gateway.cookiesForRequest(stats)
            assertEquals("gandalf=root-test-only", sent.header)
            assertTrue(sent.expiresAt > System.currentTimeMillis())
        }
    }

    @Test
    fun `selected path cookie cannot become an origin wide session`() {
        gateway().use { gateway ->
            gateway.saveCookies(stats, Headers.Builder()
                .add("Set-Cookie", "gandalf=root-test-only; Path=/; Secure; Max-Age=3600")
                .add("Set-Cookie", "api=path-test-only; Path=/api/v1; Secure; Max-Age=3600")
                .build())
            val sent = gateway.cookiesForRequest(stats)
            assertEquals("gandalf=root-test-only; api=path-test-only", sent.header)
            assertEquals(0L, sent.expiresAt)
        }
    }
}
