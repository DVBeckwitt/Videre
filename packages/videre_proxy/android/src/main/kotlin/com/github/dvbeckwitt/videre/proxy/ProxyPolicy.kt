package com.github.dvbeckwitt.videre.proxy

import java.io.IOException
import java.net.InetAddress
import java.net.InetSocketAddress
import java.net.Proxy
import java.net.ProxySelector
import java.net.ProtocolException
import java.net.SocketAddress
import java.net.URI
import java.net.UnknownHostException
import java.util.Locale
import java.util.concurrent.TimeUnit
import okhttp3.Call
import okhttp3.Callback
import okhttp3.Dns
import okhttp3.MediaType
import okhttp3.OkHttpClient
import okhttp3.Request
import okhttp3.Response
import okhttp3.ResponseBody
import okhttp3.HttpUrl
import okhttp3.HttpUrl.Companion.toHttpUrlOrNull
import okio.BufferedSource
import okio.ForwardingSource
import okio.buffer

internal data class ProxyPolicy(
    val enabled: Boolean = false,
    val host: String = "127.0.0.1",
    val port: Int = 9050,
) {
    init {
        require(!enabled || (host.isNotBlank() && host == host.trim() &&
            host.none { it.isWhitespace() || it == '/' || it == '@' || it == '?' || it == '#' } &&
            port in 1..65535)) { "A proxy host and port between 1 and 65535 are required." }
    }

    fun toMap(): Map<String, Any> = mapOf("enabled" to enabled, "host" to host, "port" to port)

    companion object {
        fun fromMap(values: Map<*, *>): ProxyPolicy {
            require(values["enabled"] is Boolean) { "Proxy enabled must be a boolean." }
            val host = values["host"] as? String
                ?: throw IllegalArgumentException("A proxy host is required.")
            val number = values["port"] as? Number
                ?: throw IllegalArgumentException("A proxy port is required.")
            require(number.toDouble() == number.toInt().toDouble()) { "Proxy port must be an integer." }
            return ProxyPolicy(values["enabled"] as Boolean, host, number.toInt())
        }
    }
}

// Do not resolve names to decide whether to bypass Tor. In particular, RFC1918
// addresses and public hosts that resolve to loopback are not implicit bypasses.
internal fun isLoopbackHost(input: String): Boolean {
    val host = input.removeSurrounding("[", "]").lowercase(Locale.ROOT)
    if (host == "localhost" || host == "::1" || host == "0:0:0:0:0:0:0:1") return true
    val octets = host.split('.')
    return octets.size == 4 && octets[0] == "127" && octets.all {
        it.isNotEmpty() && it.all(Char::isDigit) && (it.toIntOrNull() ?: -1) in 0..255
    }
}

internal class SocksOnlySelector(policy: ProxyPolicy) : ProxySelector() {
    private val proxy = Proxy(Proxy.Type.SOCKS, InetSocketAddress.createUnresolved(policy.host, policy.port))

    override fun select(uri: URI): List<Proxy> =
        listOf(if (isLoopbackHost(uri.host ?: "")) Proxy.NO_PROXY else proxy)

    override fun connectFailed(uri: URI?, address: SocketAddress?, error: IOException?) {
        // A failed SOCKS route stays failed. Never add DIRECT as a fallback.
    }
}

/** Media3 creates independent calls for manifest children, so their credential
 * origin must be anchored to the original media source rather than each call. */
private data class SourceHeaderScope(val origin: HttpUrl?, val names: Set<String>)

private fun sameOrigin(left: HttpUrl, right: HttpUrl): Boolean =
    left.scheme == right.scheme && left.host == right.host && left.port == right.port

/** Keeps a live policy for sources that were created before a settings change. */
internal class PolicyCallFactory : Call.Factory {
    private val lock = Any()
    private var client: OkHttpClient? = null
    private val calls = mutableSetOf<Call>()

    fun configure(policy: ProxyPolicy) {
        val builder = OkHttpClient.Builder()
            .connectTimeout(15, TimeUnit.SECONDS)
            .readTimeout(30, TimeUnit.SECONDS)
            .retryOnConnectionFailure(false)
            .addNetworkInterceptor { chain ->
                var outgoing = chain.request()
                val scope = outgoing.tag(SourceHeaderScope::class.java)
                val initial = scope?.origin ?: chain.call().request().url
                val destination = outgoing.url
                if ((scope != null && scope.origin == null) || !sameOrigin(destination, initial)) {
                    // Scope instance credentials to their original origin for
                    // media segments and API requests, including redirects.
                    outgoing = outgoing.newBuilder().apply {
                        (listOf("Authorization", "Proxy-Authorization", "Cookie", "Cookie2", "WWW-Authenticate") +
                            (scope?.names ?: emptySet()))
                            .forEach { removeHeader(it) }
                    }.build()
                }
                chain.proceed(outgoing)
            }
        if (policy.enabled) {
            builder.proxySelector(SocksOnlySelector(policy))
            // OkHttp passes an unresolved origin address to Java's SOCKS socket.
            // This guard also catches a future accidental direct-DNS regression.
            builder.dns(object : Dns {
                override fun lookup(hostname: String): List<InetAddress> =
                    if (isLoopbackHost(hostname)) Dns.SYSTEM.lookup(hostname)
                    else throw UnknownHostException("Direct DNS is disabled while SOCKS5 is enabled.")
            })
        }
        val nextClient = builder.build()
        synchronized(lock) {
            invalidateLocked()
            client = nextClient
        }
    }

    fun block() = synchronized(lock) {
        invalidateLocked()
        client = null
    }

    private fun invalidateLocked() {
        // Dispatcher.cancelAll() alone misses calls whose response headers have
        // arrived but whose media body is still being read by ExoPlayer.
        calls.toList().forEach(Call::cancel)
        calls.clear()
        client?.connectionPool?.evictAll()
    }

    override fun newCall(request: Request): Call = synchronized(lock) {
        val active = client ?: throw IOException("SOCKS5 transport settings have not been loaded or are invalid.")
        trackCall(active.newCall(request))
    }

    fun forSource(sourceUri: String?, headerNames: Set<String>): Call.Factory {
        val scope = SourceHeaderScope(sourceUri?.toHttpUrlOrNull(), headerNames.toSet())
        return object : Call.Factory {
            override fun newCall(request: Request): Call = this@PolicyCallFactory.newCall(
                request.newBuilder().tag(SourceHeaderScope::class.java, scope).build(),
            )
        }
    }

    fun newApiCall(request: Request, options: ApiRedirectOptions): Call = synchronized(lock) {
        val active = client ?: throw IOException("SOCKS5 transport settings have not been loaded or are invalid.")
        // Instance access controls can use arbitrary header names, not only
        // Authorization or Cookie. Anchor all caller-provided headers before
        // OkHttp adds transport headers such as Host and Accept-Encoding.
        val scopedRequest = request.newBuilder().tag(
            SourceHeaderScope::class.java,
            SourceHeaderScope(request.url, request.headers.names().toSet()),
        ).build()
        val builder = active.newBuilder().followRedirects(options.followRedirects)
        var redirects = 0
        builder.addNetworkInterceptor { chain ->
            val response = chain.proceed(chain.request())
            if (options.followRedirects) {
                val location = response.header("Location")
                if (response.isRedirect && location != null && response.request.url.resolve(location) != null) {
                    if (redirects++ >= options.maxRedirects) {
                        response.close()
                        throw ProtocolException("Maximum HTTP redirects exceeded.")
                    }
                }
            }
            response
        }
        trackCall(builder.build().newCall(scopedRequest))
    }

    private fun trackCall(call: Call): Call {
        calls.add(call)
        return TrackedCall(call)
    }

    private inner class TrackedCall(private val delegate: Call) : Call by delegate {
        private fun completed() = synchronized(lock) { calls.remove(delegate) }

        override fun execute(): Response = try {
            trackBody(delegate.execute())
        } catch (error: IOException) {
            completed()
            throw error
        }

        override fun enqueue(callback: Callback) {
            delegate.enqueue(object : Callback {
                override fun onFailure(call: Call, error: IOException) {
                    completed()
                    callback.onFailure(this@TrackedCall, error)
                }

                override fun onResponse(call: Call, response: Response) {
                    callback.onResponse(this@TrackedCall, trackBody(response))
                }
            })
        }

        override fun cancel() {
            delegate.cancel()
            completed()
        }

        override fun clone(): Call = newCall(delegate.request())

        private fun trackBody(response: Response): Response {
            val body = response.body
            if (body == null) {
                completed()
                return response
            }
            val source = object : ForwardingSource(body.source()) {
                override fun read(sink: okio.Buffer, byteCount: Long): Long = try {
                    super.read(sink, byteCount).also { if (it == -1L) completed() }
                } catch (error: IOException) {
                    completed()
                    throw error
                }

                override fun close() {
                    try {
                        super.close()
                    } finally {
                        completed()
                    }
                }
            }.buffer()
            val tracked = object : ResponseBody() {
                override fun contentType(): MediaType? = body.contentType()
                override fun contentLength(): Long = body.contentLength()
                override fun source(): BufferedSource = source
            }
            return response.newBuilder().body(tracked).build()
        }
    }
}
