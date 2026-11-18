package com.github.dvbeckwitt.videre.proxy

import java.io.IOException
import java.net.InetAddress
import java.net.ServerSocket
import java.net.Socket
import java.util.concurrent.CountDownLatch
import java.util.concurrent.Executors
import java.util.concurrent.TimeUnit
import okhttp3.HttpUrl.Companion.toHttpUrl
import okhttp3.Request
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertThrows
import org.junit.Assert.assertTrue
import org.junit.Test

class MediaCancellationTest {
    @Test fun `media cancellation stops held player bodies but preserves native API bodies`() {
        for (podcast in listOf(false, true)) {
            HeldBody().use { media ->
                HeldBody().use { api ->
                    val factory = PolicyCallFactory()
                    factory.configure(ProxyPolicy())
                    try {
                        val source = if (podcast) factory.forPodcastSource(media.url)
                            else factory.forSource(media.url, emptySet())
                        val mediaCall = source.newCall(Request.Builder().url(media.url).build())
                        val apiCall = factory.newApiCall(Request.Builder().url(api.url).build(), ApiRedirectOptions())
                        mediaCall.execute().use { mediaResponse ->
                            apiCall.execute().use { apiResponse ->
                                assertEquals('x'.code.toByte(), mediaResponse.body!!.source().readByte())
                                assertEquals('x'.code.toByte(), apiResponse.body!!.source().readByte())
                                factory.cancelMediaCalls()
                                assertTrue(mediaCall.isCanceled())
                                assertFalse(apiCall.isCanceled())
                                assertThrows(IOException::class.java) { mediaResponse.body!!.source().readByte() }
                                api.finish()
                                assertEquals("yz", apiResponse.body!!.string())
                                api.awaitServed()
                            }
                        }
                    } finally { factory.block() }
                }
            }
        }
    }

    @Test fun `account cancellation affects only media belonging to that account`() {
        val factory = PolicyCallFactory()
        factory.configure(ProxyPolicy())
        try {
            val origin = "https://instance.example/".toHttpUrl()
            val first = GatewayContext("first-account", origin)
            val second = GatewayContext("second-account", origin)
            val request = Request.Builder().url("${origin}audio").build()
            val firstMedia = factory.forSource(origin.toString(), emptySet(), first).newCall(request)
            val secondMedia = factory.forSource(origin.toString(), emptySet(), second).newCall(request)
            val publicMedia = factory.forSource(origin.toString(), emptySet()).newCall(request)
            val podcast = factory.forPodcastSource(origin.toString()).newCall(request)
            val api = factory.newApiCall(prepareGatewayRequest(request, first), ApiRedirectOptions())
            // Even a reused request enters the API cancellation lifecycle here.
            val apiFromMedia = factory.newApiCall(firstMedia.request(), ApiRedirectOptions())
            factory.cancelMediaCalls(first.key)
            assertTrue(firstMedia.isCanceled())
            assertFalse(secondMedia.isCanceled())
            assertFalse(publicMedia.isCanceled())
            assertFalse(podcast.isCanceled())
            assertFalse(api.isCanceled())
            assertFalse(apiFromMedia.isCanceled())
        } finally { factory.block() }
    }

    @Test fun `proxy reconfiguration still cancels both held media and API bodies`() {
        HeldBody().use { media ->
            HeldBody().use { api ->
                val factory = PolicyCallFactory()
                factory.configure(ProxyPolicy())
                try {
                    val mediaCall = factory.forSource(media.url, emptySet())
                        .newCall(Request.Builder().url(media.url).build())
                    val apiCall = factory.newApiCall(Request.Builder().url(api.url).build(), ApiRedirectOptions())
                    mediaCall.execute().use { mediaResponse ->
                        apiCall.execute().use { apiResponse ->
                            assertEquals('x'.code.toByte(), mediaResponse.body!!.source().readByte())
                            assertEquals('x'.code.toByte(), apiResponse.body!!.source().readByte())
                            factory.configure(ProxyPolicy(true))
                            assertTrue(mediaCall.isCanceled())
                            assertTrue(apiCall.isCanceled())
                            assertThrows(IOException::class.java) { mediaResponse.body!!.source().readByte() }
                            assertThrows(IOException::class.java) { apiResponse.body!!.source().readByte() }
                        }
                    }
                } finally { factory.block() }
            }
        }
    }

    /** One loopback response whose remaining bytes stay server-side until explicitly released. */
    private class HeldBody : AutoCloseable {
        private val listener = ServerSocket(0, 1, InetAddress.getByName("127.0.0.1"))
        private val worker = Executors.newSingleThreadExecutor()
        private val release = CountDownLatch(1)
        @Volatile private var socket: Socket? = null
        val url = "http://127.0.0.1:${listener.localPort}/body"
        private val served = worker.submit {
            listener.soTimeout = 5000
            listener.accept().use { connection ->
                socket = connection
                connection.soTimeout = 5000
                val reader = connection.getInputStream().bufferedReader()
                while (reader.readLine()?.isNotEmpty() == true) { }
                val output = connection.getOutputStream()
                output.write("HTTP/1.1 200 OK\r\nContent-Length: 3\r\nConnection: close\r\n\r\nx".toByteArray())
                output.flush()
                check(release.await(10, TimeUnit.SECONDS))
                output.write("yz".toByteArray())
                output.flush()
            }
        }

        fun finish() = release.countDown()
        fun awaitServed() { served.get(10, TimeUnit.SECONDS) }

        override fun close() {
            socket?.close()
            listener.close()
            release.countDown()
            worker.shutdownNow()
        }
    }
}
