package com.github.dvbeckwitt.videre.proxy

import org.junit.Assert.assertEquals
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertNull
import org.junit.Test

/** Pure session-boundary checks; AndroidKeyStore persistence requires a device. */
class OnionSessionStoreTest {
    private val host = "a".repeat(56) + ".onion"
    private val origin = "http://$host"
    private val sevenDays = 7L * 24 * 60 * 60 * 1000

    private fun headers(): Map<String, String> = linkedMapOf(
        "User-Agent" to "Synthetic browser for tests",
        "Accept-Language" to "en-US,en;q=0.9",
        "Accept-Encoding" to "gzip, deflate",
        "Accept" to "application/json, text/plain;q=0.9",
        "Cookie" to "gandalf_token=test-only",
    )

    @Test
    fun `canonical origin accepts only the default HTTP port`() {
        assertEquals(origin, canonicalOnionOrigin(origin))
        assertEquals(origin, canonicalOnionOrigin("$origin/"))
        assertEquals(origin, canonicalOnionOrigin("$origin:80/"))
        assertNull(canonicalOnionOrigin("$origin:8080/"))
        assertEquals(origin, canonicalOnionOrigin("HTTP://${host.uppercase()}/"))
    }

    @Test
    fun `sessions cannot be keyed by a different scheme host or onion shape`() {
        listOf(
            "https://$host/",
            "http://example.com/",
            "http://sub.$host/",
            "http://$host.example/",
            "http://${"a".repeat(55)}.onion/",
            "http://${"a".repeat(57)}.onion/",
            "http://${"1".repeat(56)}.onion/",
            "http://$host:0/",
            "http://$host:65536/",
        ).forEach { assertNull(canonicalOnionOrigin(it)) }
    }

    @Test
    fun `credentials paths query fragments and unsafe URL characters are rejected`() {
        listOf(
            "http://user:password@$host/",
            "http://@$host/",
            "$origin/api/v1/stats",
            "$origin/?query=value",
            "$origin/?",
            "$origin/#fragment",
            "$origin/#",
            " $origin",
            "$origin ",
            "$origin/\n",
            "$origin\\path",
        ).forEach { assertNull(canonicalOnionOrigin(it)) }
    }

    @Test
    fun `header names are canonicalized without changing fingerprint values`() {
        val supplied = headers().mapKeys { it.key.lowercase() }
        assertEquals(headers(), validatedOnionSessionHeaders(supplied))
    }

    @Test
    fun `each fingerprint field and the authentication cookie are required`() {
        headers().keys.forEach { omitted ->
            assertNull(validatedOnionSessionHeaders(headers().filterKeys { it != omitted }))
        }
        listOf("", " ").forEach { empty ->
            assertNull(validatedOnionSessionHeaders(headers() + ("Cookie" to empty)))
        }
    }

    @Test
    fun `unexpected duplicate and nonstring header entries are rejected`() {
        assertNull(validatedOnionSessionHeaders(headers() + ("Authorization" to "test-only")))
        assertNull(validatedOnionSessionHeaders(headers() + ("cookie" to "different=test-only")))
        assertNull(validatedOnionSessionHeaders(headers() + (1 to "test-only")))
        assertNull(validatedOnionSessionHeaders(headers() + ("Cookie" to 1)))
    }

    @Test
    fun `control characters cannot enter replay headers`() {
        listOf('\r', '\n', '\t', '\u0000', '\u007f').forEach { control ->
            assertNull(validatedOnionSessionHeaders(headers() + ("Cookie" to "token=a${control}b")))
        }
    }

    @Test
    fun `header size limits bound individual and combined values`() {
        assertNotNull(validatedOnionSessionHeaders(headers() + ("Cookie" to "x".repeat(32768))))
        assertNull(validatedOnionSessionHeaders(headers() + ("Cookie" to "x".repeat(32769))))
        assertNull(validatedOnionSessionHeaders(headers().mapValues { "x".repeat(32768) }))
    }

    @Test
    fun `expired sessions are rejected and short lifetimes remain unchanged`() {
        val now = 1_000_000L
        assertNull(boundedOnionSessionExpiry(now - 1, now))
        assertNull(boundedOnionSessionExpiry(now, now))
        assertEquals(now + 1, boundedOnionSessionExpiry(now + 1, now))
        assertEquals(now + 60_000, boundedOnionSessionExpiry(now + 60_000, now))
    }

    @Test
    fun `long lifetimes are capped without extending shorter server expiry`() {
        val now = 1_000_000L
        assertEquals(now + sevenDays, boundedOnionSessionExpiry(now + sevenDays, now))
        assertEquals(now + sevenDays, boundedOnionSessionExpiry(Long.MAX_VALUE, now))
    }

    @Test
    fun `expiry arithmetic does not overflow near the maximum timestamp`() {
        assertEquals(Long.MAX_VALUE, boundedOnionSessionExpiry(Long.MAX_VALUE, Long.MAX_VALUE - 1))
        assertNull(boundedOnionSessionExpiry(Long.MAX_VALUE, Long.MAX_VALUE))
    }
}
