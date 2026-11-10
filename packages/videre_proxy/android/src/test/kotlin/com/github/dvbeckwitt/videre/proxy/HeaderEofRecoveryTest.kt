package com.github.dvbeckwitt.videre.proxy

import java.io.ByteArrayOutputStream
import java.io.DataInputStream
import java.io.EOFException
import java.io.IOException
import java.net.InetAddress
import java.net.ServerSocket
import java.net.Socket
import java.net.SocketTimeoutException
import java.util.concurrent.CountDownLatch
import java.util.concurrent.Executors
import java.util.concurrent.TimeUnit
import javax.net.ssl.SSLException
import okhttp3.HttpUrl
import okhttp3.HttpUrl.Companion.toHttpUrl
import okhttp3.Request
import okhttp3.RequestBody.Companion.toRequestBody
import org.junit.Assert.assertEquals
import org.junit.Assert.assertThrows
import org.junit.Assert.assertTrue
import org.junit.Test

class HeaderEofRecoveryTest {
    @Test
    fun `implicit close recovers one ranged GET through the same direct or SOCKS policy`() {
        for (socks in listOf(false, true)) {
            Fixture(socks).use { fixture ->
                val served = fixture.serve {
                    val requests = mutableListOf<String>()
                    fixture.accept().use { socket ->
                        requests += headers(socket)
                        // HTTP/1.0 is nonpersistent without an explicit keep-alive.
                        // Keep the socket open until the client actually reuses it,
                        // then close without a response to reproduce the race.
                        respond(socket, "HTTP/1.0 200 OK\r\nContent-Length: 1\r\n\r\nx")
                        requests += headers(socket)
                    }
                    fixture.accept().use { socket ->
                        requests += headers(socket)
                        respond(socket, "HTTP/1.0 416 Range Not Satisfiable\r\n" +
                            "Content-Length: 0\r\nContent-Range: bytes */1\r\nConnection: close\r\n\r\n")
                    }
                    requests
                }
                val factory = fixture.factory()
                try {
                    val request = Request.Builder().url(fixture.url)
                        .header("Authorization", "fixture-only").build()
                    factory.newCall(request).execute().use { assertEquals("x", it.body!!.string()) }
                    factory.newCall(request.newBuilder().header("Range", "bytes=1-").build()).execute().use {
                        assertEquals(416, it.code)
                        assertEquals("bytes */1", it.header("Content-Range"))
                    }
                    val requests = served.get(5, TimeUnit.SECONDS)
                    assertEquals(3, requests.size)
                    assertTrue(requests.drop(1).all { it.contains("Range: bytes=1-\r\n") })
                    assertTrue(requests.all { it.contains("Authorization: fixture-only\r\n") })
                    if (socks) assertEquals(listOf("retry-origin.invalid", "retry-origin.invalid"), fixture.destinations)
                } finally {
                    factory.block()
                }
            }
        }
    }

    @Test
    fun `header EOF retry is bounded to one additional GET`() {
        Fixture().use { fixture ->
            val served = fixture.serve {
                repeat(2) { fixture.accept().use { headers(it) } }
                fixture.assertNoConnection()
            }
            val factory = fixture.factory()
            try {
                assertThrows(IOException::class.java) {
                    factory.newCall(Request.Builder().url(fixture.url).build()).execute()
                }
                served.get(5, TimeUnit.SECONDS)
            } finally {
                factory.block()
            }
        }
    }

    @Test
    fun `HEAD can recover a header EOF without reading a response body`() {
        Fixture().use { fixture ->
            val served = fixture.serve {
                fixture.accept().use { assertTrue(headers(it).startsWith("HEAD ")) }
                fixture.accept().use { socket ->
                    assertTrue(headers(socket).startsWith("HEAD "))
                    respond(socket, "HTTP/1.1 200 OK\r\nContent-Length: 10\r\nConnection: close\r\n\r\n")
                }
            }
            val factory = fixture.factory()
            try {
                factory.newCall(Request.Builder().url(fixture.url).head().build()).execute().use {
                    assertEquals(200, it.code)
                    assertEquals("", it.body!!.string())
                }
                served.get(5, TimeUnit.SECONDS)
            } finally {
                factory.block()
            }
        }
    }

    @Test
    fun `POST is never replayed after a header EOF`() {
        Fixture().use { fixture ->
            val served = fixture.serve {
                fixture.accept().use { socket ->
                    headers(socket)
                    assertEquals('x'.code, socket.getInputStream().read())
                }
                fixture.assertNoConnection()
            }
            val factory = fixture.factory()
            try {
                assertThrows(IOException::class.java) {
                    factory.newCall(Request.Builder().url(fixture.url).post("x".toRequestBody()).build()).execute()
                }
                served.get(5, TimeUnit.SECONDS)
            } finally {
                factory.block()
            }
        }
    }

    @Test
    fun `response body failures are not replayed`() {
        Fixture().use { fixture ->
            val served = fixture.serve {
                fixture.accept().use { socket ->
                    headers(socket)
                    respond(socket, "HTTP/1.1 200 OK\r\nContent-Length: 10\r\nConnection: close\r\n\r\nx")
                }
                fixture.assertNoConnection()
            }
            val factory = fixture.factory()
            try {
                factory.newCall(Request.Builder().url(fixture.url).build()).execute().use { response ->
                    assertThrows(IOException::class.java) { response.body!!.string() }
                }
                served.get(5, TimeUnit.SECONDS)
            } finally {
                factory.block()
            }
        }
    }

    @Test
    fun `EOF after response headers in a credential handler is not replayed`() {
        Fixture(true, NERDVPN_ONION_HOST, 80).use { fixture ->
            val served = fixture.serve {
                fixture.accept().use { socket ->
                    headers(socket)
                    respond(socket, "HTTP/1.1 200 OK\r\nContent-Length: 0\r\nConnection: close\r\n\r\n")
                }
                fixture.assertNoConnection()
            }
            val previous = GatewayCookieAccessRegistry.provider
            GatewayCookieAccessRegistry.provider = object : GatewayCookieAccess {
                override fun resolve(context: GatewayContext, url: HttpUrl) = GatewayCookies(true, false)
                override fun ingest(context: GatewayContext, url: HttpUrl, cookies: List<String>,
                    statusCode: Int, contentType: String?, location: String?, revision: Long?): Boolean =
                    throw EOFException("Fixture credential handler failed after receiving headers")
            }
            val factory = fixture.factory()
            try {
                val context = GatewayContext("8c9502ae-b933-5fa1-a75d-c6d85c2ec021",
                    "http://$NERDVPN_ONION_HOST".toHttpUrl())
                val request = prepareGatewayRequest(Request.Builder()
                    .url("http://$NERDVPN_ONION_HOST/api/v1/token").build(), context)
                assertThrows(EOFException::class.java) { factory.newCall(request).execute() }
                served.get(5, TimeUnit.SECONDS)
            } finally {
                factory.block()
                GatewayCookieAccessRegistry.provider = previous
            }
        }
    }

    @Test
    fun `TLS handshake EOF is not retried as an HTTP header failure`() {
        Fixture().use { fixture ->
            val served = fixture.serve {
                fixture.accept().use { socket ->
                    val input = DataInputStream(socket.getInputStream())
                    val record = ByteArray(5)
                    input.readFully(record)
                    assertEquals(22, record[0].toInt())
                    val length = ((record[3].toInt() and 255) shl 8) or (record[4].toInt() and 255)
                    input.readFully(ByteArray(length))
                }
                fixture.assertNoConnection()
            }
            val factory = fixture.factory()
            try {
                assertThrows(SSLException::class.java) {
                    factory.newCall(Request.Builder().url(fixture.url.replace("http:", "https:")).build()).execute()
                }
                served.get(5, TimeUnit.SECONDS)
            } finally {
                factory.block()
            }
        }
    }

    @Test
    fun `a policy change cancels an unsettled read instead of replaying it`() {
        Fixture().use { fixture ->
            val received = CountDownLatch(1)
            val release = CountDownLatch(1)
            val served = fixture.serve {
                fixture.accept().use { socket ->
                    headers(socket)
                    received.countDown()
                    assertTrue(release.await(5, TimeUnit.SECONDS))
                }
                fixture.assertNoConnection()
            }
            val factory = fixture.factory()
            val client = Executors.newSingleThreadExecutor()
            try {
                val call = factory.newCall(Request.Builder().url(fixture.url).build())
                val result = client.submit<Boolean> {
                    assertThrows(IOException::class.java) { call.execute() }
                    true
                }
                assertTrue(received.await(5, TimeUnit.SECONDS))
                factory.configure(ProxyPolicy(true, "127.0.0.1", fixture.port))
                release.countDown()
                assertTrue(result.get(5, TimeUnit.SECONDS))
                assertTrue(call.isCanceled())
                served.get(5, TimeUnit.SECONDS)
            } finally {
                release.countDown()
                factory.block()
                client.shutdownNow()
            }
        }
    }

    private class Fixture(private val socks: Boolean = false,
        private val targetHost: String = "retry-origin.invalid", private val targetPort: Int = 8123) : AutoCloseable {
        private val listener = ServerSocket(0, 4, InetAddress.getByName("127.0.0.1"))
        private val worker = Executors.newSingleThreadExecutor()
        val destinations = mutableListOf<String>()
        val port: Int get() = listener.localPort
        val url: String get() = if (socks) "http://$targetHost:$targetPort/media" else "http://127.0.0.1:$port/media"

        fun factory() = PolicyCallFactory().apply {
            configure(if (socks) ProxyPolicy(true, "127.0.0.1", port) else ProxyPolicy())
        }

        fun <T> serve(block: () -> T) = worker.submit<T> { block() }

        fun accept(): Socket {
            listener.soTimeout = 5000
            return listener.accept().apply {
                soTimeout = 5000
                if (socks) {
                    val input = DataInputStream(getInputStream())
                    assertEquals(5, input.readUnsignedByte())
                    val methods = ByteArray(input.readUnsignedByte())
                    input.readFully(methods)
                    getOutputStream().write(byteArrayOf(5, 0))
                    assertEquals(5, input.readUnsignedByte())
                    assertEquals(1, input.readUnsignedByte())
                    assertEquals(0, input.readUnsignedByte())
                    assertEquals(3, input.readUnsignedByte())
                    val host = ByteArray(input.readUnsignedByte())
                    input.readFully(host)
                    destinations += String(host, Charsets.UTF_8)
                    assertEquals(targetPort, input.readUnsignedShort())
                    getOutputStream().write(byteArrayOf(5, 0, 0, 1, 127, 0, 0, 1, 0, 0))
                }
            }
        }

        fun assertNoConnection() {
            listener.soTimeout = 300
            assertThrows(SocketTimeoutException::class.java) { listener.accept().use { } }
        }

        override fun close() {
            listener.close()
            worker.shutdownNow()
        }
    }

    companion object {
        private fun headers(socket: Socket): String {
            val output = ByteArrayOutputStream()
            var ending = 0
            val marker = byteArrayOf(13, 10, 13, 10)
            while (ending < marker.size && output.size() < 65536) {
                val value = socket.getInputStream().read()
                check(value >= 0) { "Incomplete request headers" }
                output.write(value)
                val byte = value.toByte()
                ending = if (byte == marker[ending]) ending + 1 else if (byte == marker[0]) 1 else 0
            }
            check(ending == marker.size)
            return output.toString(Charsets.UTF_8.name())
        }

        private fun respond(socket: Socket, value: String) {
            socket.getOutputStream().write(value.toByteArray(Charsets.UTF_8))
            socket.getOutputStream().flush()
        }
    }
}
