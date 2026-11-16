package com.github.dvbeckwitt.videre.proxy

import java.io.DataInputStream
import java.io.IOException
import java.net.InetAddress
import java.net.Proxy
import java.net.ProxySelector
import java.net.ServerSocket
import java.net.Socket
import java.net.SocketAddress
import java.net.URI
import java.util.Locale
import java.util.concurrent.Executors
import java.util.concurrent.TimeUnit
import okhttp3.Request
import okhttp3.HttpUrl.Companion.toHttpUrl
import org.junit.Assert.*
import org.junit.Test

class PodcastPrivacyTest {
    @Test
    fun `podcast URL policy rejects Google YouTube FeedBurner credentials and fragments`() {
        val factory = PolicyCallFactory()
        for (url in listOf("https://music.youtube.com/audio", "https://www.google.co.uk/audio",
            "https://www.googleapis.com/audio", "https://rr1.googlevideo.com/audio",
            "https://feeds.feedburner.com/audio", "https://FEEDBURNER.COM./audio", "https://feeds\u3002feedburner.com/audio",
            "https://publisher.example/audio#fragment", "https://user:secret@publisher.example/audio",
            "https://publisher.example/" + "a".repeat(4096), "file:///audio.mp3")) {
            assertThrows(url, PodcastConnectionBlocked::class.java) { factory.forPodcastSource(url) }
        }
        for (url in listOf("https://publisher.example/audio", "http://publisher.example/audio",
            "https://feedburner.com.publisher.example/audio", "https://notyoutube.com/audio")) {
            requirePodcastUrl(url.toHttpUrl())
        }
    }

    @Test
    fun `podcast requests strip account headers and gateway context before transport`() {
        val factory = PolicyCallFactory()
        factory.configure(ProxyPolicy())
        try {
            val source = factory.forPodcastSource("https://publisher.example/audio")
            val request = Request.Builder().url("https://publisher.example/audio")
                .header("Authorization", "not-forwarded").header("Cookie", "not-forwarded")
                .header("Proxy-Authorization", "not-forwarded").header("Cookie2", "not-forwarded")
                .header(NERDVPN_KEY_HEADER, "not-forwarded")
                .header(GATEWAY_CONTEXT_HEADER, "invalid-account-context")
                .header(INSTANCE_ORIGIN_HEADER, "invalid-instance-origin")
                .header("Range", "bytes=100-")
                .tag(GatewayRequestScope::class.java,
                    GatewayRequestScope(GatewayContext("test-account", "https://publisher.example".toHttpUrl())))
                .tag(SelectedOriginScope::class.java, SelectedOriginScope("https://instance.example".toHttpUrl()))
                .build()
            val prepared = source.newCall(request).request()
            for (name in listOf("Authorization", "Proxy-Authorization", "Cookie", "Cookie2",
                NERDVPN_KEY_HEADER, GATEWAY_CONTEXT_HEADER, INSTANCE_ORIGIN_HEADER)) assertNull(prepared.header(name))
            assertNull(prepared.tag(GatewayRequestScope::class.java))
            assertNull(prepared.tag(SelectedOriginScope::class.java))
            assertNotNull(prepared.tag(PodcastSourceScope::class.java))
            assertEquals("bytes=100-", prepared.header("Range"))
        } finally {
            factory.block()
        }
    }

    @Test
    fun `publisher redirects can change origin while preserving media range`() {
        val worker = Executors.newFixedThreadPool(2)
        val factory = PolicyCallFactory()
        try {
            localServer().use { first ->
                localServer().use { second ->
                    val initial = worker.submit<Map<String, String>> {
                        first.accept().use { socket ->
                            val headers = readHeaders(socket)
                            respond(socket, 302, "Location: http://127.0.0.1:${second.localPort}/episode\r\n")
                            headers
                        }
                    }
                    val redirected = worker.submit<Map<String, String>> {
                        second.accept().use { socket ->
                            val headers = readHeaders(socket)
                            respond(socket, 206, "Content-Range: bytes 100-104/105\r\n", "audio")
                            headers
                        }
                    }
                    factory.configure(ProxyPolicy())
                    val url = "http://127.0.0.1:${first.localPort}/episode"
                    factory.forPodcastSource(url).newCall(Request.Builder().url(url)
                        .header("Range", "bytes=100-").header("Cookie", "not-forwarded").build())
                        .execute().use { response ->
                            assertEquals(206, response.code)
                            assertEquals("audio", response.body!!.string())
                        }
                    for (headers in listOf(initial.get(10, TimeUnit.SECONDS), redirected.get(10, TimeUnit.SECONDS))) {
                        assertEquals("bytes=100-", headers["range"])
                        assertNull(headers["cookie"])
                    }
                }
            }
        } finally {
            factory.block()
            worker.shutdownNow()
        }
    }

    @Test
    fun `forbidden podcast requests and redirects are blocked before foreign routing`() {
        val previous = ProxySelector.getDefault()
        var foreignRoutes = 0
        ProxySelector.setDefault(object : ProxySelector() {
            override fun select(uri: URI): List<Proxy> {
                if (uri.host != "127.0.0.1") {
                    foreignRoutes++
                    throw IOException("Unexpected foreign route lookup")
                }
                return listOf(Proxy.NO_PROXY)
            }
            override fun connectFailed(uri: URI?, address: SocketAddress?, error: IOException?) = Unit
        })
        val worker = Executors.newSingleThreadExecutor()
        val factory = PolicyCallFactory()
        try {
            for (policy in listOf(ProxyPolicy(), ProxyPolicy(true))) {
                factory.configure(policy)
                for (target in listOf("https://feeds.feedburner.com/audio", "https://music.youtube.com/audio",
                    "https://www.googleapis.com/audio", "https://user:secret@publisher.example/audio")) {
                    val source = factory.forPodcastSource("https://publisher.example/audio")
                    assertThrows(PodcastConnectionBlocked::class.java) {
                        source.newCall(Request.Builder().url(target).build()).execute()
                    }
                    localServer().use { local ->
                        val served = worker.submit {
                            local.accept().use { socket ->
                                readHeaders(socket)
                                respond(socket, 302, "Location: $target\r\n")
                            }
                        }
                        val url = "http://127.0.0.1:${local.localPort}/episode"
                        assertThrows(IOException::class.java) {
                            factory.forPodcastSource(url).newCall(Request.Builder().url(url).build()).execute()
                        }
                        served.get(10, TimeUnit.SECONDS)
                    }
                }
            }
            assertEquals(0, foreignRoutes)
        } finally {
            factory.block()
            worker.shutdownNow()
            ProxySelector.setDefault(previous)
        }
    }

    @Test
    fun `HTTP headers cannot enable podcast routing for existing media sources`() {
        val factory = PolicyCallFactory()
        factory.configure(ProxyPolicy())
        try {
            val source = factory.forSource("https://instance.example/audio", emptySet())
            assertThrows(SelectedOriginBlocked::class.java) {
                source.newCall(Request.Builder().url("https://publisher.example/audio")
                    .header("X-Videre-Podcast-Source", "1").build()).execute()
            }
        } finally {
            factory.block()
        }
    }

    @Test
    fun `publisher redirect keeps SOCKS routing and remote DNS`() {
        val worker = Executors.newSingleThreadExecutor()
        val factory = PolicyCallFactory()
        try {
            localServer().use { proxy ->
                val served = worker.submit<List<String>> {
                    (0..1).map { index ->
                        proxy.accept().use { socket ->
                            socket.soTimeout = 5000
                            val host = readSocksConnect(socket)
                            readHeaders(socket)
                            if (index == 0) respond(socket, 302,
                                "Location: http://cdn.publisher.invalid/episode\r\n")
                            else respond(socket, 200, body = "audio")
                            host
                        }
                    }
                }
                factory.configure(ProxyPolicy(true, "127.0.0.1", proxy.localPort))
                val url = "http://publisher.invalid/episode"
                factory.forPodcastSource(url).newCall(Request.Builder().url(url).build()).execute().use {
                    assertEquals("audio", it.body!!.string())
                }
                assertEquals(listOf("publisher.invalid", "cdn.publisher.invalid"), served.get(10, TimeUnit.SECONDS))
            }
        } finally {
            factory.block()
            worker.shutdownNow()
        }
    }

    private fun localServer() = ServerSocket(0, 2, InetAddress.getByName("127.0.0.1")).apply { soTimeout = 5000 }

    private fun readHeaders(socket: Socket): Map<String, String> {
        socket.soTimeout = 5000
        val reader = socket.getInputStream().bufferedReader()
        check(reader.readLine() != null)
        return buildMap {
            while (true) {
                val line = reader.readLine() ?: break
                if (line.isEmpty()) break
                val colon = line.indexOf(':')
                if (colon > 0) put(line.substring(0, colon).lowercase(Locale.ROOT), line.substring(colon + 1).trim())
            }
        }
    }

    private fun respond(socket: Socket, status: Int, headers: String = "", body: String = "") {
        socket.getOutputStream().write(("HTTP/1.1 $status Test\r\n$headers" +
            "Content-Length: ${body.length}\r\nConnection: close\r\n\r\n$body").toByteArray())
    }

    private fun readSocksConnect(socket: Socket): String {
        val input = DataInputStream(socket.getInputStream())
        assertEquals(5, input.readUnsignedByte())
        val methods = ByteArray(input.readUnsignedByte())
        input.readFully(methods)
        socket.getOutputStream().write(byteArrayOf(5, 0))
        assertEquals(5, input.readUnsignedByte())
        assertEquals(1, input.readUnsignedByte())
        assertEquals(0, input.readUnsignedByte())
        assertEquals(3, input.readUnsignedByte())
        val name = ByteArray(input.readUnsignedByte())
        input.readFully(name)
        input.readUnsignedShort()
        socket.getOutputStream().write(byteArrayOf(5, 0, 0, 1, 127, 0, 0, 1, 0, 0))
        return String(name, Charsets.UTF_8)
    }
}
