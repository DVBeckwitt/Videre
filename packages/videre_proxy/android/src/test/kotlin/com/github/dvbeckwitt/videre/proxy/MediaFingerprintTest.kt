package com.github.dvbeckwitt.videre.proxy

import java.io.IOException
import java.net.InetAddress
import java.net.ServerSocket
import java.net.Socket
import java.util.Locale
import java.util.concurrent.Executors
import java.util.concurrent.TimeUnit
import okhttp3.Request
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertThrows
import org.junit.Test

class MediaFingerprintTest {
    @Test
    fun `media defaults cannot duplicate the verified fingerprint or restore it off origin`() {
        ServerSocket(0, 2, InetAddress.getByName("127.0.0.1")).use { origin ->
            ServerSocket(0, 1, InetAddress.getByName("127.0.0.1")).use { other ->
                origin.soTimeout = 5000
                other.soTimeout = 5000
                val workers = Executors.newFixedThreadPool(2)
                val factory = PolicyCallFactory()
                factory.configure(ProxyPolicy())
                try {
                    val originalHeaders = workers.submit<List<Map<String, List<String>>>> {
                        listOf(
                            origin.accept().use { socket ->
                                capture(socket).also {
                                    respond(socket, "302 Found", "Location: http://127.0.0.1:${other.localPort}/child\r\n")
                                }
                            },
                            origin.accept().use { socket -> capture(socket).also { respond(socket) } },
                        )
                    }
                    val otherHeaders = workers.submit<Map<String, List<String>>> {
                        other.accept().use { socket -> capture(socket).also { respond(socket) } }
                    }
                    val sourceUrl = "http://127.0.0.1:${origin.localPort}/manifest.mpd"
                    val fingerprint = linkedMapOf(
                        "user-agent" to "verified-browser",
                        "accept" to "verified-accept",
                        "accept-language" to "en-US,en;q=0.9",
                        "accept-encoding" to "identity",
                    )
                    val configured = fingerprint + mapOf("Cookie" to "verified=test-only")
                    val source = factory.forSource(sourceUrl, configured)
                    fun mediaRequest(path: String): Request = Request.Builder()
                        .url("http://127.0.0.1:${origin.localPort}/$path")
                        .apply {
                            configured.forEach { (name, value) -> header(name, value) }
                            // Match Media3's appends after default request headers.
                            addHeader("User-Agent", "media-default")
                            addHeader("Accept-Encoding", "identity")
                            header("Range", "bytes=10-19")
                        }.build()
                    source.newCall(mediaRequest("manifest.mpd")).execute().use { assertEquals(200, it.code) }
                    source.newCall(mediaRequest("segment")).execute().use { assertEquals(200, it.code) }

                    originalHeaders.get(10, TimeUnit.SECONDS).forEach { headers ->
                        fingerprint.forEach { (name, value) -> assertEquals(listOf(value), headers[name]) }
                        assertEquals(listOf("verified=test-only"), headers["cookie"])
                        assertEquals(listOf("bytes=10-19"), headers["range"])
                    }
                    val redirected = otherHeaders.get(10, TimeUnit.SECONDS)
                    (fingerprint.keys + "cookie").forEach { assertFalse(redirected.containsKey(it)) }
                    assertEquals(listOf("bytes=10-19"), redirected["range"])
                } finally {
                    factory.block()
                    workers.shutdownNow()
                }
            }
        }
    }

    @Test
    fun `conflicting fingerprint fields are rejected instead of choosing a value`() {
        val factory = PolicyCallFactory()
        assertThrows(IllegalArgumentException::class.java) {
            factory.forSource("http://127.0.0.1/", mapOf("User-Agent" to "one", "user-agent" to "two"))
        }
    }

    private fun capture(socket: Socket): Map<String, List<String>> {
        socket.soTimeout = 5000
        val input = socket.getInputStream().bufferedReader(Charsets.ISO_8859_1)
        input.readLine() ?: throw IOException("Missing test request")
        val result = linkedMapOf<String, MutableList<String>>()
        repeat(100) {
            val line = input.readLine() ?: throw IOException("Truncated test request")
            if (line.isEmpty()) return result
            val separator = line.indexOf(':')
            check(separator > 0)
            result.getOrPut(line.substring(0, separator).lowercase(Locale.ROOT)) { mutableListOf() }
                .add(line.substring(separator + 1).trim())
        }
        throw IOException("Too many test headers")
    }

    private fun respond(socket: Socket, status: String = "200 OK", headers: String = "") {
        socket.getOutputStream().write(
            ("HTTP/1.1 $status\r\n${headers}Content-Length: 0\r\nConnection: close\r\n\r\n")
                .toByteArray(Charsets.ISO_8859_1),
        )
    }
}
