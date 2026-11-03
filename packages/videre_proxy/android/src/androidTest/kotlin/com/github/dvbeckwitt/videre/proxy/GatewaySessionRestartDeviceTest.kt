package com.github.dvbeckwitt.videre.proxy

import androidx.test.ext.junit.runners.AndroidJUnit4
import androidx.test.platform.app.InstrumentationRegistry
import androidx.webkit.ProfileStore
import java.util.concurrent.CountDownLatch
import java.util.concurrent.TimeUnit
import okhttp3.HttpUrl.Companion.toHttpUrl
import okio.ByteString.Companion.encodeUtf8
import org.junit.Assert.*
import org.junit.Test
import org.junit.runner.RunWith

/** Run with gateway_phase=seed then gateway_phase=check in separate processes. */
@RunWith(AndroidJUnit4::class)
class GatewaySessionRestartDeviceTest {
    @Test fun profileCookieStoreSurvivesProcessRestart() {
        val instrumentation = InstrumentationRegistry.getInstrumentation()
        val account = GatewayContext.parse("v1.0247ed8b-e84e-5b9e-9ab6-aa534f64c013." +
            "https://gateway-fixture.example".encodeUtf8().base64Url())
        val url = "https://gateway-fixture.example/api/v1/stats".toHttpUrl()
        GatewaySessions.initialize(instrumentation.targetContext)
        if (!GatewaySessions.supported()) {
            assertEquals(false, GatewaySessions.status(account)["supported"])
            return
        }
        val phase = InstrumentationRegistry.getArguments().getString("gateway_phase")
        if (phase != "check") {
            GatewaySessions.signOut(account)
            val revision = GatewaySessions.beginSignIn(account)
            val saved = CountDownLatch(1)
            instrumentation.runOnMainSync {
                ProfileStore.getInstance().getOrCreateProfile(GatewaySessions.signInProfileName(account, revision))
                    .cookieManager.setCookie(url.toString(),
                        "authentik_proxy_fixture=persisted; Max-Age=3600; Path=/; Secure; HttpOnly") { saved.countDown() }
            }
            assertTrue(saved.await(10, TimeUnit.SECONDS))
            assertTrue(GatewaySessions.completeSignIn(account, revision))
        }
        assertTrue(GatewaySessions.resolve(account, url).cookies.orEmpty().contains("authentik_proxy_fixture=persisted"))
        if (phase != "seed") GatewaySessions.signOut(account)
    }
}
