package com.github.dvbeckwitt.videre.proxy

import android.webkit.CookieManager
import android.webkit.WebView
import androidx.test.ext.junit.runners.AndroidJUnit4
import androidx.test.platform.app.InstrumentationRegistry
import androidx.webkit.ProfileStore
import androidx.webkit.WebViewCompat
import androidx.webkit.WebViewFeature
import java.util.UUID
import java.util.concurrent.CountDownLatch
import java.util.concurrent.TimeUnit
import java.util.concurrent.atomic.AtomicBoolean
import java.util.concurrent.atomic.AtomicInteger
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test
import org.junit.runner.RunWith

/** Only random profiles in the isolated library test host, with fixture cookies. */
@RunWith(AndroidJUnit4::class)
class BrowserProfileCleanupDeviceTest {
    private val instrumentation = InstrumentationRegistry.getInstrumentation()
    private val origin = "https://signin-fixture.invalid/"

    @Test(timeout = 30_000)
    fun loadedTokenProfileClearsAfterWebViewDestructionWithoutClearingSavedProfile() {
        assertTrue(WebViewFeature.isFeatureSupported(WebViewFeature.MULTI_PROFILE))
        val prefix = "videre_auth_cleanup_fixture_${UUID.randomUUID()}"
        val temporaryName = "${prefix}_token"
        val managers = mutableListOf<CookieManager>()
        val seeded = CountDownLatch(2)
        val cleared = CountDownLatch(1)
        val successful = AtomicBoolean(false)
        val completions = AtomicInteger()
        try {
            instrumentation.runOnMainSync {
                val profiles = ProfileStore.getInstance()
                for (name in listOf(temporaryName, "${prefix}_saved")) {
                    val profile = profiles.getOrCreateProfile(name)
                    profile.serviceWorkerController.serviceWorkerWebSettings.blockNetworkLoads = true
                    managers.add(profile.cookieManager)
                    profile.cookieManager.setCookie(origin, "session=fixture; Secure; Path=/") {
                        seeded.countDown()
                    }
                }
                val browser = WebView(instrumentation.targetContext)
                BrowserPrivacySettings.apply(browser)
                WebViewCompat.setProfile(browser, temporaryName)
                browser.destroy()
            }
            assertTrue("Fixture cookies were not written", seeded.await(5, TimeUnit.SECONDS))
            instrumentation.runOnMainSync {
                assertTrue(managers[0].getCookie(origin).orEmpty().contains("session=fixture"))
                GatewaySessions.clearTemporaryBrowserProfile(temporaryName) { success ->
                    successful.set(success)
                    completions.incrementAndGet()
                    cleared.countDown()
                }
            }
            assertTrue("Temporary profile cleanup did not complete", cleared.await(10, TimeUnit.SECONDS))
            assertTrue("A loaded, detached token profile must support clearing", successful.get())
            assertEquals(1, completions.get())
            instrumentation.runOnMainSync {
                assertFalse(managers[0].getCookie(origin).orEmpty().contains("session=fixture"))
                assertTrue("A separate saved account must keep its cookie",
                    managers[1].getCookie(origin).orEmpty().contains("session=fixture"))
            }
        } finally {
            val removed = CountDownLatch(managers.size)
            instrumentation.runOnMainSync {
                managers.forEach { manager -> manager.removeAllCookies { removed.countDown() } }
            }
            assertTrue(removed.await(5, TimeUnit.SECONDS))
        }
    }

    @Test(timeout = 15_000)
    fun absentTemporaryProfileCompletesWithoutCreatingBrowserState() {
        val name = "videre_auth_cleanup_missing_${UUID.randomUUID()}"
        val completed = CountDownLatch(1)
        val successful = AtomicBoolean(false)
        instrumentation.runOnMainSync {
            GatewaySessions.clearTemporaryBrowserProfile(name) {
                successful.set(it)
                completed.countDown()
            }
        }
        assertTrue(completed.await(5, TimeUnit.SECONDS))
        assertTrue(successful.get())
        instrumentation.runOnMainSync {
            assertFalse(ProfileStore.getInstance().allProfileNames.contains(name))
        }
    }
}
