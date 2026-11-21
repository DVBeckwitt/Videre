package com.github.dvbeckwitt.videre.proxy

import java.io.ByteArrayInputStream
import java.io.IOException
import okhttp3.OkHttpClient
import okhttp3.Protocol
import okhttp3.Request
import okhttp3.Response
import okhttp3.ResponseBody.Companion.asResponseBody
import okio.ByteString.Companion.encodeUtf8
import okio.buffer
import okio.source
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertThrows
import org.junit.Assert.assertTrue
import org.junit.Test

class MediaCompanionGrantsTest {
    private val companion = "https://revoke-media.example"
    private val source = "$companion/audio"

    private fun account(id: Int, origin: String, path: String = ""): Map<String, Any> {
        val key = "10000000-0000-5000-8000-${id.toString().padStart(12, '0')}"
        return mapOf(
            "origin" to origin,
            "instanceBase" to (origin + path),
            "origins" to listOf(companion),
            "gatewayContext" to "v1.$key.${origin.encodeUtf8().base64Url()}",
        )
    }

    private fun revoked(account: Map<String, Any>) = account + ("origins" to emptyList<String>())

    @Test fun `revocation while waiting for redirect headers closes the response`() {
        val origin = "https://redirect-revoke.example"
        val settings = account(31, origin)
        MediaCompanionGrants.update(settings)
        val policy = MediaCompanions.parse(settings, origin)
        val request = Request.Builder().url(origin)
            .tag(SelectedOriginScope::class.java, SelectedOriginScope(policy.origin, true, policy)).build()
        var closed = false
        val body = object : ByteArrayInputStream(byteArrayOf()) {
            override fun close() { closed = true }
        }.source().buffer().asResponseBody()
        val client = OkHttpClient.Builder().addInterceptor(SelectedOriginRedirectGuard())
            .addInterceptor { chain ->
                MediaCompanionGrants.update(revoked(settings))
                Response.Builder().request(chain.request()).protocol(Protocol.HTTP_1_1)
                    .code(307).message("Temporary Redirect").header("Location", source).body(body).build()
            }.build()
        assertThrows(IOException::class.java) { client.newCall(request).execute().use {} }
        assertTrue("The rejected redirect response must release its body.", closed)
    }

    @Test fun `batch revokes both linked accounts and keeps other profiles instances and strict sources active`() {
        val origin = "https://revoke-fixture.example"
        val active = account(1, origin)
        val inactive = account(2, origin)
        val otherProfile = account(3, origin)
        val otherPort = account(1, "$origin:8443")
        val otherInstance = account(1, "https://another-fixture.example")
        val others = listOf(otherProfile, otherPort, otherInstance)
        val all = listOf(active, inactive) + others
        MediaCompanionGrants.update(mapOf("accounts" to all))
        val policies = all.map { MediaCompanions.parse(it, source) }
        val factory = PolicyCallFactory()
        try {
            factory.configure(ProxyPolicy())
            val request = Request.Builder().url(source).build()
            val streams = policies.map { factory.forSource(source, emptySet(), companions = it) }
            val calls = streams.map { it.newCall(request) }
            val strict = factory.forSource(origin, emptySet(), policies.first().gateway)
                .newCall(request.newBuilder().url(origin).build())

            val affected = MediaCompanionGrants.update(mapOf("accounts" to listOf(revoked(active), revoked(inactive))))
            assertEquals(2, affected.size)
            factory.cancelRevokedCompanionCalls(affected)
            val lateChild = request.newBuilder().header(INSTANCE_ORIGIN_HEADER, origin).build()
            for (i in 0..1) {
                assertTrue(calls[i].isCanceled())
                assertThrows(IOException::class.java) { streams[i].newCall(lateChild) }
                assertThrows(IOException::class.java) { MediaCompanions.parse(all[i], source) }
                assertThrows(IOException::class.java) { factory.forSource(source, emptySet(), companions = policies[i]) }
            }
            for (i in 2 until all.size) {
                assertFalse(calls[i].isCanceled())
                MediaCompanions.parse(all[i], source)
            }
            assertFalse(strict.isCanceled())

            // Re-adding this account can install the remembered instance grant
            // even when its previous native scope was explicitly revoked.
            MediaCompanionGrants.update(inactive)
            factory.forSource(source, emptySet(), companions = MediaCompanions.parse(inactive, source))
            assertThrows(IOException::class.java) { MediaCompanions.parse(active, source) }
        } finally {
            factory.block()
        }
    }

    @Test fun `moving one account between same-origin instance paths fences its old source`() {
        val origin = "https://path-fixture.example"
        val old = account(11, origin, "/a")
        val replacement = account(11, origin, "/b")
        MediaCompanionGrants.update(old)
        val previous = MediaCompanions.parse(old, source)
        val factory = PolicyCallFactory()
        try {
            factory.configure(ProxyPolicy())
            val request = Request.Builder().url(source).build()
            val oldCall = factory.forSource(source, emptySet(), companions = previous).newCall(request)
            val affected = MediaCompanionGrants.update(mapOf("accounts" to listOf(revoked(old), replacement)))
            assertEquals(2, affected.size)
            val newPolicy = MediaCompanions.parse(replacement, source)
            assertEquals(previous.gateway, newPolicy.gateway)
            val newCall = factory.forSource(source, emptySet(), companions = newPolicy).newCall(request)
            factory.cancelRevokedCompanionCalls(affected)
            assertTrue(oldCall.isCanceled())
            assertFalse(newCall.isCanceled())
            assertThrows(IOException::class.java) { factory.forSource(source, emptySet(), companions = previous) }
            assertThrows(IOException::class.java) { MediaCompanions.parse(old, source) }
        } finally {
            factory.block()
        }
    }

    @Test fun `a malformed batch applies no preceding or following account updates`() {
        val origin = "https://rollback-fixture.example"
        val a = account(21, origin)
        val b = account(22, origin)
        MediaCompanionGrants.update(a)
        MediaCompanionGrants.update(revoked(b))
        val invalid = account(23, origin) + ("origins" to listOf("http://bad.example"))
        assertThrows(IllegalArgumentException::class.java) {
            MediaCompanionGrants.update(mapOf("accounts" to listOf(revoked(a), invalid, b)))
        }
        MediaCompanions.parse(a, source)
        assertThrows(IOException::class.java) { MediaCompanions.parse(b, source) }
    }
}
