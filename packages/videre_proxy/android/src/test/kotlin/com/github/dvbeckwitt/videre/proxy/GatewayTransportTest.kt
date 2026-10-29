package com.github.dvbeckwitt.videre.proxy

import java.io.BufferedInputStream
import java.io.ByteArrayOutputStream
import java.io.EOFException
import java.io.InputStream
import java.net.InetAddress
import java.net.InetSocketAddress
import java.net.ServerSocket
import java.net.Socket
import java.net.SocketTimeoutException
import java.net.URI
import java.nio.charset.StandardCharsets
import java.util.Locale
import java.util.concurrent.CountDownLatch
import java.util.concurrent.Executors
import java.util.concurrent.TimeUnit
import java.util.concurrent.atomic.AtomicBoolean
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Assert.fail
import org.junit.Test

/** Real loopback sockets exercise the gateway without a device or public network. */
class GatewayTransportTest {
    private val onionHost = "a".repeat(56) + ".onion"
    private val gate = "synthetic_gateway_test_capability"

    @Test(timeout = 15_000)
    fun `gate authorization precedes SOCKS and upstream identity encoding is pinned`() {
        proxyListener().use { proxy ->
            val verified = AtomicBoolean(false)
            val gateway = gateway(proxy.localPort, verified)
            val executor = Executors.newSingleThreadExecutor()
            try {
                val gatewayPort = gateway.start()
                val unauthorized = requestGateway(gatewayPort, authorized = false)
                assertTrue(unauthorized.startsWith("HTTP/1.1 403 "))
                assertNoProxyConnection(proxy)

                val beforePreflight = requestGateway(gatewayPort, authorized = true)
                assertTrue(beforePreflight.startsWith("HTTP/1.1 403 "))
                assertNoProxyConnection(proxy)
                gateway.enableRelay()

                val serviceWorker = requestGateway(gatewayPort, authorized = true, serviceWorker = true)
                assertTrue(serviceWorker.startsWith("HTTP/1.1 403 "))
                assertNoProxyConnection(proxy)

                proxy.soTimeout = 5_000
                val upstream = executor.submit<ObservedRequest> {
                    proxy.accept().use { socket -> serveSocks(socket, reply = 0) }
                }
                val accepted = requestGateway(gatewayPort, authorized = true)
                val observed = upstream.get(5, TimeUnit.SECONDS)

                assertTrue(accepted.startsWith("HTTP/1.1 200 "))
                assertTrue(accepted.endsWith("\r\n\r\nok"))
                assertEquals(1, accepted.lineSequence().count {
                    it == "Connection-Allowlist: (response-origin); redirects=allow"
                })
                assertFalse(accepted.contains("Connection-Allowlist-Report-Only:", ignoreCase = true))
                assertFalse(accepted.contains("Alt-Svc:", ignoreCase = true))
                assertEquals("SOCKS must carry the hostname, not a resolved IP", 3, observed.addressType)
                assertEquals(onionHost, observed.destination)
                assertEquals(80, observed.port)
                assertEquals("GET /.gandalf/check HTTP/1.1", observed.requestLine)
                assertEquals(listOf("identity"), observed.headers["accept-encoding"])
                assertEquals(listOf(onionHost), observed.headers["host"])
                assertEquals(listOf("Synthetic WebView test browser"), observed.headers["user-agent"])
                assertFalse("The localhost capability must never leave the gateway", observed.headers.containsKey("cookie"))
                assertFalse("A challenge page is not a verified Invidious session", verified.get())
            } finally {
                gateway.close()
                executor.shutdownNow()
                executor.awaitTermination(1, TimeUnit.SECONDS)
            }
        }
    }

    @Test(timeout = 15_000)
    fun `SOCKS rejection ends the request without retry or a verified session`() {
        proxyListener().use { proxy ->
            val verified = AtomicBoolean(false)
            val failed = CountDownLatch(1)
            val gateway = gateway(proxy.localPort, verified, failed)
            val executor = Executors.newSingleThreadExecutor()
            try {
                val gatewayPort = gateway.start()
                gateway.enableRelay()
                val rejected = executor.submit<ObservedRequest> {
                    proxy.accept().use { socket -> serveSocks(socket, reply = 5) }
                }

                assertEquals("", requestGateway(gatewayPort, authorized = true))
                val observed = rejected.get(5, TimeUnit.SECONDS)
                assertEquals(3, observed.addressType)
                assertEquals(onionHost, observed.destination)
                assertTrue(failed.await(2, TimeUnit.SECONDS))
                assertFalse(verified.get())
                assertNoProxyConnection(proxy)
            } finally {
                gateway.close()
                executor.shutdownNow()
                executor.awaitTermination(1, TimeUnit.SECONDS)
            }
        }
    }

    @Test(timeout = 15_000)
    fun `preflight pages require the gate and only the exact probe is anonymous`() {
        proxyListener().use { proxy ->
            val gateway = gateway(proxy.localPort, AtomicBoolean(false))
            try {
                val port = gateway.start()
                val controlPath = URI(gateway.controlUrl()).rawPath
                val policyPath = URI(gateway.policyUrl()).rawPath
                val probePath = URI(gateway.probeUrl()).rawPath
                assertEquals(3, setOf(controlPath, policyPath, probePath).size)

                val denied = requestGateway(port, authorized = false, target = controlPath)
                assertTrue(denied.startsWith("HTTP/1.1 403 "))
                val control = requestGateway(port, authorized = true, target = controlPath)
                val protected = requestGateway(port, authorized = true, target = policyPath)
                assertTrue(control.startsWith("HTTP/1.1 200 "))
                assertTrue(protected.startsWith("HTTP/1.1 200 "))
                assertFalse(control.contains("Connection-Allowlist:"))
                assertTrue(protected.contains("Connection-Allowlist: (response-origin); redirects=allow\r\n"))
                for (page in listOf(control, protected)) {
                    assertTrue(page.contains("Cache-Control: no-store\r\n"))
                    assertTrue(page.contains("connect-src 'self' http://127.0.0.1:$port;"))
                    assertFalse(page.contains("<script", ignoreCase = true))
                }

                assertEquals(0, gateway.probeRequestCount())
                val wrongHost = requestGateway(port, authorized = false, target = probePath)
                assertTrue(wrongHost.startsWith("HTTP/1.1 403 "))
                val wrongMethod = requestGateway(port, authorized = false,
                    target = probePath, requestHost = "127.0.0.1", method = "POST")
                assertTrue(wrongMethod.startsWith("HTTP/1.1 405 "))
                assertEquals(0, gateway.probeRequestCount())
                val probe = requestGateway(port, authorized = false,
                    target = probePath, requestHost = "127.0.0.1")
                assertTrue(probe.startsWith("HTTP/1.1 200 "))
                assertTrue(probe.endsWith("\r\n\r\nok"))
                assertTrue(probe.contains("Access-Control-Allow-Origin: *\r\n"))
                assertFalse(probe.contains("Access-Control-Allow-Credentials:", ignoreCase = true))
                assertFalse(probe.contains("Set-Cookie:", ignoreCase = true))
                assertEquals(1, gateway.probeRequestCount())
                assertNoProxyConnection(proxy)

                gateway.enableRelay()
                val retiredControl = requestGateway(port, authorized = true, target = controlPath)
                val retiredPolicy = requestGateway(port, authorized = true, target = policyPath)
                val retiredProbe = requestGateway(port, authorized = false,
                    target = probePath, requestHost = "127.0.0.1")
                for (retired in listOf(retiredControl, retiredPolicy, retiredProbe)) {
                    assertTrue(retired.startsWith("HTTP/1.1 403 "))
                    assertTrue(retired.contains("Connection-Allowlist: (response-origin); redirects=allow\r\n"))
                    assertTrue(retired.endsWith("\r\n\r\n"))
                }
                assertEquals(1, gateway.probeRequestCount())
                assertNoProxyConnection(proxy)
            } finally {
                gateway.close()
            }
        }
    }

    private fun gateway(
        proxyPort: Int,
        verified: AtomicBoolean,
        failed: CountDownLatch? = null,
    ): OnionVerificationGateway = OnionVerificationGateway(
        "http://$onionHost",
        ProxyPolicy(enabled = true, host = "127.0.0.1", port = proxyPort),
        gate,
        object : OnionVerificationGateway.Listener {
            override fun onEvent(safe: String) {
                if (safe == "Network request failed") failed?.countDown()
            }

            override fun onVerified(requestHeaders: Map<String, String>, expiresAt: Long) {
                verified.set(true)
            }
        },
    )

    private fun proxyListener(): ServerSocket = ServerSocket().apply {
        bind(InetSocketAddress(InetAddress.getByName("127.0.0.1"), 0))
        soTimeout = 5_000
    }

    private fun assertNoProxyConnection(proxy: ServerSocket) {
        proxy.soTimeout = 250
        try {
            proxy.accept().use { fail("Unexpected connection to the SOCKS endpoint") }
        } catch (_: SocketTimeoutException) {
            // The loopback listener had no queued connection during this bound.
        }
    }

    private fun requestGateway(
        port: Int,
        authorized: Boolean,
        target: String = "/.gandalf/check",
        requestHost: String = "localhost",
        method: String = "GET",
        serviceWorker: Boolean = false,
    ): String = Socket().use { socket ->
        socket.connect(InetSocketAddress("127.0.0.1", port), 2_000)
        socket.soTimeout = 5_000
        val request = buildString {
            append("$method $target HTTP/1.1\r\n")
            append("Host: $requestHost:$port\r\n")
            append("User-Agent: Synthetic WebView test browser\r\n")
            append("Accept: text/html\r\n")
            append("Accept-Language: en-US,en;q=0.9\r\n")
            append("Accept-Encoding: gzip, br\r\n")
            if (serviceWorker) append("Service-Worker: script\r\n")
            if (authorized) append("Cookie: ${OnionVerificationGateway.GATE_COOKIE}=$gate\r\n")
            append("Connection: close\r\n\r\n")
        }
        socket.getOutputStream().write(request.toByteArray(StandardCharsets.ISO_8859_1))
        socket.getOutputStream().flush()
        String(socket.getInputStream().readBytes(), StandardCharsets.ISO_8859_1)
    }

    private data class ObservedRequest(
        val addressType: Int,
        val destination: String,
        val port: Int,
        val requestLine: String = "",
        val headers: Map<String, List<String>> = emptyMap(),
    )

    private fun serveSocks(socket: Socket, reply: Int): ObservedRequest {
        socket.soTimeout = 5_000
        val input = BufferedInputStream(socket.getInputStream())
        val output = socket.getOutputStream()
        assertEquals(5, readByte(input))
        val methods = readExactly(input, readByte(input))
        assertTrue(methods.any { it.toInt() == 0 })
        output.write(byteArrayOf(5, 0))
        output.flush()

        assertEquals(5, readByte(input))
        assertEquals(1, readByte(input))
        assertEquals(0, readByte(input))
        val addressType = readByte(input)
        assertEquals("SOCKS domain-name address type", 3, addressType)
        val destination = String(readExactly(input, readByte(input)), StandardCharsets.US_ASCII)
        val port = (readByte(input) shl 8) or readByte(input)
        output.write(byteArrayOf(5, reply.toByte(), 0, 1, 127, 0, 0, 1, 0, 80))
        output.flush()
        if (reply != 0) return ObservedRequest(addressType, destination, port)

        val requestLine = readLine(input)
        val headers = linkedMapOf<String, MutableList<String>>()
        while (true) {
            val line = readLine(input)
            if (line.isEmpty()) break
            val separator = line.indexOf(':')
            assertTrue(separator > 0)
            val name = line.substring(0, separator).lowercase(Locale.ROOT)
            headers.getOrPut(name) { mutableListOf() }.add(line.substring(separator + 1).trim())
        }
        output.write(("HTTP/1.1 200 OK\r\nContent-Type: text/plain\r\nContent-Length: 2\r\n"
            + "Connection-Allowlist: *\r\nConnection-Allowlist-Report-Only: *\r\n"
            + "Alt-Svc: h3=\":443\"\r\n"
            + "Connection: close\r\n\r\nok").toByteArray(StandardCharsets.ISO_8859_1))
        output.flush()
        return ObservedRequest(addressType, destination, port, requestLine, headers)
    }

    private fun readByte(input: InputStream): Int = input.read().also {
        if (it < 0) throw EOFException("Fixture connection closed")
    }

    private fun readExactly(input: InputStream, count: Int): ByteArray = ByteArray(count).also {
        var offset = 0
        while (offset < count) {
            val read = input.read(it, offset, count - offset)
            if (read < 0) throw EOFException("Fixture connection closed")
            offset += read
        }
    }

    private fun readLine(input: InputStream): String {
        val bytes = ByteArrayOutputStream()
        while (true) {
            val value = readByte(input)
            if (value == 10) return bytes.toString(StandardCharsets.ISO_8859_1.name()).removeSuffix("\r")
            if (bytes.size() >= 8_192) throw IllegalStateException("Fixture header too large")
            bytes.write(value)
        }
    }
}
