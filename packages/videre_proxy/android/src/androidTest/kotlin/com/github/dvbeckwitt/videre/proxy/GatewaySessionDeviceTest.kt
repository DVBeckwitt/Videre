package com.github.dvbeckwitt.videre.proxy

import android.content.Context
import androidx.test.ext.junit.runners.AndroidJUnit4
import androidx.test.platform.app.InstrumentationRegistry
import androidx.webkit.ProfileStore
import java.util.concurrent.CountDownLatch
import java.util.concurrent.TimeUnit
import okhttp3.HttpUrl.Companion.toHttpUrl
import okio.ByteString.Companion.encodeUtf8
import org.junit.After
import org.junit.Assert.*
import org.junit.Before
import org.junit.Test
import org.junit.runner.RunWith

/** Real Chromium cookie store, synthetic HTTPS URLs; no external credentials. */
@RunWith(AndroidJUnit4::class)
class GatewaySessionDeviceTest {
    private val instrumentation = InstrumentationRegistry.getInstrumentation()
    private val url = "https://gateway-fixture.example/api/v1/stats".toHttpUrl()
    private val first = account("0247ed8b-e84e-5b9e-9ab6-aa534f64c011")
    private val second = account("0247ed8b-e84e-5b9e-9ab6-aa534f64c012")

    private fun account(key: String) = GatewayContext.parse(
        "v1.$key.${"https://gateway-fixture.example".encodeUtf8().base64Url()}")

    @Before fun initialize() {
        GatewaySessions.initialize(instrumentation.targetContext)
    }

    @After fun clear() {
        GatewaySessions.signOut(first)
        GatewaySessions.signOut(second)
    }

    @Test fun accountCookiesRemainIsolatedAndRespectPaths() {
        if (!GatewaySessions.supported()) {
            assertEquals(false, GatewaySessions.status(first)["supported"])
            assertThrows(GatewaySessionUnavailable::class.java) { GatewaySessions.beginSignIn(first) }
            return
        }
        val firstRevision = GatewaySessions.beginSignIn(first)
        val secondRevision = GatewaySessions.beginSignIn(second)
        setCookie(first, firstRevision, "authentik_proxy_fixture=alice; Path=/; Secure; HttpOnly")
        setCookie(first, firstRevision, "api_only=private; Path=/api/; Secure; HttpOnly")
        setCookie(second, secondRevision, "authentik_proxy_fixture=bob; Path=/; Secure; HttpOnly")
        assertTrue(GatewaySessions.completeSignIn(first, firstRevision))
        assertTrue(GatewaySessions.completeSignIn(second, secondRevision))

        val alice = GatewaySessions.resolve(first, url)
        val bob = GatewaySessions.resolve(second, url)
        assertTrue(alice.cookies.orEmpty().contains("authentik_proxy_fixture=alice"))
        assertTrue(alice.cookies.orEmpty().contains("api_only=private"))
        assertFalse(alice.cookies.orEmpty().contains("bob"))
        assertTrue(bob.cookies.orEmpty().contains("authentik_proxy_fixture=bob"))
        assertFalse(bob.cookies.orEmpty().contains("alice"))
        val image = GatewaySessions.resolve(first, "https://gateway-fixture.example/thumbnail.jpg".toHttpUrl())
        assertFalse(image.cookies.orEmpty().contains("api_only"))
        assertFalse(GatewaySessions.resolve(first, "https://external.example/segment.ts".toHttpUrl()).enabled)

        GatewaySessions.signOut(first)
        assertFalse(GatewaySessions.resolve(first, url).enabled)
        assertTrue(GatewaySessions.resolve(second, url).cookies.orEmpty().contains("bob"))
    }

    @Test fun expiredAndLateResponsesCannotRestoreAnOldSession() {
        if (!GatewaySessions.supported()) {
            assertEquals(false, GatewaySessions.status(first)["enabled"])
            return
        }
        val oldRevision = GatewaySessions.beginSignIn(first)
        setCookie(first, oldRevision, "authentik_proxy_fixture=old; Path=/; Secure; HttpOnly")
        assertTrue(GatewaySessions.completeSignIn(first, oldRevision))
        GatewaySessions.signOut(first)
        val newRevision = GatewaySessions.beginSignIn(first)
        setCookie(first, newRevision, "authentik_proxy_fixture=new; Path=/; Secure; HttpOnly")
        assertTrue(GatewaySessions.completeSignIn(first, newRevision))
        GatewaySessions.signOut(first, oldRevision)
        assertTrue("An older logout must not revoke the new sign-in", GatewaySessions.resolve(first, url).enabled)
        assertFalse(GatewaySessions.ingest(first, url,
            listOf("authentik_proxy_fixture=stale; Path=/; Secure; HttpOnly"),
            200, "application/json", null, oldRevision))
        assertTrue(GatewaySessions.resolve(first, url).cookies.orEmpty().contains("=new"))
        assertTrue(GatewaySessions.ingest(first, url, emptyList(), 302, null,
            "https://identity.example/if/flow/login/", newRevision))
        assertTrue(GatewaySessions.resolve(first, url).needsSignIn)
        assertEquals(true, GatewaySessions.status(first)["enabled"])
        val cancelled = GatewaySessions.beginSignIn(first)
        GatewaySessions.cancelSignIn(first, cancelled)
        GatewaySessions.signOut(first, cancelled)
        assertFalse("Logout may finish revocation after closing its own pending login", GatewaySessions.resolve(first, url).enabled)
    }

    @Test fun anotherEngineInitializationDoesNotCancelAnActiveReauthentication() {
        if (!GatewaySessions.supported()) return
        val saved = GatewaySessions.beginSignIn(first)
        setCookie(first, saved, "authentik_proxy_fixture=previous; Path=/; Secure; HttpOnly")
        assertTrue(GatewaySessions.completeSignIn(first, saved))
        val pending = GatewaySessions.beginSignIn(first)

        GatewaySessions.initialize(instrumentation.targetContext)

        assertEquals(pending, GatewaySessions.status(first)["revision"])
        assertTrue(GatewaySessions.resolve(first, url).needsSignIn)
        setCookie(first, pending, "authentik_proxy_fixture=latest; Path=/; Secure; HttpOnly")
        assertTrue(GatewaySessions.completeSignIn(first, pending))
        assertTrue(GatewaySessions.resolve(first, url).cookies.orEmpty().contains("=latest"))
    }

    @Test fun readingSavedCookiesRestoresTheProfileWorkerNetworkBlock() {
        if (!GatewaySessions.supported()) return
        val revision = GatewaySessions.beginSignIn(first)
        val profileName = GatewaySessions.signInProfileName(first, revision)
        setCookie(first, revision, "authentik_proxy_fixture=retained; Path=/; Secure; HttpOnly")
        assertTrue(GatewaySessions.completeSignIn(first, revision))
        instrumentation.runOnMainSync {
            // Model process-local settings resetting while the saved cookie profile survives.
            ProfileStore.getInstance().getOrCreateProfile(profileName)
                .serviceWorkerController.serviceWorkerWebSettings.blockNetworkLoads = false
        }
        assertTrue(GatewaySessions.resolve(first, url).cookies.orEmpty().contains("=retained"))
        instrumentation.runOnMainSync {
            assertTrue(ProfileStore.getInstance().getOrCreateProfile(profileName)
                .serviceWorkerController.serviceWorkerWebSettings.blockNetworkLoads)
        }
    }

    @Test fun missingPendingProfileCanBeRevokedWithoutRecreatingIt() {
        if (!GatewaySessions.supported()) return
        val profileName = "${first.profileName}_missing"
        instrumentation.runOnMainSync {
            assertFalse(ProfileStore.getInstance().allProfileNames.contains(profileName))
        }
        // Model a pending profile that Chromium did not persist before process death.
        val preferences = instrumentation.targetContext
            .getSharedPreferences("videre_gateway_sessions", Context.MODE_PRIVATE)
        assertTrue(preferences.edit().putBoolean("pending_${first.key}", true)
            .putString("pendingProfile_${first.key}", profileName).commit())
        assertTrue(GatewaySessions.resolve(first, url).needsSignIn)

        GatewaySessions.signOut(first)

        assertFalse(GatewaySessions.resolve(first, url).enabled)
        instrumentation.runOnMainSync {
            assertFalse("Cleanup must not recreate a missing profile", ProfileStore.getInstance().allProfileNames.contains(profileName))
        }
    }

    private fun setCookie(account: GatewayContext, revision: Long, value: String) {
        val finished = CountDownLatch(1)
        instrumentation.runOnMainSync {
            ProfileStore.getInstance().getOrCreateProfile(GatewaySessions.signInProfileName(account, revision)).cookieManager
                .setCookie(url.toString(), value) { finished.countDown() }
        }
        assertTrue("Fixture cookie creation timed out", finished.await(10, TimeUnit.SECONDS))
    }
}
