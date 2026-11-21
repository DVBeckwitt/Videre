package com.github.dvbeckwitt.videre.proxy

import java.io.IOException
import java.net.Proxy
import java.net.ProxySelector
import java.net.SocketAddress
import java.net.URI
import okhttp3.HttpUrl.Companion.toHttpUrl
import okhttp3.OkHttpClient
import okhttp3.Protocol
import okhttp3.Request
import okhttp3.Response
import okhttp3.ResponseBody.Companion.toResponseBody
import okio.ByteString.Companion.encodeUtf8
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertThrows
import org.junit.Assert.assertTrue
import org.junit.Test

class MediaCompanionsTest {
    private val instance = "https://instance.example"
    private val companion = "https://media.example:8443"
    private val manifest = "$instance/manifest.mpd"
    private fun context(origin: String) =
        "v1.11111111-1111-5111-8111-111111111111.${origin.encodeUtf8().base64Url()}"

    private fun policy(origins: List<String> = listOf(companion), source: String = manifest) =
        MediaCompanions.parse(mapOf(
            "origin" to instance, "origins" to origins, "gatewayContext" to context(instance),
        ), source)

    @Test
    fun `a media grant matches the exact HTTPS authority`() {
        val policy = policy()
        assertTrue(policy.permitsCompanion("$companion/segment?id=1".toHttpUrl()))
        for (target in listOf("http://media.example:8443", "https://media.example",
            "https://other.media.example:8443", "https://media.example.attacker.test:8443",
            "https://user@media.example:8443", "https://media.example.:8443")) {
            assertFalse(target, policy.permitsCompanion(target.toHttpUrl()))
        }
        policy(source = "$companion/playlist.m3u8")
        assertThrows(IllegalArgumentException::class.java) { policy(source = "https://other.example/source") }
    }

    @Test
    fun `untrusted and malformed settings never grant an extra destination`() {
        for (url in listOf("http://media.example", "https://*.example", "https://user@media.example",
            "https://media.example/path", "https://media.example?debug", "https://media.example#token",
            "https://media.example:65536", "https://media.example.", "https://127.0.0.1",
            "https://[::1]", "https://10.0.0.1", "https://localhost", "https://host.local",
            "https://host.onion", "https://redirect.googlevideo.com", "https://youtube.com")) {
            assertThrows(url, IllegalArgumentException::class.java) { policy(listOf(companion, url)) }
        }
        for (origin in listOf("http://instance.example", "https://hidden.onion", "https://127.0.0.1")) {
            assertThrows(origin, IllegalArgumentException::class.java) {
                MediaCompanions.parse(mapOf(
                    "origin" to origin, "origins" to listOf(companion), "gatewayContext" to context(origin),
                ), "$origin/manifest")
            }
        }
        for (marker in listOf(null, "bad", context("https://unrelated.example"))) {
            assertThrows(IllegalArgumentException::class.java) {
                MediaCompanions.parse(mapOf(
                    "origin" to instance, "origins" to listOf(companion), "gatewayContext" to marker,
                ), manifest)
            }
        }
        assertThrows(IllegalArgumentException::class.java) { policy((1..9).map { "https://companion$it.example" }) }
    }

    @Test
    fun `an independent media child needs a local source grant before route lookup`() {
        val previous = ProxySelector.getDefault()
        val routes = mutableListOf<String>()
        ProxySelector.setDefault(object : ProxySelector() {
            override fun select(uri: URI): List<Proxy> {
                routes.add(uri.host)
                throw IOException("Reached recording proxy selector")
            }
            override fun connectFailed(uri: URI?, address: SocketAddress?, error: IOException?) = Unit
        })
        val factory = PolicyCallFactory()
        try {
            factory.configure(ProxyPolicy())
            val child = Request.Builder().url("$companion/segment").build()
            val strict = factory.forSource(manifest, emptySet())
            val granted = factory.forSource(manifest, emptySet(), companions = policy())
            assertThrows(SelectedOriginBlocked::class.java) { strict.newCall(child).execute() }
            val unexpected = child.newBuilder().url("https://other.example/segment").build()
            assertThrows(SelectedOriginBlocked::class.java) { granted.newCall(unexpected).execute() }
            assertTrue(routes.isEmpty())
            val admitted = assertThrows(IOException::class.java) { granted.newCall(child).execute() }
            assertEquals("Reached recording proxy selector", admitted.message)
            assertEquals(listOf("media.example"), routes)
        } finally {
            factory.block()
            ProxySelector.setDefault(previous)
        }
    }

    // Run the production redirect guard against controlled responses. No redirect
    // destination is dialled by this interceptor fixture.
    private fun redirectCode(request: Request, destination: String): Int {
        val client = OkHttpClient.Builder()
            .addInterceptor(SelectedOriginRedirectGuard())
            .addInterceptor { chain ->
                Response.Builder().request(chain.request()).protocol(Protocol.HTTP_1_1)
                    .code(302).message("Found").header("Location", destination)
                    .body("".toResponseBody()).build()
            }.build()
        return client.newCall(request).execute().use { it.code }
    }

    @Test
    fun `a media grant permits a companion redirect while scoped APIs and third hosts stay restricted`() {
        val factory = PolicyCallFactory()
        try {
            factory.configure(ProxyPolicy())
            val initial = Request.Builder().url(manifest).build()
            val grant = factory.forSource(manifest, emptySet(), companions = policy())
            assertEquals(302, redirectCode(grant.newCall(initial).request(), "$companion/stream"))
            val child = initial.newBuilder().url("$companion/segment").build()
            assertThrows(SelectedOriginBlocked::class.java) {
                redirectCode(grant.newCall(child).request(), "https://third.example/segment")
            }
            val api = factory.newApiCall(initial, ApiRedirectOptions(sameOriginOnly = true))
            assertThrows(SelectedOriginBlocked::class.java) { redirectCode(api.request(), "$companion/stream") }
            val reused = factory.newApiCall(grant.newCall(initial).request(), ApiRedirectOptions(sameOriginOnly = true))
            assertThrows(SelectedOriginBlocked::class.java) { redirectCode(reused.request(), "$companion/stream") }
        } finally {
            factory.block()
        }
    }

    @Test
    fun `companion requests discard instance and caller credentials while preserving the media range`() {
        val policy = policy()
        val names = listOf("Authorization", "Cookie", "Proxy-Authorization", NERDVPN_KEY_HEADER,
            GATEWAY_CONTEXT_HEADER, INSTANCE_ORIGIN_HEADER, "X-Private-Header", "Referer")
        val request = Request.Builder().url("$companion/segment?signed=fixture")
            .header("Host", "private.example").header("User-Agent", "fixture-account")
            .header("Accept-Encoding", "fixture-account")
            .header("Range", "bytes=1024-2047").apply {
                names.forEach { header(it, "fixture") }
            }.build()
        val outgoing = policy.prepareRequest(request, setOf("x-private-header"))
        for (name in names) assertNull(name, outgoing.header(name))
        assertEquals("bytes=1024-2047", outgoing.header("Range"))
        assertEquals("media.example:8443", outgoing.header("Host"))
        assertEquals("Videre", outgoing.header("User-Agent"))
        assertEquals("identity", outgoing.header("Accept-Encoding"))
        assertEquals(request.url, outgoing.url)

        // Even a well-formed Range is an instance credential when supplied in
        // the account header settings. A transport range must be a single value.
        assertNull(policy.prepareRequest(request, setOf("rAnGe")).header("Range"))
        for (modified in listOf(
            request.newBuilder().header("Range", "fixture-account").build(),
            request.newBuilder().addHeader("Range", "bytes=1-2").build(),
        )) assertNull(policy.prepareRequest(modified, emptySet()).header("Range"))
    }
}
