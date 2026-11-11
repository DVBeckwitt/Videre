package com.github.dvbeckwitt.videre.proxy

import java.io.BufferedInputStream
import java.io.Closeable
import java.io.IOException
import java.io.OutputStream
import java.net.InetSocketAddress
import java.net.Proxy
import java.net.ServerSocket
import java.net.Socket
import java.util.Locale
import java.util.concurrent.RejectedExecutionException
import java.util.concurrent.SynchronousQueue
import java.util.concurrent.ThreadPoolExecutor
import java.util.concurrent.TimeUnit
import okhttp3.HttpUrl
import okhttp3.HttpUrl.Companion.toHttpUrlOrNull

/** A process-local WebView route. Keep the listener bound while denied so a
 * previous browser override cannot fall back to direct or a recycled port. */
class BrowserPrivacyProxy internal constructor(
    private val createSocket: (Proxy) -> Socket,
    private val observeTarget: (HttpUrl, Boolean) -> Unit = { _, _ -> },
) : Closeable {
    constructor() : this({ Socket(it) })

    private data class Route(val socks: InetSocketAddress?)
    private class Connection(val browser: Socket, val route: Route) {
        var outbound: Socket? = null
    }

    private val lock = Any()
    private val active = mutableSetOf<Connection>()
    private val listener = ServerSocket().apply { bind(InetSocketAddress("127.0.0.1", 0), MAX_CONNECTIONS) }
    private val workers = ThreadPoolExecutor(0, MAX_CONNECTIONS * 2, 30, TimeUnit.SECONDS,
        SynchronousQueue()) { action -> Thread(action, "videre-browser-tunnel").apply { isDaemon = true } }
    private var route: Route? = null
    private var closed = false
    val url = "http://127.0.0.1:${listener.localPort}"
    private val acceptor = Thread(::accept, "videre-browser-accept").apply { isDaemon = true; start() }

    /** Replace the previous route and close its sockets before admitting new work. */
    fun allow(socksHost: String?, socksPort: Int?) {
        synchronized(lock) {
            revokeLocked()
            check(!closed && acceptor.isAlive) { "Browser privacy route is unavailable." }
            require((socksHost == null) == (socksPort == null))
            val socks = if (socksHost == null) null else {
                require(!socksHost.isBlank() && socksHost.none { it.code !in 33..126 || it in "/\\@?#%" } &&
                    socksPort != null && socksPort in 1..65535)
                val canonical = HttpUrl.Builder().scheme("http").host(socksHost).build().host
                require(!blockedBrowserHost(canonical))
                InetSocketAddress.createUnresolved(canonical, socksPort)
            }
            route = Route(socks)
        }
    }

    fun deny() = synchronized(lock) { revokeLocked() }

    override fun close() {
        synchronized(lock) {
            if (closed) return
            closed = true
            revokeLocked()
            closeQuietly(listener)
        }
        workers.shutdownNow()
    }

    private fun revokeLocked() {
        route = null
        active.forEach { closeSockets(it) }
        active.clear()
    }

    private fun accept() {
        while (!listener.isClosed) {
            val browser = try { listener.accept() } catch (_: IOException) { return }
            val connection = synchronized(lock) {
                route?.takeIf { active.size < MAX_CONNECTIONS }?.let {
                    Connection(browser, it).also { admitted -> active.add(admitted) }
                }
            }
            if (connection == null) {
                closeQuietly(browser)
                continue
            }
            try {
                workers.execute { serve(connection) }
            } catch (_: RejectedExecutionException) {
                finish(connection)
            }
        }
    }

    private fun finish(connection: Connection) = synchronized(lock) {
        active.remove(connection)
        closeSockets(connection)
    }

    private fun closeSockets(connection: Connection) {
        closeQuietly(connection.browser)
        closeQuietly(connection.outbound)
    }

    private fun serve(connection: Connection) {
        val browser = connection.browser
        var committed = false
        try {
            browser.soTimeout = HEADER_TIMEOUT_MS
            val input = BufferedInputStream(browser.getInputStream())
            val output = browser.getOutputStream()
            val request = BrowserRequest.read(input)
            val host = request.target.host
            val socks = connection.route.socks
            val allowed = !blockedBrowserHost(host) && (!host.trimEnd('.').endsWith(".onion") || socks != null)
            observeTarget(request.target, allowed)
            if (!allowed) {
                reply(output, "403 Forbidden")
                return
            }
            val outbound = synchronized(lock) {
                if (connection !in active) return
                createSocket(if (socks == null) Proxy.NO_PROXY else Proxy(Proxy.Type.SOCKS, socks)).also {
                    connection.outbound = it
                }
            }
            // Leave destination DNS with SOCKS when selected. Never retry direct.
            val address = if (socks == null) InetSocketAddress(host, request.target.port)
                else InetSocketAddress.createUnresolved(host, request.target.port)
            outbound.connect(address, CONNECT_TIMEOUT_MS)
            browser.soTimeout = TRANSFER_TIMEOUT_MS
            outbound.soTimeout = TRANSFER_TIMEOUT_MS
            val upstream = outbound.getOutputStream()
            if (request.connect) {
                committed = true
                output.write("HTTP/1.1 200 Connection established\r\n\r\n".toByteArray(Charsets.US_ASCII))
                output.flush()
                workers.execute {
                    try {
                        input.copyTo(upstream)
                        outbound.shutdownOutput()
                    } catch (_: IOException) {
                        finish(connection)
                    }
                }
            } else {
                upstream.write(request.originHeaders().toByteArray(Charsets.ISO_8859_1))
                upstream.flush()
                if (request.contentLength > 0) workers.execute {
                    try {
                        // Only this request body is forwarded, even if the browser
                        // sends more bytes on this connection.
                        copyBody(input, upstream, request.contentLength)
                    } catch (_: IOException) {
                        finish(connection)
                    }
                }
                committed = true
            }
            outbound.getInputStream().copyTo(output)
            output.flush()
        } catch (_: InvalidBrowserRequest) {
            if (!committed) errorReply(browser, "400 Bad Request")
        } catch (_: IOException) {
            if (!committed) errorReply(browser, "502 Bad Gateway")
        } catch (_: RejectedExecutionException) {
            if (!committed) errorReply(browser, "503 Service Unavailable")
        } finally {
            finish(connection)
        }
    }

    private companion object {
        const val MAX_CONNECTIONS = 24
        const val HEADER_TIMEOUT_MS = 5_000
        const val CONNECT_TIMEOUT_MS = 15_000
        const val TRANSFER_TIMEOUT_MS = 60_000

        fun blockedBrowserHost(host: String): Boolean = isOfficialYoutubeHost(host)

        fun closeQuietly(resource: Closeable?) { try { resource?.close() } catch (_: IOException) { } }

        fun errorReply(browser: Socket, status: String) {
            try { reply(browser.getOutputStream(), status) } catch (_: IOException) { }
        }

        fun reply(output: OutputStream, status: String) {
            output.write("HTTP/1.1 $status\r\nContent-Length: 0\r\nConnection: close\r\n\r\n"
                .toByteArray(Charsets.US_ASCII))
            output.flush()
        }

        fun copyBody(input: BufferedInputStream, output: OutputStream, length: Long) {
            var remaining = length
            val bytes = ByteArray(8192)
            while (remaining > 0) {
                val read = input.read(bytes, 0, minOf(bytes.size.toLong(), remaining).toInt())
                if (read < 0) throw InvalidBrowserRequest()
                output.write(bytes, 0, read)
                remaining -= read
            }
            output.flush()
        }
    }
}

private class InvalidBrowserRequest : IOException("Invalid WebView proxy request.")

private class BrowserRequest(
    val method: String,
    val target: HttpUrl,
    val headers: List<Pair<String, String>>,
    val contentLength: Long,
) {
    val connect: Boolean get() = method == "CONNECT"

    fun originHeaders(): String = buildString {
        append(method).append(' ').append(target.encodedPath)
        target.encodedQuery?.let { append('?').append(it) }
        append(" HTTP/1.1\r\nHost: ")
        append(if (':' in target.host) "[${target.host}]" else target.host)
        if (target.port != 80) append(':').append(target.port)
        append("\r\nConnection: close\r\n")
        val named = headers.filter { it.first.equals("Connection", ignoreCase = true) }
            .flatMap { it.second.split(',') }.map { it.trim().lowercase(Locale.ROOT) }.toSet()
        for ((name, value) in headers) {
            val lower = name.lowercase(Locale.ROOT)
            if (lower !in HOP_HEADERS && lower !in named && lower != "content-length") {
                append(name).append(": ").append(value).append("\r\n")
            }
        }
        if (headers.any { it.first.equals("Content-Length", ignoreCase = true) }) {
            append("Content-Length: ").append(contentLength).append("\r\n")
        }
        append("\r\n")
    }

    companion object {
        private const val MAX_HEADER_BYTES = 32 * 1024
        private const val MAX_BODY_BYTES = 16L * 1024 * 1024
        private val TOKEN = Regex("[!#%&'*+.^_`|~0-9A-Za-z\\$-]+")
        private val HOP_HEADERS = setOf("host", "connection", "proxy-connection", "keep-alive", "upgrade",
            "proxy-authorization", "proxy-authenticate", "te", "trailer", "transfer-encoding")

        fun read(input: BufferedInputStream): BrowserRequest {
            var bytes = 0
            val deadline = System.nanoTime() + TimeUnit.SECONDS.toNanos(5)
            fun readByte(): Int {
                if (++bytes > MAX_HEADER_BYTES || System.nanoTime() - deadline >= 0) throw InvalidBrowserRequest()
                return input.read().also { if (it < 0) throw InvalidBrowserRequest() }
            }
            fun line(): String = buildString {
                while (true) {
                    val byte = readByte()
                    if (byte == 13) {
                        if (readByte() != 10) throw InvalidBrowserRequest()
                        break
                    }
                    if (byte == 127 || (byte < 32 && byte != 9)) throw InvalidBrowserRequest()
                    append(byte.toChar())
                }
            }

            val start = line().split(' ')
            if (start.size != 3 || !TOKEN.matches(start[0]) || start[2] !in setOf("HTTP/1.0", "HTTP/1.1")) {
                throw InvalidBrowserRequest()
            }
            val method = start[0]
            val raw = start[1]
            val connect = method == "CONNECT"
            val scheme = if (connect) "https" else "http"
            val target = if (connect) {
                val port = raw.substringAfterLast(':', "").toIntOrNull() ?: throw InvalidBrowserRequest()
                if (port !in 1..65535) throw InvalidBrowserRequest()
                authority(raw, scheme)
            } else {
                if (!raw.startsWith("http://", ignoreCase = true) || raw.any { it.code !in 33..126 || it in "\\#" }) {
                    throw InvalidBrowserRequest()
                }
                val expected = authority(raw.substring(7).substringBefore('/').substringBefore('?'), scheme)
                val parsed = raw.toHttpUrlOrNull() ?: throw InvalidBrowserRequest()
                if (parsed.host != expected.host || parsed.port != expected.port) throw InvalidBrowserRequest()
                parsed
            }
            val headers = mutableListOf<Pair<String, String>>()
            while (true) {
                val header = line()
                if (header.isEmpty()) break
                val colon = header.indexOf(':')
                if (colon < 1) throw InvalidBrowserRequest()
                val name = header.substring(0, colon)
                if (!TOKEN.matches(name)) throw InvalidBrowserRequest()
                headers += name to header.substring(colon + 1).trim(' ', '\t')
            }
            fun values(name: String) = headers.filter { it.first.equals(name, ignoreCase = true) }.map { it.second }
            val host = values("Host").singleOrNull() ?: throw InvalidBrowserRequest()
            val expected = authority(host, scheme)
            if (expected.host != target.host || expected.port != target.port ||
                values("Transfer-Encoding").isNotEmpty() || values("Upgrade").isNotEmpty()) {
                throw InvalidBrowserRequest()
            }
            val lengths = values("Content-Length")
            val length = if (lengths.isEmpty()) 0 else {
                val value = lengths.singleOrNull() ?: throw InvalidBrowserRequest()
                if (value.isEmpty() || value.any { it !in '0'..'9' }) throw InvalidBrowserRequest()
                value.toLongOrNull() ?: throw InvalidBrowserRequest()
            }
            if (length > MAX_BODY_BYTES || (connect && length != 0L)) throw InvalidBrowserRequest()
            return BrowserRequest(method, target, headers, length)
        }

        private fun authority(value: String, scheme: String): HttpUrl {
            if (value.isEmpty() || value.any { it.code !in 33..126 || it in "/\\?#@%" }) throw InvalidBrowserRequest()
            return "$scheme://$value".toHttpUrlOrNull() ?: throw InvalidBrowserRequest()
        }
    }
}
