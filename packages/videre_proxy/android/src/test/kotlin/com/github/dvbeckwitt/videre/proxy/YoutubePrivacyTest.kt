package com.github.dvbeckwitt.videre.proxy

import java.io.IOException
import java.net.InetAddress
import java.net.Proxy
import java.net.ProxySelector
import java.net.ServerSocket
import java.net.SocketAddress
import java.net.SocketTimeoutException
import java.net.URI
import java.util.concurrent.Executors
import java.util.concurrent.TimeUnit
import okhttp3.HttpUrl.Companion.toHttpUrl
import okhttp3.Request
import okhttp3.RequestBody.Companion.toRequestBody
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertThrows
import org.junit.Assert.assertTrue
import org.junit.Test

class YoutubePrivacyTest {
    @Test
    fun `official host boundaries and shared API routes are classified`() {
        listOf("MUSIC.YOUTUBE.COM.", "youtu.be", "yt.be", "www.youtube-nocookie.com",
            "youtubekids.com", "www.youtubeeducation.com", "about.youtube",
            "youtubei.googleapis.com", "youtube.googleapis.com", "rr1.googlevideo.com",
            "content-youtube.googleapis.com", "youtubeembeddedplayer.googleapis.com", "www.googleapis.com",
            "i.ytimg.com", "s.ytimg.com", "yt3.ggpht.com", "lh3.googleusercontent.com",
            "www.gstatic.com").forEach { assertTrue(it, isOfficialYoutubeHost(it)) }
        listOf("invidious.nerdvpn.de", "invidious.dvbeckwitt.duckdns.org", "notyoutube.com",
            "youtube.com.example.org", "127.0.0.1").forEach { assertFalse(it, isOfficialYoutubeHost(it)) }
        assertTrue(isOfficialYoutubeUrl("https://www.googleapis.com/youtube/v3/videos".toHttpUrl()))
        assertTrue(isOfficialYoutubeUrl("https://www.googleapis.com/upload/youtube/v3/videos".toHttpUrl()))
        assertTrue(isOfficialYoutubeUrl("https://www.googleapis.com/youtube%2fv3/search".toHttpUrl()))
        assertTrue(isOfficialYoutubeUrl("https://content.googleapis.com/youtube%2Fv3/search".toHttpUrl()))
        assertTrue(isOfficialYoutubeUrl("https://www.googleapis.com/batch".toHttpUrl()))
        assertTrue(isOfficialYoutubeUrl("https://content.googleapis.com/batch".toHttpUrl()))
        assertTrue(isOfficialYoutubeUrl("https://www.googleapis.com/drive/v3/files".toHttpUrl()))
        assertFalse(isOfficialYoutubeUrl("https://invidious.example/videoplayback?host=rr1.googlevideo.com".toHttpUrl()))
    }

    @Test
    fun `API media and independent manifest children reject YouTube before route lookup`() {
        val previous = ProxySelector.getDefault()
        var routeLookups = 0
        ProxySelector.setDefault(object : ProxySelector() {
            override fun select(uri: URI): List<Proxy> {
                routeLookups++
                throw IOException("Unexpected route lookup in test.")
            }
            override fun connectFailed(uri: URI?, address: SocketAddress?, error: IOException?) = Unit
        })
        val factory = PolicyCallFactory()
        try {
            factory.configure(ProxyPolicy())
            val source = factory.forSource("https://invidious.example/manifest.mpd", emptySet())
            val requests = listOf(
                Request.Builder().url("https://music.youtube.com/youtubei/v1/search")
                    .post("{}".toRequestBody()).build(),
                Request.Builder().url("https://rr1.googlevideo.com/segment").build(),
                Request.Builder().url("https://i.ytimg.com/vi/video/default.jpg").build(),
                Request.Builder().url("https://www.googleapis.com/youtube/v3/videos").build(),
                Request.Builder().url("https://www.googleapis.com/batch")
                    .post("fixture-only".toRequestBody()).build(),
                Request.Builder().url("https://youtubeembeddedplayer.googleapis.com/").build(),
                Request.Builder().url("https://yt.be/fixture").build(),
            )
            for (request in requests) {
                assertThrows(YoutubeConnectionBlocked::class.java) { factory.newCall(request).execute() }
                assertThrows(YoutubeConnectionBlocked::class.java) { factory.newApiCall(request, ApiRedirectOptions()).execute() }
                assertThrows(YoutubeConnectionBlocked::class.java) { source.newCall(request).execute() }
            }
            assertEquals(0, routeLookups)
        } finally {
            factory.block()
            ProxySelector.setDefault(previous)
        }
    }

    @Test
    fun `SOCKS cannot authorize official YouTube destinations`() {
        ServerSocket(0, 1, InetAddress.getByName("127.0.0.1")).use { proxy ->
            val factory = PolicyCallFactory()
            try {
                factory.configure(ProxyPolicy(true, "127.0.0.1", proxy.localPort))
                val request = Request.Builder().url("https://music.youtube.com/youtubei/v1/search")
                    .post("{}".toRequestBody()).build()
                assertThrows(YoutubeConnectionBlocked::class.java) { factory.newCall(request).execute() }
                proxy.soTimeout = 100
                assertThrows(SocketTimeoutException::class.java) { proxy.accept().close() }
            } finally {
                factory.block()
            }
        }
    }

    @Test
    fun `instance redirect is blocked before official DNS or connection acquisition`() {
        val previous = ProxySelector.getDefault()
        var officialRoutes = 0
        ProxySelector.setDefault(object : ProxySelector() {
            override fun select(uri: URI): List<Proxy> {
                if (isOfficialYoutubeHost(uri.host ?: "")) {
                    officialRoutes++
                    throw IOException("Unexpected official destination in test.")
                }
                return listOf(Proxy.NO_PROXY)
            }
            override fun connectFailed(uri: URI?, address: SocketAddress?, error: IOException?) = Unit
        })
        val worker = Executors.newSingleThreadExecutor()
        val factory = PolicyCallFactory()
        try {
            ServerSocket(0, 1, InetAddress.getByName("127.0.0.1")).use { local ->
                val served = worker.submit {
                    local.accept().use { socket ->
                        socket.soTimeout = 5000
                        val reader = socket.getInputStream().bufferedReader()
                        while (reader.readLine()?.isNotEmpty() == true) { }
                        socket.getOutputStream().write(("HTTP/1.1 302 Found\r\n" +
                            "Location: https://music.youtube.com/youtubei/v1/search\r\n" +
                            "Content-Length: 0\r\nConnection: close\r\n\r\n").toByteArray())
                    }
                }
                factory.configure(ProxyPolicy())
                val request = Request.Builder().url("http://127.0.0.1:${local.localPort}/videoplayback").build()
                assertThrows(YoutubeConnectionBlocked::class.java) { factory.newCall(request).execute() }
                served.get(10, TimeUnit.SECONDS)
                assertEquals(0, officialRoutes)
            }
        } finally {
            factory.block()
            worker.shutdownNow()
            ProxySelector.setDefault(previous)
        }
    }
}
