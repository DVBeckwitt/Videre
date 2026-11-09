package com.github.dvbeckwitt.videre.proxy

import java.util.concurrent.TimeUnit
import okhttp3.Call
import okhttp3.Connection
import okhttp3.Interceptor
import okhttp3.Protocol
import okhttp3.Request
import okhttp3.Response
import okhttp3.ResponseBody.Companion.toResponseBody
import okhttp3.HttpUrl.Companion.toHttpUrl
import okio.ByteString.Companion.encodeUtf8
import org.junit.After
import org.junit.Assert.*
import org.junit.Test

class GatewayTransportTest {
    private val onionHost = "nerdvpneaggggfdiurknszkbmhvjndks5z5k3g5yp4nhphflh3n3boad.onion"
    private val key = "8c9502ae-b933-5fa1-a75d-c6d85c2ec021"
    private val marker = "v1.$key.${"https://instance.example".encodeUtf8().base64Url()}"
    private val context = GatewayContext.parse(marker)

    @After fun reset() { GatewayCookieAccessRegistry.provider = null }

    @Test fun `context rejects insecure origins credentials and malformed identity`() {
        for (origin in listOf("http://instance.example", "https://user:secret@instance.example", "https://instance.example/path")) {
            assertThrows(IllegalArgumentException::class.java) {
                GatewayContext.parse("v1.$key.${origin.encodeUtf8().base64Url()}")
            }
        }
        assertThrows(IllegalArgumentException::class.java) { GatewayContext.parse("v1.bad.key") }
        assertTrue(context.allows("https://instance.example/api/v1/videos/video".toHttpUrl()))
        assertFalse(context.allows("https://instance.example:8443/api/v1/videos/video".toHttpUrl()))
        assertFalse(context.allows("https://other.example/api/v1/videos/video".toHttpUrl()))
    }

    @Test fun `official onion context allows only its exact scheme host and port`() {
        for (scheme in listOf("http", "https")) {
            val origin = "$scheme://$onionHost"
            val onion = GatewayContext.parse("v1.$key.${origin.encodeUtf8().base64Url()}")
            assertTrue(onion.allows("$origin/api/v1/videos/video".toHttpUrl()))
            for (target in listOf("https://invidious.nerdvpn.de/api/v1/videos/video",
                "$scheme://other.onion/api/v1/videos/video", "$scheme://sub.$onionHost/api/v1/videos/video",
                "$scheme://$onionHost:8443/api/v1/videos/video", "$scheme://user@$onionHost/api/v1/videos/video",
                "${if (scheme == "http") "https" else "http"}://$onionHost/api/v1/videos/video")) {
                assertFalse(target, onion.allows(target.toHttpUrl()))
            }
        }
        for (origin in listOf("http://other.onion", "http://sub.$onionHost", "http://$onionHost.attacker.example",
            "http://$onionHost:81", "http://user:secret@$onionHost", "http://$onionHost/path")) {
            assertThrows(origin, IllegalArgumentException::class.java) {
                GatewayContext.parse("v1.$key.${origin.encodeUtf8().base64Url()}")
            }
        }
    }

    @Test fun `onion token bootstrap keeps account scope and strips internal marker`() {
        val origin = "http://$onionHost"
        val onionMarker = "v1.$key.${origin.encodeUtf8().base64Url()}"
        val cookies = FakeSessions()
        GatewayCookieAccessRegistry.provider = cookies
        val chain = Chain(Request.Builder().url("$origin/api/v1/token")
            .header(GATEWAY_CONTEXT_HEADER, onionMarker)
            .header("Authorization", "Bearer fixture-token").build())
        GatewayTransportInterceptor().intercept(chain).close()
        assertEquals("Bearer fixture-token", chain.sent!!.header("Authorization"))
        assertNull(chain.sent!!.header(GATEWAY_CONTEXT_HEADER))
        assertEquals(listOf(key), cookies.resolved)

        cookies.resolved.clear()
        val onion = GatewayContext.parse(onionMarker)
        for (url in listOf("https://invidious.nerdvpn.de/api/v1/token", "https://$onionHost/api/v1/token",
            "http://other.onion/api/v1/token")) {
            val other = Chain(prepareGatewayRequest(Request.Builder().url(url).build(), onion))
            GatewayTransportInterceptor().intercept(other).close()
            assertNull(other.sent!!.header("Cookie"))
            assertNull(other.sent!!.header(NERDVPN_KEY_HEADER))
        }
        assertTrue(cookies.resolved.isEmpty())
    }

    @Test fun `marker never reaches wire and explicit Invidious cookie wins`() {
        val cookies = FakeSessions()
        GatewayCookieAccessRegistry.provider = cookies
        val request = Request.Builder().url("https://instance.example/api/v1/auth/history")
            .header(GATEWAY_CONTEXT_HEADER, marker).header("Cookie", "SID=app-session; preference=dark")
            .header("Authorization", "Bearer app-token").build()
        val chain = Chain(request)
        GatewayTransportInterceptor().intercept(chain).close()
        val sent = chain.sent!!
        assertNull(sent.header(GATEWAY_CONTEXT_HEADER))
        assertEquals("authentik_proxy_session=gateway; SID=app-session; preference=dark", sent.header("Cookie"))
        assertEquals("Bearer app-token", sent.header("Authorization"))
        assertEquals(listOf(context.key), cookies.resolved)
        assertEquals(7L, cookies.ingestedRevision)
    }

    @Test fun `gateway cookies are not looked up for media on another origin`() {
        val cookies = FakeSessions()
        GatewayCookieAccessRegistry.provider = cookies
        val request = prepareGatewayRequest(Request.Builder().url("https://cdn.example/segment.ts").build(), context)
        val chain = Chain(request)
        GatewayTransportInterceptor().intercept(chain).close()
        assertNull(chain.sent!!.header("Cookie"))
        assertNull(chain.sent!!.header(GATEWAY_CONTEXT_HEADER))
        assertTrue(cookies.resolved.isEmpty())
    }

    @Test fun `raw repeated Set-Cookie values retain expiry commas and revisions`() {
        val cookies = FakeSessions()
        GatewayCookieAccessRegistry.provider = cookies
        val request = Request.Builder().url("https://instance.example/api/v1/stats")
            .header(GATEWAY_CONTEXT_HEADER, marker).build()
        val values = listOf("authentik_proxy_session=new; Expires=Wed, 01 Jan 2031 00:00:00 GMT; Secure; HttpOnly", "preference=dark; Path=/")
        val chain = Chain(request, values)
        GatewayTransportInterceptor().intercept(chain).close()
        assertEquals(values, cookies.received)
        assertEquals(7L, cookies.ingestedRevision)
    }

    @Test fun `revoked session fails before request is sent`() {
        val cookies = FakeSessions().apply { expired = true }
        GatewayCookieAccessRegistry.provider = cookies
        val request = Request.Builder().url("https://instance.example/api/v1/stats")
            .header(GATEWAY_CONTEXT_HEADER, marker).build()
        val chain = Chain(request)
        assertThrows(GatewayAuthenticationRequired::class.java) { GatewayTransportInterceptor().intercept(chain) }
        assertNull(chain.sent)
    }

    @Test fun `login redirect and HTML are auth failures but Invidious JSON 401 and media redirects are not`() {
        val url = "https://instance.example/api/v1/auth/history".toHttpUrl()
        assertTrue(gatewayRequiresSignIn(url, 302, null, "https://auth.example/if/flow/default-authentication-flow/"))
        assertTrue(gatewayRequiresSignIn(url, 200, "text/html; charset=utf-8", null))
        assertTrue(gatewayRequiresSignIn(url, 401, "text/html", null))
        assertFalse(gatewayRequiresSignIn(url, 401, "application/json", null))
        assertFalse(gatewayRequiresSignIn(url, 302, null, "https://r1.googlevideo.com/videoplayback"))
    }

    private class FakeSessions : GatewayCookieAccess {
        var expired = false
        val resolved = mutableListOf<String>()
        var received = emptyList<String>()
        var ingestedRevision: Long? = null
        override fun resolve(context: GatewayContext, url: okhttp3.HttpUrl): GatewayCookies {
            resolved.add(context.key)
            return GatewayCookies(true, expired, "authentik_proxy_session=gateway; SID=browser-session", 7)
        }
        override fun ingest(context: GatewayContext, url: okhttp3.HttpUrl, cookies: List<String>,
            statusCode: Int, contentType: String?, location: String?, revision: Long?): Boolean {
            received = cookies
            ingestedRevision = revision
            return false
        }
    }

    private class Chain(private val original: Request, private val cookies: List<String> = emptyList()) : Interceptor.Chain {
        var sent: Request? = null
        override fun request(): Request = original
        override fun proceed(request: Request): Response {
            sent = request
            return Response.Builder().request(request).protocol(Protocol.HTTP_1_1).code(200).message("OK")
                .apply { cookies.forEach { addHeader("Set-Cookie", it) } }.body("{}".toResponseBody()).build()
        }
        override fun connection(): Connection? = null
        override fun call(): Call = error("No socket is used by this boundary test.")
        override fun connectTimeoutMillis(): Int = 1000
        override fun readTimeoutMillis(): Int = 1000
        override fun writeTimeoutMillis(): Int = 1000
        override fun withConnectTimeout(timeout: Int, unit: TimeUnit): Interceptor.Chain = this
        override fun withReadTimeout(timeout: Int, unit: TimeUnit): Interceptor.Chain = this
        override fun withWriteTimeout(timeout: Int, unit: TimeUnit): Interceptor.Chain = this
    }
}
