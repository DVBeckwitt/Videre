package com.github.dvbeckwitt.videre.proxy

import java.io.BufferedInputStream
import java.io.DataInputStream
import java.io.EOFException
import java.net.InetAddress
import java.net.Proxy
import java.net.ServerSocket
import java.net.Socket
import java.net.URI
import java.util.concurrent.Executors
import java.util.concurrent.TimeUnit
import java.util.concurrent.atomic.AtomicInteger
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertThrows
import org.junit.Assert.assertTrue
import org.junit.Test

class BrowserPrivacyProxyTest {
    private val localhost = InetAddress.getByName("127.0.0.1")

    @Test fun `direct and SOCKS routes reject YouTube before allocating an outbound socket`() {
        val allocations = AtomicInteger()
        BrowserPrivacyProxy(createSocket = {
            allocations.incrementAndGet()
            error("Unexpected outbound connection")
        }).use { proxy ->
            for ((socks, port) in listOf(null to null, "127.0.0.1" to 9050)) {
                proxy.allow(socks, port)
                val requests = listOf(
                    "CONNECT music.youtube.com:443 HTTP/1.1\r\nHost: music.youtube.com:443\r\n\r\n",
                    "GET http://music.youtube.com/youtubei/v1/search HTTP/1.1\r\nHost: music.youtube.com\r\n\r\n",
                    "CONNECT MUSIC.YOUTUBE.COM.:443 HTTP/1.1\r\nHost: music.youtube.com.:443\r\n\r\n",
                    "CONNECT www.googleapis.com:443 HTTP/1.1\r\nHost: www.googleapis.com:443\r\n\r\n",
                    "CONNECT content.googleapis.com:443 HTTP/1.1\r\nHost: content.googleapis.com:443\r\n\r\n",
                )
                for (request in requests) {
                    connect(proxy).use { browser ->
                        browser.write(request)
                        assertTrue(headers(browser.getInputStream()).startsWith("HTTP/1.1 403 "))
                    }
                }
            }
            assertEquals(0, allocations.get())
        }
    }

    @Test fun `plain proxy requests reject conflicting authority and ambiguous body framing`() {
        val allocations = AtomicInteger()
        BrowserPrivacyProxy(createSocket = {
            allocations.incrementAndGet()
            error("Unexpected outbound connection")
        }).use { proxy ->
            proxy.allow(null, null)
            val requests = listOf(
                "GET http://instance.example/a HTTP/1.1\r\nHost: other.example\r\n\r\n",
                "GET http://instance.example/a HTTP/1.1\r\nHost: instance.example\r\nHost: instance.example\r\n\r\n",
                "POST http://instance.example/a HTTP/1.1\r\nHost: instance.example\r\n" +
                    "Content-Length: 1\r\nContent-Length: 2\r\n\r\n",
                "POST http://instance.example/a HTTP/1.1\r\nHost: instance.example\r\nTransfer-Encoding: chunked\r\n\r\n",
                "GET http://instance.example/a HTTP/1.1\r\nHost: instance.example\r\nX-Fill: ${"x".repeat(33 * 1024)}\r\n\r\n",
            )
            for (request in requests) {
                connect(proxy).use { browser ->
                    browser.write(request)
                    assertTrue(headers(browser.getInputStream()).startsWith("HTTP/1.1 400 "))
                }
            }
            assertEquals(0, allocations.get())
        }
    }

    @Test fun `SOCKS HTTP login POST keeps cookies and body and a later redirect is blocked`() {
        val worker = Executors.newSingleThreadExecutor()
        try {
            ServerSocket(0, 1, localhost).use { socks ->
                socks.soTimeout = 3_000
                val served = worker.submit {
                    socks.accept().use { upstream ->
                        upstream.soTimeout = 3_000
                        val input = DataInputStream(BufferedInputStream(upstream.getInputStream()))
                        assertEquals(5, input.readUnsignedByte())
                        val methods = ByteArray(input.readUnsignedByte()).also(input::readFully)
                        assertTrue(0.toByte() in methods)
                        upstream.getOutputStream().write(byteArrayOf(5, 0))
                        assertEquals(5, input.readUnsignedByte())
                        assertEquals(1, input.readUnsignedByte())
                        assertEquals(0, input.readUnsignedByte())
                        assertEquals(3, input.readUnsignedByte())
                        val host = ByteArray(input.readUnsignedByte()).also(input::readFully).toString(Charsets.US_ASCII)
                        assertEquals(NERDVPN_ONION_HOST, host)
                        assertEquals(80, input.readUnsignedShort())
                        upstream.getOutputStream().write(byteArrayOf(5, 0, 0, 1, 127, 0, 0, 1, 0, 80))
                        val request = headers(input)
                        assertTrue(request.startsWith("POST /login?step=2 HTTP/1.1\r\n"))
                        assertTrue(request.contains("\r\nCookie: fixture=ok\r\n"))
                        assertTrue(request.contains("\r\nConnection: close\r\n"))
                        assertFalse(request.contains("Proxy-Authorization"))
                        assertEquals("answer=yes", ByteArray(10).also(input::readFully).toString(Charsets.US_ASCII))
                        upstream.write("HTTP/1.1 302 Found\r\nLocation: https://music.youtube.com/youtubei/v1/search\r\n" +
                            "Set-Cookie: fixture=updated; Path=/\r\nContent-Length: 0\r\nConnection: close\r\n\r\n")
                    }
                }
                val allocations = AtomicInteger()
                BrowserPrivacyProxy(createSocket = { policy ->
                    assertEquals(Proxy.Type.SOCKS, policy.type())
                    allocations.incrementAndGet()
                    Socket(policy)
                }).use { proxy ->
                    proxy.allow("127.0.0.1", socks.localPort)
                    connect(proxy).use { browser ->
                        browser.write("POST http://$NERDVPN_ONION_HOST/login?step=2 HTTP/1.1\r\n" +
                            "Host: $NERDVPN_ONION_HOST\r\nCookie: fixture=ok\r\n" +
                            "Proxy-Authorization: fixture-only\r\nContent-Length: 10\r\n\r\nanswer=yes")
                        val response = headers(browser.getInputStream())
                        assertTrue(response.startsWith("HTTP/1.1 302 "))
                        assertTrue(response.contains("\r\nSet-Cookie: fixture=updated; Path=/\r\n"))
                    }
                    connect(proxy).use { browser ->
                        browser.write("CONNECT music.youtube.com:443 HTTP/1.1\r\nHost: music.youtube.com:443\r\n\r\n")
                        assertTrue(headers(browser.getInputStream()).startsWith("HTTP/1.1 403 "))
                    }
                    assertEquals(1, allocations.get())
                    served.get(5, TimeUnit.SECONDS)
                }
            }
        } finally {
            worker.shutdownNow()
        }
    }

    @Test fun `deny closes an established tunnel and keeps the loopback listener reserved`() {
        val worker = Executors.newSingleThreadExecutor()
        try {
            ServerSocket(0, 1, localhost).use { server ->
                server.soTimeout = 3_000
                val served = worker.submit {
                    server.accept().use { upstream ->
                        upstream.soTimeout = 3_000
                        assertEquals('a'.code, upstream.getInputStream().read())
                        upstream.write("b")
                        assertEquals(-1, upstream.getInputStream().read())
                    }
                }
                BrowserPrivacyProxy().use { proxy ->
                    connect(proxy).use { browser -> assertEquals(-1, browser.getInputStream().read()) }
                    proxy.allow(null, null)
                    val authority = "127.0.0.1:${server.localPort}"
                    connect(proxy).use { browser ->
                        browser.write("CONNECT $authority HTTP/1.1\r\nHost: $authority\r\n\r\n")
                        assertTrue(headers(browser.getInputStream()).startsWith("HTTP/1.1 200 "))
                        browser.write("a")
                        assertEquals('b'.code, browser.getInputStream().read())
                        proxy.deny()
                        assertEquals(-1, browser.getInputStream().read())
                    }
                    assertThrows(IllegalArgumentException::class.java) {
                        proxy.allow("music.youtube.com", 9050)
                    }
                    connect(proxy).use { browser -> assertEquals(-1, browser.getInputStream().read()) }
                    served.get(5, TimeUnit.SECONDS)
                }
            }
        } finally {
            worker.shutdownNow()
        }
    }

    private fun connect(proxy: BrowserPrivacyProxy): Socket = Socket(localhost, URI(proxy.url).port).apply {
        soTimeout = 3_000
    }

    private fun Socket.write(value: String) {
        getOutputStream().write(value.toByteArray(Charsets.US_ASCII))
        getOutputStream().flush()
    }

    private fun headers(input: java.io.InputStream): String = buildString {
        while (!endsWith("\r\n\r\n") && length < 32 * 1024) {
            val byte = input.read()
            if (byte == -1) throw EOFException("Missing fixture response headers")
            append(byte.toChar())
        }
    }
}
