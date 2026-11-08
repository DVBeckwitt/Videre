package com.github.dvbeckwitt.videre.proxy

import android.content.Context
import androidx.test.ext.junit.runners.AndroidJUnit4
import androidx.test.platform.app.InstrumentationRegistry
import java.util.concurrent.TimeUnit
import okhttp3.Call
import okhttp3.Connection
import okhttp3.HttpUrl
import okhttp3.HttpUrl.Companion.toHttpUrl
import okhttp3.Interceptor
import okhttp3.MediaType.Companion.toMediaType
import okhttp3.Protocol
import okhttp3.Request
import okhttp3.RequestBody.Companion.toRequestBody
import okhttp3.Response
import okhttp3.ResponseBody.Companion.toResponseBody
import okio.ByteString.Companion.encodeUtf8
import org.junit.After
import org.junit.Assert.*
import org.junit.Before
import org.junit.Test
import org.junit.runner.RunWith

/** Real encrypted access store and native interceptors with fixture responses.
 * The terminal chain never creates a socket or contacts the public instance. */
@RunWith(AndroidJUnit4::class)
class NerdVpnTransportDeviceTest {
    private val target = InstrumentationRegistry.getInstrumentation().targetContext
    private val origin = "https://invidious.nerdvpn.de".toHttpUrl()
    private val account = GatewayContext("0247ed8b-e84e-5b9e-9ab6-aa534f64c033", origin)
    private val marker = "v1.${account.key}.${"https://invidious.nerdvpn.de".encodeUtf8().base64Url()}"
    private val fixtureKey = "nvpn_" + "N".repeat(32)
    private val rotatedKey = "nvpn_" + "R".repeat(32)
    private val preferences = target.getSharedPreferences(NERDVPN_PREFERENCES, Context.MODE_PRIVATE)
    private val preferenceName = "account_${account.key}"
    private var previousRecord: String? = null
    private var previousSessions: GatewayCookieAccess? = null

    @Before fun initializeFixture() {
        previousRecord = preferences.getString(preferenceName, null)
        previousSessions = GatewayCookieAccessRegistry.provider
        GatewayCookieAccessRegistry.provider = EmptySessions
        NerdVpnAccess.initialize(target)
        NerdVpnAccess.clear(account)
        NerdVpnAccess.setKey(account, fixtureKey)
    }

    @After fun restoreFixture() {
        GatewayCookieAccessRegistry.provider = previousSessions
        val edit = preferences.edit()
        if (previousRecord == null) edit.remove(preferenceName)
        else edit.putString(preferenceName, previousRecord)
        assertTrue(edit.commit())
    }

    @Test fun nativeRequestsInjectStoredKeyOnlyOnApprovedOriginAndRemoveInternalMarker() {
        var sent: Request? = null
        val original = request().newBuilder().header(GATEWAY_CONTEXT_HEADER, marker).build()
        GatewayTransportInterceptor().intercept(TestChain(original) {
            sent = it
            response(it, 200)
        }).close()
        assertEquals(fixtureKey, sent!!.header(NERDVPN_KEY_HEADER))
        assertNull(sent!!.header(GATEWAY_CONTEXT_HEADER))

        val external = prepareGatewayRequest(Request.Builder()
            .url("https://cdn.example/segment.ts").header(GATEWAY_CONTEXT_HEADER, marker).build())
        GatewayTransportInterceptor().intercept(TestChain(external) {
            sent = it
            response(it, 200)
        }).close()
        assertNull(sent!!.header(NERDVPN_KEY_HEADER))
        assertNull(sent!!.header(GATEWAY_CONTEXT_HEADER))

        NerdVpnAccess.clear(account)
        val stale = original.newBuilder().header(NERDVPN_KEY_HEADER, fixtureKey).build()
        assertThrows(NerdVpnAccessRequired::class.java) {
            GatewayTransportInterceptor().intercept(TestChain(stale) {
                error("A stale manual header must not revive a cleared account")
            })
        }
    }

    @Test fun staleReadFailureReusesRotatedKeyAndRetriesOnce() {
        val sent = mutableListOf<Request>()
        runInterceptors(request()) {
            sent.add(it)
            if (sent.size == 1) {
                rotateKeyForCurrentIdentity()
                response(it, 401, "invalid_credentials")
            } else response(it, 200)
        }.use { assertEquals(200, it.code) }
        assertEquals(2, sent.size)
        assertEquals(fixtureKey, sent.first().header(NERDVPN_KEY_HEADER))
        assertEquals(rotatedKey, sent.last().header(NERDVPN_KEY_HEADER))
        assertEquals("ready", NerdVpnAccess.status(account)["state"])
    }

    @Test fun writeFailureUpdatesAccessButNeverReplaysTheWrite() {
        var sent = 0
        runInterceptors(request().newBuilder().post("{}".toRequestBody("application/json".toMediaType())).build()) {
            sent++
            rotateKeyForCurrentIdentity()
            response(it, 401, "invalid_credentials")
        }.use { assertEquals(401, it.code) }
        assertEquals(1, sent)
        assertEquals(rotatedKey, NerdVpnAccess.resolve(account, origin.resolve("/api/v1/stats")!!).apiKey)
    }

    @Test fun repeatedReadKeyFailureStopsAndRequestsSignIn() {
        var sent = 0
        val exception = assertThrows(NerdVpnAccessRequired::class.java) {
            runInterceptors(request()) {
                sent++
                if (sent == 1) rotateKeyForCurrentIdentity()
                response(it, 401, "invalid_credentials")
            }
        }
        assertEquals(2, sent)
        assertEquals("signInRequired", exception.state)
        assertEquals("signInRequired", NerdVpnAccess.status(account)["state"])
    }

    @Test fun manualReplacementCannotReplayAnEarlierAccountRequest() {
        var sent = 0
        runInterceptors(request()) {
            sent++
            NerdVpnAccess.setKey(account, rotatedKey)
            response(it, 401, "invalid_credentials")
        }.use { assertEquals(401, it.code) }
        assertEquals(1, sent)
        assertEquals("ready", NerdVpnAccess.status(account)["state"])
        assertEquals(rotatedKey, NerdVpnAccess.resolve(account, origin.resolve("/api/v1/stats")!!).apiKey)
    }

    @Test fun credentialChangeBetweenRecoveryAndReplayStopsBeforeTheSecondRequest() {
        var networkAttempts = 0
        var sent = 0
        val newIdentityKey = "nvpn_" + "M".repeat(32)
        val exception = assertThrows(NerdVpnAccessRequired::class.java) {
            NerdVpnRecoveryInterceptor().intercept(TestChain(request()) { next ->
                networkAttempts++
                if (networkAttempts == 2) NerdVpnAccess.setKey(account, newIdentityKey)
                GatewayTransportInterceptor().intercept(TestChain(next) {
                    sent++
                    rotateKeyForCurrentIdentity()
                    response(it, 401, "invalid_credentials")
                })
            })
        }
        assertEquals("superseded", exception.state)
        assertEquals(2, networkAttempts)
        assertEquals(1, sent)
        assertEquals(newIdentityKey, NerdVpnAccess.resolve(account, origin.resolve("/api/v1/stats")!!).apiKey)
        assertEquals("ready", NerdVpnAccess.status(account)["state"])
    }

    @Test fun unavailableResponsePreservesKeyAndPausesFurtherNativeRequests() {
        var sent = 0
        val before = System.currentTimeMillis()
        val exception = assertThrows(NerdVpnAccessRequired::class.java) {
            runInterceptors(request()) {
                sent++
                response(it, 503, "unavailable").newBuilder().header("Retry-After", "60").build()
            }
        }
        assertEquals("unavailable", exception.state)
        val record = EncryptedNerdVpnStore(target).read(account)!!
        assertEquals(fixtureKey, record.key)
        assertTrue(record.retryAt!! >= before + 60_000)
        assertThrows(NerdVpnAccessRequired::class.java) {
            runInterceptors(request()) {
                sent++
                response(it, 200)
            }
        }
        assertEquals(1, sent)
    }

    private fun request() = prepareGatewayRequest(Request.Builder()
        .url("https://invidious.nerdvpn.de/api/v1/videos/fixture")
        .header(GATEWAY_CONTEXT_HEADER, marker).build())

    private fun rotateKeyForCurrentIdentity() {
        val store = EncryptedNerdVpnStore(target)
        val current = store.read(account)!!
        store.write(account, current.copy(key = rotatedKey, revision = current.revision + 1))
    }

    private fun runInterceptors(request: Request, terminal: (Request) -> Response): Response =
        NerdVpnRecoveryInterceptor().intercept(TestChain(request) { next ->
            GatewayTransportInterceptor().intercept(TestChain(next, terminal))
        })

    private fun response(request: Request, status: Int, error: String? = null): Response =
        Response.Builder().request(request).protocol(Protocol.HTTP_1_1).code(status)
            .message("Fixture response").header("Content-Type", "application/json")
            .body((if (error == null) "{}" else "{\"error\":\"$error\"}")
                .toResponseBody("application/json".toMediaType())).build()

    private object EmptySessions : GatewayCookieAccess {
        override fun resolve(context: GatewayContext, url: HttpUrl) = GatewayCookies(false, false)
        override fun ingest(context: GatewayContext, url: HttpUrl, cookies: List<String>,
            statusCode: Int, contentType: String?, location: String?, revision: Long?) = false
    }

    private class TestChain(private val original: Request, private val terminal: (Request) -> Response) : Interceptor.Chain {
        override fun request(): Request = original
        override fun proceed(request: Request): Response = terminal(request)
        override fun connection(): Connection? = null
        override fun call(): Call = error("No socket is used by the fixture transport")
        override fun connectTimeoutMillis(): Int = 1000
        override fun readTimeoutMillis(): Int = 1000
        override fun writeTimeoutMillis(): Int = 1000
        override fun withConnectTimeout(timeout: Int, unit: TimeUnit): Interceptor.Chain = this
        override fun withReadTimeout(timeout: Int, unit: TimeUnit): Interceptor.Chain = this
        override fun withWriteTimeout(timeout: Int, unit: TimeUnit): Interceptor.Chain = this
    }
}
