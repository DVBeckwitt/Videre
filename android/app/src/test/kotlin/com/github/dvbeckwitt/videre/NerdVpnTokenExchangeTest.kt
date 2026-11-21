package com.github.dvbeckwitt.videre

import java.io.IOException
import java.io.InterruptedIOException
import java.net.InetAddress
import java.net.Proxy
import java.net.ServerSocket
import java.net.SocketException
import java.net.SocketTimeoutException
import java.util.concurrent.Executors
import java.util.concurrent.TimeUnit
import okhttp3.OkHttpClient
import okhttp3.Protocol
import okhttp3.Request
import okhttp3.Response
import okhttp3.ResponseBody.Companion.toResponseBody
import okio.buffer
import okio.source
import org.junit.Assert.*
import org.junit.Test

class NerdVpnTokenExchangeTest {
    @Test fun immediateServiceRetryDoesNotReplayTheSingleUseExchange() {
        val payload = """{"code":"fixture"}"""
        val server = ServerSocket(0, 2, InetAddress.getByName("127.0.0.1"))
        val executor = Executors.newSingleThreadExecutor()
        val received = executor.submit<List<String>> {
            val bodies = mutableListOf<String>()
            try {
                while (bodies.size < 2) {
                    server.accept().use { socket ->
                        socket.soTimeout = 5000
                        val input = socket.source().buffer()
                        while (input.readUtf8LineStrict().isNotEmpty()) {
                            // The fixed ASCII fixture body follows the request headers.
                        }
                        bodies.add(input.readUtf8(payload.length.toLong()))
                        val reply = "HTTP/1.1 503 Service Unavailable\r\nRetry-After: 0\r\nContent-Length: 0\r\nConnection: close\r\n\r\n"
                        socket.getOutputStream().write(reply.toByteArray(Charsets.US_ASCII))
                    }
                }
            } catch (closed: SocketException) {
                if (!server.isClosed) throw closed
            }
            bodies
        }
        val client = OkHttpClient.Builder().proxy(Proxy.NO_PROXY)
            .retryOnConnectionFailure(false).followRedirects(false)
            .callTimeout(5, TimeUnit.SECONDS).build()
        try {
            val request = Request.Builder().url("http://127.0.0.1:${server.localPort}/api/v1/token")
                .post(NerdVpnTokenExchange.exchangeBody(payload)).build()
            client.newCall(request).execute().use { assertEquals(503, it.code) }
        } finally {
            server.close()
            executor.shutdown()
            client.connectionPool.evictAll()
        }
        assertEquals(listOf(payload), received.get(5, TimeUnit.SECONDS))
    }

    @Test fun connectionFailuresOnlyReportSafeCategories() {
        for (timeout in listOf(SocketTimeoutException(), InterruptedIOException("timeout"))) {
            assertEquals("GATEWAY_TOKEN_TIMEOUT", NerdVpnTokenExchange.transportError(timeout))
        }
        assertEquals("GATEWAY_TOKEN_UNAVAILABLE", NerdVpnTokenExchange.transportError(IOException("private details")))
    }

    @Test fun rateLimitAndServiceOutageAreReportedEvenWithHtmlOrNoRetryAfter() {
        for (status in listOf(429, 503)) {
            for (retryAfter in listOf(null, "120")) {
                val response = Response.Builder()
                    .request(Request.Builder().url("https://instance.example/api/v1/token").build())
                    .protocol(Protocol.HTTP_1_1).code(status).message("fixture")
                    .apply { if (retryAfter != null) header("Retry-After", retryAfter) }
                    .body("<html>private details</html>".toResponseBody()).build()
                val result = NerdVpnTokenExchange.read(response)
                assertNull(result.token)
                assertEquals("GATEWAY_TOKEN_UNAVAILABLE", result.error)
                assertEquals(mapOf("statusCode" to status, "retryAfter" to (retryAfter ?: "")), result.details)
                assertTrue(result.cookies.isEmpty())
            }
        }
    }
}
