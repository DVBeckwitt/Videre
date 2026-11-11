package com.github.dvbeckwitt.videre.proxy

import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

class NativeHttpRetryPolicyTest {
    @Test fun `only known transient HTTP statuses can enter native recovery`() {
        for (status in listOf(502, 503, 504)) {
            assertTrue(NativeHttpRetryPolicy.allowsTransientResponse(status, emptyMap()))
            assertTrue(NativeHttpRetryPolicy.allowsTransientResponse(status,
                mapOf(null to listOf("HTTP/1.1 fixture"), "Content-Type" to listOf("video/mp4"))))
        }
        for (status in listOf(200, 301, 401, 403, 404, 408, 429, 500, 501)) {
            assertFalse(NativeHttpRetryPolicy.allowsTransientResponse(status, emptyMap()))
        }
    }

    @Test fun `every advertised cooldown prevents immediate native recovery`() {
        for (status in listOf(502, 503, 504)) {
            for (name in listOf("Retry-After", "retry-after", "RETRY-AFTER")) {
                for (values in listOf(emptyList(), listOf(""), listOf("0"), listOf("60"),
                    listOf("invalid"), listOf("Wed, 21 Oct 2099 07:28:00 GMT"), listOf("0", "60"))) {
                    assertFalse("$status $name $values", NativeHttpRetryPolicy.allowsTransientResponse(status,
                        mapOf(name to values)))
                }
            }
        }
    }
}
