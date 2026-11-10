package com.github.dvbeckwitt.videre.proxy

import android.os.Handler
import android.os.Looper
import android.webkit.WebResourceError
import android.webkit.WebResourceRequest
import android.webkit.WebView
import android.webkit.WebViewClient
import androidx.test.ext.junit.runners.AndroidJUnit4
import androidx.test.platform.app.InstrumentationRegistry
import androidx.webkit.ProxyConfig
import androidx.webkit.ProxyController
import androidx.webkit.ProfileStore
import androidx.webkit.ServiceWorkerControllerCompat
import androidx.webkit.WebViewCompat
import androidx.webkit.WebViewFeature
import okhttp3.HttpUrl.Companion.toHttpUrl
import java.io.IOException
import java.net.InetSocketAddress
import java.net.ServerSocket
import java.net.Socket
import java.util.concurrent.ConcurrentHashMap
import java.util.concurrent.CountDownLatch
import java.util.concurrent.Executor
import java.util.concurrent.TimeUnit
import java.util.concurrent.atomic.AtomicBoolean
import java.util.concurrent.atomic.AtomicReference
import org.junit.Assert.assertFalse
import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Test
import org.junit.runner.RunWith

/** Real Chromium in the library test host. The dial observer permits only the local fixture. */
@RunWith(AndroidJUnit4::class)
class BrowserPrivacyDeviceTest {
    private val instrumentation = InstrumentationRegistry.getInstrumentation()
    private val executor = Executor { Handler(Looper.getMainLooper()).post(it) }
    private val officialHosts = setOf("music.youtube.com", "www.youtube-nocookie.com", "i.ytimg.com", "www.youtube.com")

    private class Attempt(blocks: Int) {
        val refused = CountDownLatch(blocks)
        val blocked = ConcurrentHashMap.newKeySet<String>()
        val allowedPaths = ConcurrentHashMap.newKeySet<String>()
    }

    @Test(timeout = 45_000)
    fun realWebViewFiltersMusicFetchIframeImageAndRedirect() = verifyBrowser(profileName = null)

    @Test(timeout = 60_000)
    fun isolatedWebViewKeepsFilteringWhenReopened() {
        assertTrue(WebViewFeature.isFeatureSupported(WebViewFeature.MULTI_PROFILE))
        verifyBrowser(profileName = "videre_browser_privacy_fixture")
    }

    @Test(timeout = 60_000)
    fun pageScriptsStayDisabledAndNativePageReadsPreserveCookies() =
        verifyBrowser(profileName = "videre_scriptless_privacy_fixture", pageScriptsDisabled = true)

    private fun verifyBrowser(profileName: String?, pageScriptsDisabled: Boolean = false) {
        assertTrue(WebViewFeature.isFeatureSupported(WebViewFeature.PROXY_OVERRIDE))
        assertTrue(WebViewFeature.isFeatureSupported(WebViewFeature.SERVICE_WORKER_BLOCK_NETWORK_LOADS))
        Fixture().use { fixture ->
            val unexpected = ConcurrentHashMap.newKeySet<String>()
            val current = AtomicReference<Attempt>()
            BrowserPrivacyProxy({ Socket(it) }, { target, allowed ->
                if (allowed && (target.host != "127.0.0.1" || target.port != fixture.port)) {
                    unexpected.add(target.host)
                    throw IOException("Test fixture permits only loopback.")
                }
                current.get()?.let { attempt ->
                    if (allowed) attempt.allowedPaths.add(target.encodedPath)
                    if (!allowed && target.host in officialHosts && attempt.blocked.add(target.host)) {
                        attempt.refused.countDown()
                    }
                }
            }).use { proxy ->
                var browser: WebView? = null
                try {
                    val pages = if (profileName == null) listOf("") else listOf("", "reopened")
                    for (page in pages) {
                        val installed = CountDownLatch(1)
                        instrumentation.runOnMainSync {
                            ServiceWorkerControllerCompat.getInstance().serviceWorkerWebSettings.blockNetworkLoads = true
                            val config = ProxyConfig.Builder().addProxyRule(proxy.url).removeImplicitRules().build()
                            ProxyController.getInstance().setProxyOverride(config, executor) { installed.countDown() }
                        }
                        assertTrue("Chromium proxy installation timed out", installed.await(8, TimeUnit.SECONDS))
                        val attempt = Attempt(officialHosts.size)
                        current.set(attempt)
                        val blockedAfterClose = CountDownLatch(1)
                        val workersBlocked = AtomicBoolean(profileName == null)
                        instrumentation.runOnMainSync {
                            val view = WebView(instrumentation.targetContext)
                            browser = view
                            if (profileName != null) {
                                val workers = ProfileStore.getInstance().getOrCreateProfile(profileName)
                                    .serviceWorkerController.serviceWorkerWebSettings
                                workers.blockNetworkLoads = true
                                workersBlocked.set(workers.blockNetworkLoads)
                                WebViewCompat.setProfile(view, profileName)
                            }
                            if (pageScriptsDisabled) BrowserPrivacySettings.apply(view) else {
                                view.settings.blockNetworkLoads = true
                                view.settings.javaScriptEnabled = true
                            }
                            view.webViewClient = object : WebViewClient() {
                                override fun onReceivedError(
                                    view: WebView, request: WebResourceRequest, error: WebResourceError,
                                ) {
                                    if (request.isForMainFrame && request.url.path == "/closed") {
                                        blockedAfterClose.countDown()
                                    }
                                }
                            }
                            proxy.allow(null, null)
                            view.settings.blockNetworkLoads = false
                            view.loadUrl("${fixture.url}$page")
                        }
                        assertTrue("Expected Chromium fetch/iframe/image/redirect blocks; got ${attempt.blocked}",
                            attempt.refused.await(15, TimeUnit.SECONDS))
                        assertTrue("Isolated profile workers must stay off the network", workersBlocked.get())
                        val fixturePaths = setOf("/$page", "/redirect")
                        assertTrue("Fixture page and redirect should both be loaded", fixture.paths.containsAll(fixturePaths))
                        assertTrue("Fixture must traverse the installed proxy", attempt.allowedPaths.containsAll(fixturePaths))
                        assertTrue("Unexpected attempt to open an external socket: $unexpected", unexpected.isEmpty())

                        if (pageScriptsDisabled) {
                            assertFalse("Untrusted page scripts must never run", fixture.paths.contains("/page-script-ran"))
                            assertFalse("Page script resources must remain disabled", fixture.paths.contains("/page-script-resource.js"))
                            val cookie = AtomicReference<String>()
                            instrumentation.runOnMainSync {
                                assertFalse(checkNotNull(browser).settings.javaScriptEnabled)
                                cookie.set(ProfileStore.getInstance().getOrCreateProfile(checkNotNull(profileName))
                                    .cookieManager.getCookie(fixture.url))
                            }
                            assertTrue(cookie.get().orEmpty().contains("privacy_fixture=ok"))
                            ProxyDataSource.initialize(instrumentation.targetContext)
                            val read = BrowserPageReader.newCall("${fixture.url}selector".toHttpUrl(), cookie.get(), null)
                            read.execute().use { response ->
                                assertTrue(BrowserPageReader.readHtml(response).orEmpty().contains("fixture-backend"))
                            }
                            assertTrue(fixture.cookies["/selector"].orEmpty().contains("privacy_fixture=ok"))
                            if (page.isEmpty()) {
                                instrumentation.runOnMainSync {
                                    checkNotNull(browser).postUrl("${fixture.url}form", "fixture=ok".toByteArray())
                                    assertFalse(checkNotNull(browser).settings.javaScriptEnabled)
                                }
                                assertTrue("Scriptless form POST did not arrive", fixture.formPosted.await(5, TimeUnit.SECONDS))
                                assertEquals("fixture=ok", fixture.formBody.get())
                                assertTrue(fixture.cookies["/form"].orEmpty().contains("privacy_fixture=ok"))
                            }
                        }

                        // The override stays pinned during closure and reopening.
                        proxy.deny()
                        instrumentation.runOnMainSync { checkNotNull(browser).loadUrl("${fixture.url}closed") }
                        assertTrue("Denied route must fail instead of reconnecting directly",
                            blockedAfterClose.await(8, TimeUnit.SECONDS))
                        assertFalse(fixture.paths.contains("/closed"))
                        instrumentation.runOnMainSync {
                            checkNotNull(browser).destroyBrowser()
                            browser = null
                        }
                    }
                } finally {
                    proxy.deny()
                    instrumentation.runOnMainSync {
                        browser?.destroyBrowser()
                    }
                    // Only restore routing in the isolated instrumentation host.
                    val cleared = CountDownLatch(1)
                    instrumentation.runOnMainSync {
                        ProxyController.getInstance().clearProxyOverride(executor) { cleared.countDown() }
                    }
                    assertTrue(cleared.await(8, TimeUnit.SECONDS))
                }
            }
        }
    }

    private fun WebView.destroyBrowser() {
        settings.blockNetworkLoads = true
        stopLoading()
        destroy()
    }

    private class Fixture : AutoCloseable {
        private val listener = ServerSocket().apply { bind(InetSocketAddress("127.0.0.1", 0)) }
        val paths = ConcurrentHashMap.newKeySet<String>()
        val cookies = ConcurrentHashMap<String, String>()
        val formPosted = CountDownLatch(1)
        val formBody = AtomicReference<String>()
        val port get() = listener.localPort
        val url get() = "http://127.0.0.1:$port/"
        private val worker = Thread(::serve, "webview-privacy-fixture").apply { isDaemon = true; start() }

        private fun serve() {
            while (!listener.isClosed) {
                val socket = try { listener.accept() } catch (_: IOException) { return }
                socket.use {
                    try {
                        it.soTimeout = 3_000
                        val reader = it.getInputStream().bufferedReader()
                        val request = reader.readLine()?.split(' ') ?: return@use
                        val path = request.getOrNull(1) ?: return@use
                        var length = 0
                        while (true) {
                            val header = reader.readLine() ?: break
                            if (header.isEmpty()) break
                            if (header.startsWith("Content-Length:", ignoreCase = true)) {
                                length = header.substringAfter(':').trim().toInt()
                            }
                            if (header.startsWith("Cookie:", ignoreCase = true)) cookies[path] = header.substringAfter(':').trim()
                        }
                        if (path == "/form" && request.first() == "POST") {
                            val body = CharArray(length)
                            var offset = 0
                            while (offset < length) {
                                val count = reader.read(body, offset, length - offset)
                                if (count < 0) throw IOException("Incomplete fixture form")
                                offset += count
                            }
                            formBody.set(String(body))
                            formPosted.countDown()
                        }
                        paths.add(path)
                        val response = if (path == "/redirect") {
                            "HTTP/1.1 302 Found\r\nLocation: https://www.youtube.com/youtubei/v1/search\r\n" +
                                "Cache-Control: no-store\r\nContent-Length: 0\r\nConnection: close\r\n\r\n"
                        } else {
                            val page = if (path == "/" || path == "/reopened" || path == "/selector") PAGE else ""
                            "HTTP/1.1 200 OK\r\nContent-Type: text/html; charset=utf-8\r\n" +
                                "Set-Cookie: privacy_fixture=ok; Path=/\r\n" +
                                "Cache-Control: no-store\r\nContent-Length: ${page.toByteArray().size}\r\nConnection: close\r\n\r\n$page"
                        }
                        it.getOutputStream().write(response.toByteArray())
                    } catch (_: IOException) { }
                }
            }
        }

        override fun close() {
            listener.close()
            worker.join(3_500)
        }

        private companion object {
            const val PAGE = """
                <!doctype html><title>Local privacy fixture</title>
                <script>
                  window.pageScriptRan = true;
                  fetch('/page-script-ran').catch(() => {});
                  fetch('https://music.youtube.com/youtubei/v1/search',
                    { method: 'POST', mode: 'no-cors', body: '{}' }).catch(() => {});
                </script>
                <script src="/page-script-resource.js"></script>
                <noscript><img src="https://music.youtube.com/fixture-image"></noscript>
                <div id=backend-selector><a href="/switchbackend?backend=fixture-backend">Fixture</a></div>
                <form id="fixture-form" action="/form" method="post"><input name="fixture" value="ok"></form>
                <iframe src="https://www.youtube-nocookie.com/embed/fixture"></iframe>
                <img src="https://i.ytimg.com/vi/fixture/default.jpg">
                <img src="/redirect">
            """
        }
    }
}
