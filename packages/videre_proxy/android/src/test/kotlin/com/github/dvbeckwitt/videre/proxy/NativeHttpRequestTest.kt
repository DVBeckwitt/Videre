package com.github.dvbeckwitt.videre.proxy

import java.io.ByteArrayInputStream
import java.io.IOException
import java.io.InputStream
import java.net.InetAddress
import java.net.ServerSocket
import java.net.SocketTimeoutException
import java.util.concurrent.Executors
import java.util.concurrent.TimeUnit
import okhttp3.Protocol
import okhttp3.Request
import okhttp3.Response
import okhttp3.ResponseBody.Companion.toResponseBody
import org.junit.Assert.assertArrayEquals
import org.junit.Assert.assertEquals
import org.junit.Assert.assertThrows
import org.junit.Test

class NativeHttpRequestTest {
    @Test
    fun `onion worker proxy bindings validate their route and reject stale configurations`() {
        val proxy = ProxyPolicy(true, "127.0.0.1", 9050)
        val onion = Request.Builder().url("http://${"a".repeat(56)}.onion/api/v1/stats").build()
        val metadata = mapOf("expectedOnionProxy" to proxy.toMap())
        assertEquals(proxy, expectedOnionProxy(metadata, onion))
        assertEquals(null, expectedOnionProxy(emptyMap<Any, Any>(), onion))
        requireMatchingOnionProxy(proxy, proxy)
        requireMatchingOnionProxy(null, ProxyPolicy(false))
        for (changed in listOf(null, ProxyPolicy(false), proxy.copy(port = 9150), proxy.copy(host = "localhost"))) {
            assertThrows(IOException::class.java) { requireMatchingOnionProxy(proxy, changed) }
        }
        for (invalid in listOf(null, "proxy", mapOf("enabled" to true), proxy.toMap() + ("extra" to true))) {
            assertThrows(IllegalArgumentException::class.java) {
                expectedOnionProxy(mapOf("expectedOnionProxy" to invalid), onion)
            }
        }
        val ordinary = Request.Builder().url("https://instance.example/api/v1/stats").build()
        assertThrows(IllegalArgumentException::class.java) { expectedOnionProxy(metadata, ordinary) }
    }

    @Test
    fun `request accepts HTTP headers and body bytes`() {
        val request = buildApiRequest(mapOf(
            "method" to "POST",
            "url" to "https://instance.example/api/v1/auth/subscriptions",
            "headers" to mapOf("Content-Type" to "application/json"),
            "body" to "{}".toByteArray(),
        ))
        assertEquals("POST", request.method)
        assertEquals("application/json", request.header("Content-Type"))
        assertEquals(2L, request.body!!.contentLength())
    }

    @Test
    fun `non HTTP URLs invalid headers and oversized request bodies are rejected`() {
        listOf("file:///secret", "ftp://instance.example/a", "not a URL").forEach {
            assertThrows(IllegalArgumentException::class.java) {
                buildApiRequest(mapOf("method" to "GET", "url" to it))
            }
        }
        assertThrows(IllegalArgumentException::class.java) {
            buildApiRequest(mapOf("method" to "GET", "url" to "http://localhost", "headers" to mapOf("a\r\nb" to "value")))
        }
        assertThrows(IllegalArgumentException::class.java) {
            buildApiRequest(mapOf("method" to "POST", "url" to "http://localhost", "body" to ByteArray(MAX_API_BODY_BYTES + 1)))
        }
    }

    @Test
    fun `streaming responses are capped even without Content-Length`() {
        val bytes = ByteArray(MAX_API_BODY_BYTES + 1)
        assertThrows(ApiBodyTooLarge::class.java) {
            readLimitedApiBody(ByteArrayInputStream(bytes), -1)
        }
        assertThrows(ApiBodyTooLarge::class.java) {
            readLimitedApiBody(ByteArrayInputStream(ByteArray(0)), bytes.size.toLong())
        }
        assertEquals(MAX_API_BODY_BYTES, readLimitedApiBody(ByteArrayInputStream(bytes.copyOf(MAX_API_BODY_BYTES)), -1).size)
    }

    @Test
    fun `read errors propagate instead of returning partial JSON`() {
        val broken = object : InputStream() {
            override fun read(): Int = throw IOException("Test read error")
        }
        assertThrows(IOException::class.java) { readLimitedApiBody(broken, -1) }
    }

    @Test
    fun `redirect options validate their native transport limit`() {
        assertEquals(ApiRedirectOptions(), ApiRedirectOptions.fromMap(emptyMap<Any, Any>()))
        assertEquals(ApiRedirectOptions(false, 0), ApiRedirectOptions.fromMap(mapOf("followRedirects" to false, "maxRedirects" to 0)))
        listOf(-1, 21, 1.5, "5").forEach { max ->
            assertThrows(IllegalArgumentException::class.java) {
                ApiRedirectOptions.fromMap(mapOf("maxRedirects" to max))
            }
        }
    }

    @Test
    fun `worker can return redirects or stop before exceeding requested redirect limit`() {
        listOf(false, true).forEach { follow ->
            ServerSocket(0, 1, InetAddress.getByName("127.0.0.1")).use { listener ->
                val executor = Executors.newSingleThreadExecutor()
                val served = executor.submit {
                    listener.soTimeout = 5000
                    listener.accept().use { socket ->
                        socket.soTimeout = 5000
                        val input = socket.getInputStream()
                        var ending = 0
                        val marker = byteArrayOf(13, 10, 13, 10)
                        while (ending < 4) {
                            val byte = input.read()
                            check(byte >= 0)
                            ending = if (byte == marker[ending].toInt()) ending + 1 else 0
                        }
                        socket.getOutputStream().write(("HTTP/1.1 302 Found\r\nLocation: http://127.0.0.1:${listener.localPort}/next\r\n" +
                            "Content-Length: 0\r\nConnection: close\r\n\r\n").toByteArray())
                    }
                    listener.soTimeout = 300
                    assertThrows(SocketTimeoutException::class.java) { listener.accept().close() }
                }
                val factory = PolicyCallFactory()
                factory.configure(ProxyPolicy())
                try {
                    val request = Request.Builder().url("http://127.0.0.1:${listener.localPort}/first").build()
                    val call = factory.newApiCall(request, ApiRedirectOptions(follow, 0))
                    if (follow) assertThrows(IOException::class.java) { call.execute() }
                    else call.execute().use { assertEquals(302, it.code) }
                    served.get(10, TimeUnit.SECONDS)
                } finally {
                    factory.block()
                    executor.shutdownNow()
                }
            }
        }
    }

    @Test
    fun `worker retains same-origin session headers and strips them across origins`() {
        checkRedirectHeaders(useWorkerBridge = true)
    }

    @Test
    fun `worker confines custom instance credentials to their original origin`() {
        checkRedirectHeaders(useWorkerBridge = true, includeCustomCredentials = true)
    }

    @Test
    fun `media retains same-origin session headers and strips them across origins`() {
        checkRedirectHeaders(useWorkerBridge = false)
    }

    @Test
    fun `manifest header scope survives independent child calls and redirects`() {
        ServerSocket(0, 5, InetAddress.getByName("127.0.0.1")).use { listener ->
            val executor = Executors.newSingleThreadExecutor()
            val served = executor.submit<List<Map<String, String>>> {
                listener.soTimeout = 5000
                (0..4).map { index ->
                    listener.accept().use { socket ->
                        socket.soTimeout = 5000
                        val headers = captureHeaders(socket.getInputStream())
                        val response = if (index == 3) {
                            "HTTP/1.1 302 Found\r\nLocation: http://127.0.0.1:${listener.localPort}/redirected-segment\r\n"
                        } else {
                            "HTTP/1.1 200 OK\r\n"
                        }
                        socket.getOutputStream().write((response +
                            "Content-Length: 0\r\nConnection: close\r\n\r\n").toByteArray())
                        headers
                    }
                }
            }
            val factory = PolicyCallFactory()
            factory.configure(ProxyPolicy())
            try {
                val origin = "http://localhost:${listener.localPort}"
                val configured = setOf("Authorization", "Cookie", "X-Instance-Key")
                val source = factory.forSource("$origin/manifest.mpd", configured)
                listOf(
                    "$origin/manifest.mpd",
                    "$origin/same-origin-segment",
                    "http://127.0.0.1:${listener.localPort}/external-segment",
                    "$origin/redirect",
                ).forEach { url ->
                    val request = Request.Builder().url(url)
                        .header("Authorization", "instance-secret")
                        .header("Cookie", "session=secret")
                        .header("X-Instance-Key", "custom-secret")
                        // Added by Media3 for the individual data request, not
                        // inherited from the source's configured headers.
                        .header("Range", "bytes=100-199")
                        .build()
                    source.newCall(request).execute().use { assertEquals(200, it.code) }
                }
                val captured = served.get(10, TimeUnit.SECONDS)
                captured.forEachIndexed { index, headers ->
                    val sameOrigin = index in setOf(0, 1, 3)
                    assertEquals(if (sameOrigin) "instance-secret" else null, headers["authorization"])
                    assertEquals(if (sameOrigin) "session=secret" else null, headers["cookie"])
                    assertEquals(if (sameOrigin) "custom-secret" else null, headers["x-instance-key"])
                    assertEquals("bytes=100-199", headers["range"])
                }
            } finally {
                factory.block()
                executor.shutdownNow()
            }
        }
    }

    private fun checkRedirectHeaders(useWorkerBridge: Boolean, includeCustomCredentials: Boolean = false) {
        listOf(false, true).forEach { crossOrigin ->
            ServerSocket(0, 2, InetAddress.getByName("127.0.0.1")).use { listener ->
                val executor = Executors.newSingleThreadExecutor()
                val served = executor.submit<Pair<Map<String, String>, Map<String, String>>> {
                    listener.soTimeout = 5000
                    val original = listener.accept().use { socket ->
                        socket.soTimeout = 5000
                        val headers = captureHeaders(socket.getInputStream())
                        val host = if (crossOrigin) "localhost" else "127.0.0.1"
                        socket.getOutputStream().write(("HTTP/1.1 302 Found\r\nLocation: http://$host:${listener.localPort}/target\r\n" +
                            "Content-Length: 0\r\nConnection: close\r\n\r\n").toByteArray())
                        headers
                    }
                    val redirected = listener.accept().use { socket ->
                        socket.soTimeout = 5000
                        val headers = captureHeaders(socket.getInputStream())
                        socket.getOutputStream().write("HTTP/1.1 200 OK\r\nContent-Length: 0\r\nConnection: close\r\n\r\n".toByteArray())
                        headers
                    }
                    original to redirected
                }
                val factory = PolicyCallFactory()
                factory.configure(ProxyPolicy())
                try {
                    val sensitive = listOf("Authorization", "Proxy-Authorization", "Cookie", "Cookie2", "WWW-Authenticate") +
                        if (includeCustomCredentials) listOf("X-Instance-Key", "CF-Access-Client-Secret") else emptyList()
                    val builder = Request.Builder().url("http://127.0.0.1:${listener.localPort}/first")
                        .header("X-Marker", "kept")
                    sensitive.forEach { builder.header(it, "session-secret") }
                    val request = builder.build()
                    val call = if (useWorkerBridge) factory.newApiCall(request, ApiRedirectOptions()) else factory.newCall(request)
                    call.execute().use { assertEquals(200, it.code) }
                    val (original, redirected) = served.get(10, TimeUnit.SECONDS)
                    sensitive.forEach {
                        val name = it.lowercase(java.util.Locale.ROOT)
                        assertEquals("session-secret", original[name])
                        assertEquals(if (crossOrigin) null else "session-secret", redirected[name])
                    }
                    assertEquals(if (crossOrigin && useWorkerBridge) null else "kept", redirected["x-marker"])
                    // OkHttp-generated transport headers are not caller credentials.
                    assertEquals("gzip", redirected["accept-encoding"])
                } finally {
                    factory.block()
                    executor.shutdownNow()
                }
            }
        }
    }

    @Test
    fun `response returns HTTP error status headers and body without logging URLs`() {
        val response = Response.Builder()
            .request(Request.Builder().url("https://instance.example/api").build())
            .protocol(Protocol.HTTP_1_1)
            .code(503)
            .message("Service unavailable")
            .header("Content-Type", "application/json")
            .body("{\"error\":\"unavailable\"}".toResponseBody())
            .build()
        response.use {
            val value = readApiResponse(it)
            assertEquals(503, value["statusCode"])
            assertEquals(mapOf("content-type" to "application/json"), value["headers"])
            assertArrayEquals("{\"error\":\"unavailable\"}".toByteArray(), value["body"] as ByteArray)
        }
    }

    private fun captureHeaders(input: InputStream): Map<String, String> {
        val reader = input.bufferedReader(Charsets.ISO_8859_1)
        check(reader.readLine().startsWith("GET "))
        val headers = mutableMapOf<String, String>()
        while (true) {
            val line = reader.readLine() ?: throw IOException("Truncated test HTTP headers")
            if (line.isEmpty()) return headers
            val separator = line.indexOf(':')
            check(separator > 0)
            headers[line.substring(0, separator).lowercase(java.util.Locale.ROOT)] = line.substring(separator + 1).trim()
        }
    }
}
