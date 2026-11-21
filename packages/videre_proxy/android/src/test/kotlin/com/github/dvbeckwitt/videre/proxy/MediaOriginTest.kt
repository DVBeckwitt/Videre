package com.github.dvbeckwitt.videre.proxy

import java.io.IOException
import java.net.InetAddress
import java.net.Proxy
import java.net.ProxySelector
import java.net.ServerSocket
import java.net.SocketAddress
import java.net.URI
import java.util.concurrent.Executors
import java.util.concurrent.TimeUnit
import javax.net.ssl.SSLException
import okhttp3.Request
import org.junit.Assert.assertEquals
import org.junit.Assert.assertThrows
import org.junit.Test

class MediaOriginTest {
    @Test
    fun `anchored media children reject different scheme host or port before routing`() {
        val previous = ProxySelector.getDefault()
        var routes = 0
        ProxySelector.setDefault(object : ProxySelector() {
            override fun select(uri: URI): List<Proxy> {
                routes++
                throw IOException("Unexpected route lookup")
            }
            override fun connectFailed(uri: URI?, address: SocketAddress?, error: IOException?) = Unit
        })
        val factory = PolicyCallFactory()
        try {
            for (policy in listOf(ProxyPolicy(), ProxyPolicy(true))) {
                factory.configure(policy)
                val source = factory.forSource("https://instance.example/manifest.mpd", emptySet())
                for (url in listOf("https://other.example/segment", "http://instance.example/segment",
                    "https://instance.example:8443/segment", "http://127.0.0.1/segment")) {
                    for (marked in listOf(false, true)) {
                        val request = Request.Builder().url(url).apply {
                            if (marked) header(INSTANCE_ORIGIN_HEADER, "https://instance.example")
                        }.build()
                        val error = assertThrows(SelectedOriginBlocked::class.java) { source.newCall(request).execute() }
                        assertEquals(true, MediaOriginFailure.isBlocked(IOException("Source error", error)))
                    }
                }
                for (url in listOf("https://user:password@other.example/segment", "https://rr1.googlevideo.com/segment")) {
                    val error = assertThrows(IOException::class.java) {
                        source.newCall(Request.Builder().url(url).build()).execute()
                    }
                    assertEquals(false, MediaOriginFailure.isBlocked(error))
                }
            }
            assertEquals(0, routes)
        } finally {
            factory.block()
            ProxySelector.setDefault(previous)
        }
    }

    @Test
    fun `media and scoped API redirects reject a different origin before routing`() {
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
            for (mode in listOf("media", "api", "no-follow", "marked", "marked-no-follow")) {
                ServerSocket(0, 1, InetAddress.getByName("127.0.0.1")).use { listener ->
                    listener.soTimeout = 5000
                    val served = worker.submit {
                        listener.accept().use { socket ->
                            socket.soTimeout = 5000
                            val reader = socket.getInputStream().bufferedReader()
                            while (reader.readLine()?.isNotEmpty() == true) { }
                            socket.getOutputStream().write(("HTTP/1.1 302 Found\r\n" +
                                "Location: https://other.example/media\r\n" +
                                "Content-Length: 0\r\nConnection: close\r\n\r\n").toByteArray())
                        }
                    }
                    factory.configure(ProxyPolicy())
                    val origin = "http://127.0.0.1:${listener.localPort}"
                    val request = Request.Builder().url("$origin/segment").apply {
                        if (mode.startsWith("marked")) header(INSTANCE_ORIGIN_HEADER, origin)
                    }.build()
                    val call = if (mode == "media") {
                        factory.forSource("$origin/manifest.mpd", emptySet()).newCall(request)
                    } else if (mode == "marked") {
                        factory.newCall(request)
                    } else factory.newApiCall(request, ApiRedirectOptions(
                        followRedirects = !mode.endsWith("no-follow"), sameOriginOnly = !mode.startsWith("marked")))
                    if (mode.endsWith("no-follow")) call.execute().use { assertEquals(302, it.code) }
                    else {
                        val error = assertThrows(SelectedOriginBlocked::class.java) { call.execute() }
                        assertEquals(mode == "media", MediaOriginFailure.isBlocked(error))
                    }
                    served.get(10, TimeUnit.SECONDS)
                    assertEquals(0, foreignRoutes)
                }
            }
        } finally {
            factory.block()
            worker.shutdownNow()
            ProxySelector.setDefault(previous)
        }
    }

    @Test
    fun `malformed markers and access failures cannot trigger a media fallback`() {
        val factory = PolicyCallFactory()
        try {
            factory.configure(ProxyPolicy())
            val source = factory.forSource("https://instance.example/manifest.mpd", emptySet())
            for (marker in listOf("invalid", "https://other.example", "https://instance.example/path")) {
                val request = Request.Builder().url("https://other.example/segment")
                    .header(INSTANCE_ORIGIN_HEADER, marker).build()
                val error = assertThrows(SelectedOriginBlocked::class.java) { source.newCall(request).execute() }
                assertEquals(false, MediaOriginFailure.isBlocked(error))
            }
            for (refusal in listOf(GatewayAuthenticationRequired(), NerdVpnAccessRequired("missing"),
                SSLException("TLS failure"), IOException("Source error"))) {
                assertEquals(false, MediaOriginFailure.isBlocked(refusal))
            }
            val wrapped = SSLException("TLS failure").apply { initCause(SelectedOriginBlocked(mediaDestination = true)) }
            assertEquals(false, MediaOriginFailure.isBlocked(wrapped))
        } finally {
            factory.block()
        }
    }

    @Test
    fun `unanchored and local source factories preserve generic transport routing`() {
        val previous = ProxySelector.getDefault()
        var routes = 0
        ProxySelector.setDefault(object : ProxySelector() {
            override fun select(uri: URI): List<Proxy> {
                routes++
                throw IOException("Expected generic route lookup")
            }
            override fun connectFailed(uri: URI?, address: SocketAddress?, error: IOException?) = Unit
        })
        val factory = PolicyCallFactory()
        try {
            factory.configure(ProxyPolicy())
            val request = Request.Builder().url("http://127.0.0.1/generic").build()
            for (anchor in listOf(null, "file:///local/video.mp4", "content://downloads/video")) {
                val source = factory.forSource(anchor, emptySet())
                val error = assertThrows(IOException::class.java) { source.newCall(request).execute() }
                assertEquals("Expected generic route lookup", error.message)
            }
            assertEquals(3, routes)
        } finally {
            factory.block()
            ProxySelector.setDefault(previous)
        }
    }
}
