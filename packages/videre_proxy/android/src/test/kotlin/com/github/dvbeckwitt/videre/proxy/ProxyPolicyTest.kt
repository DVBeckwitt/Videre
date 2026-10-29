package com.github.dvbeckwitt.videre.proxy

import java.io.DataInputStream
import java.io.IOException
import java.net.InetAddress
import java.net.InetSocketAddress
import java.net.Proxy
import java.net.ServerSocket
import java.net.Socket
import java.net.URI
import java.util.concurrent.CountDownLatch
import java.util.concurrent.Executors
import java.util.concurrent.Future
import java.util.concurrent.TimeUnit
import okhttp3.Request
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertThrows
import org.junit.Assert.assertTrue
import org.junit.Test

class ProxyPolicyTest {
    @Test
    fun `Orbot defaults are disabled until chosen`() {
        val defaults = ProxyPolicy()
        assertFalse(defaults.enabled)
        assertEquals("127.0.0.1", defaults.host)
        assertEquals(9050, defaults.port)
        assertEquals(defaults, ProxyPolicy.fromMap(defaults.toMap()))
    }

    @Test
    fun `invalid enabled settings are rejected`() {
        listOf("", " ", "socks5://127.0.0.1", "host/path", "host@other").forEach { host ->
            assertThrows(IllegalArgumentException::class.java) { ProxyPolicy(true, host, 9050) }
        }
        listOf(0, -1, 65536).forEach { port ->
            assertThrows(IllegalArgumentException::class.java) { ProxyPolicy(true, "127.0.0.1", port) }
        }
        assertThrows(IllegalArgumentException::class.java) {
            ProxyPolicy.fromMap(mapOf("enabled" to true, "host" to "127.0.0.1", "port" to 9050.5))
        }
    }

    @Test
    fun `only literal loopback bypasses SOCKS`() {
        val selector = SocksOnlySelector(ProxyPolicy(true))
        listOf("http://localhost/a", "http://127.0.0.1/a", "http://127.7.8.9/a", "http://[::1]/a").forEach {
            assertEquals(listOf(Proxy.NO_PROXY), selector.select(URI(it)))
        }
        listOf("https://media.example/a", "http://192.168.1.4/a", "http://localhost.evil/a", "http://[::2]/a").forEach {
            val proxies = selector.select(URI(it))
            assertEquals(1, proxies.size)
            assertEquals(Proxy.Type.SOCKS, proxies.single().type())
            assertEquals(9050, (proxies.single().address() as InetSocketAddress).port)
        }
    }

    @Test
    fun `uninitialized or blocked transport never creates a direct call`() {
        val factory = PolicyCallFactory()
        val request = Request.Builder().url("https://media.example.invalid/video").build()
        assertThrows(IOException::class.java) { factory.newCall(request) }
        factory.configure(ProxyPolicy())
        factory.block()
        assertThrows(IOException::class.java) { factory.newCall(request) }
    }

    @Test
    fun `native SOCKS sends unresolved destination and reads HTTP through tunnel`() {
        FakeSocks().use { proxy ->
            val served = proxy.serve { input, socket ->
                val target = readConnect(input, socket)
                assertEquals("unresolvable-media.example.invalid", target.first)
                assertEquals(8123, target.second)
                readHeaders(input)
                socket.getOutputStream().write("HTTP/1.1 200 OK\r\nContent-Length: 5\r\nConnection: close\r\n\r\nvideo".toByteArray())
            }
            val factory = PolicyCallFactory()
            factory.configure(ProxyPolicy(true, "127.0.0.1", proxy.port))
            factory.newCall(Request.Builder().url("http://unresolvable-media.example.invalid:8123/video").build())
                .execute().use { assertEquals("video", it.body!!.string()) }
            served.get(10, TimeUnit.SECONDS)
            factory.block()
        }
    }

    @Test
    fun `redirect from internal audio proxy still routes external media through SOCKS`() {
        FakeSocks().use { proxy ->
            ServerSocket(0, 1, InetAddress.getLoopbackAddress()).use { local ->
                val worker = Executors.newSingleThreadExecutor()
                try {
                    val redirect = worker.submit {
                        local.accept().use { socket ->
                            socket.soTimeout = 5000
                            readHeaders(DataInputStream(socket.getInputStream()))
                            socket.getOutputStream().write(("HTTP/1.1 302 Found\r\n" +
                                "Location: http://redirected-media.example.invalid/video\r\n" +
                                "Content-Length: 0\r\nConnection: close\r\n\r\n").toByteArray())
                        }
                    }
                    val served = proxy.serve { input, socket ->
                        assertEquals("redirected-media.example.invalid", readConnect(input, socket).first)
                        readHeaders(input)
                        socket.getOutputStream().write("HTTP/1.1 200 OK\r\nContent-Length: 2\r\nConnection: close\r\n\r\nok".toByteArray())
                    }
                    val factory = PolicyCallFactory()
                    factory.configure(ProxyPolicy(true, "127.0.0.1", proxy.port))
                    factory.newCall(Request.Builder().url("http://127.0.0.1:${local.localPort}/audio").build())
                        .execute().use { assertEquals("ok", it.body!!.string()) }
                    redirect.get(10, TimeUnit.SECONDS)
                    served.get(10, TimeUnit.SECONDS)
                    factory.block()
                } finally {
                    worker.shutdownNow()
                }
            }
        }
    }

    @Test
    fun `changing settings cancels an already opened media response body`() {
        FakeSocks().use { proxy ->
            val release = CountDownLatch(1)
            val served = proxy.serve { input, socket ->
                readConnect(input, socket)
                readHeaders(input)
                socket.getOutputStream().write("HTTP/1.1 200 OK\r\nContent-Length: 100\r\n\r\nx".toByteArray())
                socket.getOutputStream().flush()
                release.await(10, TimeUnit.SECONDS)
            }
            val factory = PolicyCallFactory()
            factory.configure(ProxyPolicy(true, "127.0.0.1", proxy.port))
            try {
                factory.newCall(Request.Builder().url("http://stream.example.invalid/video").build()).execute().use {
                    assertEquals('x'.code.toByte(), it.body!!.source().readByte())
                    factory.configure(ProxyPolicy())
                    assertThrows(IOException::class.java) { it.body!!.source().readByte() }
                }
            } finally {
                release.countDown()
                served.get(10, TimeUnit.SECONDS)
                factory.block()
            }
        }
    }

    @Test
    fun `a call created before a settings change cannot connect afterward`() {
        val factory = PolicyCallFactory()
        factory.configure(ProxyPolicy())
        val call = factory.newCall(Request.Builder().url("http://unresolvable.example.invalid/").build())
        factory.configure(ProxyPolicy(true))
        assertTrue(call.isCanceled())
        assertThrows(IOException::class.java) { call.execute() }
        factory.block()
    }

    @Test
    fun `verified onion media refuses a changed proxy before creating calls`() {
        val factory = PolicyCallFactory()
        val original = ProxyPolicy(true, "127.0.0.1", 9050)
        val sourceUrl = "http://${"a".repeat(56)}.onion/manifest.m3u8"
        val request = Request.Builder().url(sourceUrl).build()
        val headers = verifiedHeaders()
        factory.configure(original)
        try {
            val source = factory.forSource(sourceUrl, headers, original)
            val created = source.newCall(request)
            factory.configure(original.copy(port = 9150))
            assertTrue(created.isCanceled())
            assertThrows(IOException::class.java) { source.newCall(request) }
            assertThrows(IOException::class.java) { created.clone() }
            factory.configure(original.copy(enabled = false))
            assertThrows(IOException::class.java) { source.newCall(request) }
            assertThrows(IOException::class.java) { factory.forSource(sourceUrl, headers) }
            assertThrows(IOException::class.java) {
                factory.forSource(sourceUrl, headers, original.copy(enabled = false))
            }
        } finally {
            factory.block()
        }
    }

    @Test
    fun `verified onion media uses its unchanged SOCKS route`() {
        FakeSocks().use { proxy ->
            val host = "${"a".repeat(56)}.onion"
            val served = proxy.serve { input, socket ->
                assertEquals(host, readConnect(input, socket).first)
                readHeaders(input)
                socket.getOutputStream().write("HTTP/1.1 200 OK\r\nContent-Length: 2\r\nConnection: close\r\n\r\nok".toByteArray())
            }
            val factory = PolicyCallFactory()
            val policy = ProxyPolicy(true, "127.0.0.1", proxy.port)
            factory.configure(policy)
            try {
                val url = "http://$host/manifest.m3u8"
                val source = factory.forSource(url, verifiedHeaders(), policy)
                source.newCall(Request.Builder().url(url).build()).execute().use {
                    assertEquals("ok", it.body!!.string())
                }
                served.get(10, TimeUnit.SECONDS)
            } finally {
                factory.block()
            }
        }
    }

    @Test
    fun `ordinary sources retain the live proxy policy`() {
        val onion = "${"a".repeat(56)}.onion"
        listOf(
            "ordinary-media.example.invalid" to verifiedHeaders(),
            onion to mapOf("Cookie" to "sid=fake"),
            onion to verifiedHeaders().filterKeys { !it.equals("Cookie", ignoreCase = true) },
        ).forEach { (host, headers) ->
            FakeSocks().use { proxy ->
                val served = proxy.serve { input, socket ->
                    assertEquals(host, readConnect(input, socket).first)
                    readHeaders(input)
                    socket.getOutputStream().write("HTTP/1.1 200 OK\r\nContent-Length: 2\r\nConnection: close\r\n\r\nok".toByteArray())
                }
                val factory = PolicyCallFactory()
                val original = ProxyPolicy()
                factory.configure(original)
                try {
                    val url = "http://$host/manifest.m3u8"
                    val source = factory.forSource(url, headers, original)
                    factory.configure(ProxyPolicy(true, "127.0.0.1", proxy.port))
                    source.newCall(Request.Builder().url(url).build()).execute().use {
                        assertEquals("ok", it.body!!.string())
                    }
                    served.get(10, TimeUnit.SECONDS)
                } finally {
                    factory.block()
                }
            }
        }
    }

    private fun verifiedHeaders(): Map<String, String> = mapOf(
        "cookie" to "verification=fake",
        "USER-AGENT" to "Test browser",
        "Accept" to "application/json",
        "Accept-Language" to "en-US",
        "Accept-Encoding" to "identity",
    )

    private class FakeSocks : AutoCloseable {
        private val listener = ServerSocket(0, 1, InetAddress.getByName("127.0.0.1"))
        private val worker = Executors.newSingleThreadExecutor()
        val port: Int get() = listener.localPort

        fun serve(handler: (DataInputStream, Socket) -> Unit): Future<*> = worker.submit {
            listener.soTimeout = 5000
            listener.accept().use { socket ->
                socket.soTimeout = 5000
                handler(DataInputStream(socket.getInputStream()), socket)
            }
        }

        override fun close() {
            listener.close()
            worker.shutdownNow()
        }
    }

    companion object {
        private fun readConnect(input: DataInputStream, socket: Socket): Pair<String, Int> {
            assertEquals(5, input.readUnsignedByte())
            val methods = ByteArray(input.readUnsignedByte())
            input.readFully(methods)
            assertTrue(methods.contains(0.toByte()))
            // Send fragmented replies to cover clients' TCP stream handling.
            socket.getOutputStream().write(byteArrayOf(5))
            socket.getOutputStream().write(byteArrayOf(0))
            assertEquals(5, input.readUnsignedByte())
            assertEquals(1, input.readUnsignedByte())
            assertEquals(0, input.readUnsignedByte())
            assertEquals(3, input.readUnsignedByte())
            val hostname = ByteArray(input.readUnsignedByte())
            input.readFully(hostname)
            val port = input.readUnsignedShort()
            socket.getOutputStream().write(byteArrayOf(5, 0, 0, 1, 127, 0, 0, 1, 0, 0))
            return String(hostname, Charsets.UTF_8) to port
        }

        private fun readHeaders(input: DataInputStream) {
            var ending = 0
            val marker = byteArrayOf(13, 10, 13, 10)
            var count = 0
            while (ending < marker.size && count++ < 65536) {
                val byte = input.readByte()
                ending = if (byte == marker[ending]) ending + 1 else if (byte == marker[0]) 1 else 0
            }
            check(ending == marker.size) { "HTTP request headers exceeded test limit." }
        }
    }
}
