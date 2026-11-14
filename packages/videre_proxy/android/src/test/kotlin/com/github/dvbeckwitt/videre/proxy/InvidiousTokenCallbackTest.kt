package com.github.dvbeckwitt.videre.proxy

import org.junit.Assert.*
import org.junit.Test

class InvidiousTokenCallbackTest {
    private val nonce = "attempt-nonce"
    private val callback = "videre-gateway://callback/$nonce"

    @Test fun `valid callback decodes one token exactly once`() {
        assertEquals("token/with+encoding=", invidiousTokenFromCallback(
            "$callback?token=token%2Fwith%2Bencoding%3D", nonce))
        assertEquals("literal%2F", invidiousTokenFromCallback("$callback?token=literal%252F", nonce))
        assertEquals("value", invidiousTokenFromCallback("$callback?tok%65n=value&other=ignored", nonce))
    }

    @Test fun `callback requires exact scheme authority and attempt path`() {
        for (value in listOf(
            "https://callback/$nonce?token=secret",
            "videre-auth://callback/$nonce?token=secret",
            "videre-gateway://other/$nonce?token=secret",
            "videre-gateway://callback.attacker.example/$nonce?token=secret",
            "videre-gateway://user@callback/$nonce?token=secret",
            "videre-gateway://callback:443/$nonce?token=secret",
            "videre-gateway://callback/other?token=secret",
            "$callback/extra?token=secret",
            "videre-gateway://callback/attempt%2Dnonce?token=secret",
            "$callback?token=secret#fragment",
            "$callback?token=secret#",
        )) assertNull(value, invidiousTokenFromCallback(value, nonce))
    }

    @Test fun `missing duplicate empty and malformed token values are rejected`() {
        for (query in listOf(
            "", "code=other", "token", "token=", "token=%20%09",
            "token=first&token=second", "token=first&tok%65n=second",
            "token=%", "token=%2", "token=%ZZ", "token=value&other=%",
        )) assertNull(query, invidiousTokenFromCallback("$callback?$query", nonce))
    }

    @Test fun `decoded token size bound includes valid percent encoded tokens`() {
        val maximum = "x".repeat(65536)
        assertEquals(maximum, invidiousTokenFromCallback("$callback?token=$maximum", nonce))
        assertEquals(maximum, invidiousTokenFromCallback("$callback?token=${"%78".repeat(65536)}", nonce))
        assertNull(invidiousTokenFromCallback("$callback?token=${maximum}x", nonce))
    }
}
