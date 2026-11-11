package com.github.dvbeckwitt.videre

import android.app.Activity
import android.app.Dialog
import android.content.Context
import android.content.SharedPreferences
import android.graphics.Color
import android.net.Uri
import android.os.Handler
import android.os.Looper
import android.view.ViewGroup
import android.webkit.RenderProcessGoneDetail
import android.webkit.CookieManager
import android.webkit.WebResourceRequest
import android.webkit.WebSettings
import android.webkit.WebView
import android.webkit.WebViewClient
import android.widget.Button
import android.widget.LinearLayout
import android.widget.TextView
import io.flutter.plugin.common.MethodCall
import com.github.dvbeckwitt.videre.proxy.BrowserPrivacySettings
import com.github.dvbeckwitt.videre.proxy.BrowserPageReader
import io.flutter.plugin.common.MethodChannel
import org.json.JSONObject
import okhttp3.Call
import okhttp3.Callback
import okhttp3.Response
import okhttp3.HttpUrl.Companion.toHttpUrlOrNull
import java.io.IOException
import java.util.concurrent.Executor

/** A visible browser for reading public selector markup, never browser cookies. */
class BackendDiscoveryBrowser(private val activity: Activity) {
    private data class SavedProxy(val enabled: Boolean, val host: String, val port: Int)

    private data class PageArguments(
        val url: String, val origin: Uri, val title: String, val help: String,
        val usePage: String, val cancel: String, val noOptions: String,
    )

    private class Request(
        val result: MethodChannel.Result, val policy: SavedProxy, val args: PageArguments,
    ) {
        var finishing = false
        var value: Map<String, String>? = null
        var error: String? = null
        var pageRead: Call? = null
        val closeResults = mutableListOf<MethodChannel.Result>()
    }

    private var current: Request? = null
    private var dialog: Dialog? = null
    private var browser: WebView? = null
    private var closed = false
    private val handler = Handler(Looper.getMainLooper())
    private val executor = Executor { handler.post(it) }
    private val proxyInstallTimeout = Runnable { finish(error = "BROWSER_PROXY_CONFIGURATION") }
    private val proxyPreferences = activity.applicationContext.getSharedPreferences("videre_network_proxy", Context.MODE_PRIVATE)
    private var watchingProxy = false
    private val proxyChanged = SharedPreferences.OnSharedPreferenceChangeListener { _, key ->
        if (key == "configuration") handler.post { finish(error = "PROXY_CHANGED") }
    }

    fun open(call: MethodCall, result: MethodChannel.Result) {
        if (call.method == "close") {
            val request = current
            if (request == null) result.success(null)
            else {
                request.closeResults.add(result)
                finish()
            }
            return
        }
        if (call.method != "open") {
            result.notImplemented()
            return
        }
        if (closed || activity.isFinishing || activity.isDestroyed) {
            result.error("BROWSER_UNAVAILABLE", null, null)
            return
        }
        if (current != null) {
            result.error("BROWSER_BUSY", null, null)
            return
        }
        if (!WebViewBrowserLease.supported()) {
            result.error("BROWSER_PROXY_UNSUPPORTED", null, null)
            return
        }
        val policy = readPolicy()
        if (policy == null) {
            result.error("PROXY_CONFIGURATION", null, null)
            return
        }
        val url = call.argument<String>("url")
        val origin = url?.let { runCatching { Uri.parse(it) }.getOrNull() }
        val title = call.argument<String>("title")
        val help = call.argument<String>("help")
        val usePage = call.argument<String>("usePage")
        val cancel = call.argument<String>("cancel")
        val noOptions = call.argument<String>("noOptions")?.takeIf { it.isNotBlank() } ?: help
        if (origin == null || !allowedOrigin(origin) ||
            (origin.path.orEmpty() != "" && origin.path != "/") ||
            origin.query != null || origin.fragment != null ||
            listOf(title, help, usePage, cancel).any { it.isNullOrBlank() }) {
            result.error("INVALID_ARGUMENT", null, null)
            return
        }
        val request = Request(result, policy,
            PageArguments(url!!, origin, title!!, help!!, usePage!!, cancel!!, noOptions!!))
        if (!WebViewBrowserLease.acquire(this)) {
            result.error("BROWSER_BUSY", null, null)
            return
        }
        current = request
        proxyPreferences.registerOnSharedPreferenceChangeListener(proxyChanged)
        watchingProxy = true
        if (readPolicy() != policy) {
            finish(error = "PROXY_CHANGED")
            return
        }
        try {
            handler.postDelayed(proxyInstallTimeout, 10_000L)
            WebViewBrowserLease.install(this, executor) {
                if (current !== request || request.finishing) return@install
                handler.removeCallbacks(proxyInstallTimeout)
                if (closed || readPolicy() != request.policy) finish(error = "PROXY_CHANGED")
                else showBrowser(request)
            }
        } catch (_: Exception) {
            finish(error = "BROWSER_PROXY_CONFIGURATION")
        }
    }

    private fun showBrowser(request: Request) {
        if (current !== request || request.finishing) return
        if (closed || activity.isFinishing || activity.isDestroyed || readPolicy() != request.policy) {
            finish(error = "PROXY_CHANGED")
            return
        }
        val url = request.args.url
        val origin = request.args.origin
        val title = request.args.title
        val help = request.args.help
        val usePage = request.args.usePage
        val cancel = request.args.cancel
        val noOptions = request.args.noOptions
        try {
            val surface = Dialog(activity, android.R.style.Theme_DeviceDefault_Light_NoActionBar)
            dialog = surface
            val content = LinearLayout(activity).apply {
                orientation = LinearLayout.VERTICAL
                fitsSystemWindows = true
                setBackgroundColor(Color.WHITE)
            }
            val padding = (16 * activity.resources.displayMetrics.density).toInt()
            val heading = TextView(activity).apply {
                text = title
                textSize = 20f
                setTextColor(Color.BLACK)
                setPadding(padding, padding, padding, padding / 2)
            }
            val status = TextView(activity).apply {
                text = help
                setTextColor(Color.DKGRAY)
                setPadding(padding, padding / 2, padding, padding)
                accessibilityLiveRegion = android.view.View.ACCESSIBILITY_LIVE_REGION_POLITE
            }
            content.addView(heading)
            content.addView(status)
            val web = WebView(activity)
            browser = web
            BrowserPrivacySettings.apply(web)
            web.settings.apply {
                cacheMode = WebSettings.LOAD_NO_CACHE
                domStorageEnabled = true
                allowFileAccess = false
                allowContentAccess = false
                mixedContentMode = WebSettings.MIXED_CONTENT_NEVER_ALLOW
                setGeolocationEnabled(false)
                javaScriptCanOpenWindowsAutomatically = false
                setSupportMultipleWindows(false)
            }
            web.webViewClient = object : WebViewClient() {
                override fun onRenderProcessGone(view: WebView, detail: RenderProcessGoneDetail): Boolean {
                    // Renderer loss must close this browser, not kill Videre
                    // and its playback. A stale view was already torn down.
                    if (browser === view && current === request) finish(error = "BROWSER_UNAVAILABLE")
                    return true
                }

                override fun shouldOverrideUrlLoading(view: WebView, request: WebResourceRequest): Boolean {
                    if (!request.isForMainFrame) return false
                    return !allowedNavigation(origin, request.url)
                }

                @Deprecated("Required for older WebView implementations")
                override fun shouldOverrideUrlLoading(view: WebView, target: String): Boolean =
                    !allowedNavigation(origin, Uri.parse(target))
            }
            content.addView(web, LinearLayout.LayoutParams(ViewGroup.LayoutParams.MATCH_PARENT, 0, 1f))
            val actions = LinearLayout(activity).apply {
                orientation = LinearLayout.HORIZONTAL
                setPadding(padding, 0, padding, padding)
                gravity = android.view.Gravity.END
            }
            val cancelButton = Button(activity).apply {
                text = cancel
                setOnClickListener { finish() }
            }
            val useButton = Button(activity).apply { text = usePage }
            actions.addView(cancelButton)
            actions.addView(useButton)
            content.addView(actions)
            useButton.setOnClickListener {
                if (current !== request || request.finishing || !sameOrigin(origin, Uri.parse(web.url.orEmpty()))) return@setOnClickListener
                val page = web.url?.toHttpUrlOrNull() ?: return@setOnClickListener
                if (request.pageRead != null) return@setOnClickListener
                useButton.isEnabled = false
                fun completeRead(call: Call?, html: String?) {
                    handler.post {
                        if (current !== request || request.finishing || browser !== web || request.pageRead !== call) return@post
                        request.pageRead = null
                        useButton.isEnabled = true
                        if (readPolicy() != request.policy) { finish(error = "PROXY_CHANGED"); return@post }
                        if (web.url?.toHttpUrlOrNull() != page || html.isNullOrBlank()) {
                            status.text = noOptions
                            status.announceForAccessibility(noOptions)
                        } else {
                            finish(mapOf("url" to page.toString(), "html" to html))
                        }
                    }
                }
                try {
                    val cookies = CookieManager.getInstance().getCookie(page.toString())
                    val call = BrowserPageReader.newCall(page, cookies, web.settings.userAgentString)
                    request.pageRead = call
                    call.enqueue(object : Callback {
                        override fun onFailure(call: Call, error: IOException) = completeRead(call, null)
                        override fun onResponse(call: Call, response: Response) {
                            val html = runCatching { response.use(BrowserPageReader::readHtml) }.getOrNull()
                            completeRead(call, html)
                        }
                    })
                } catch (_: Exception) { completeRead(request.pageRead, null) }
            }
            surface.setContentView(content)
            surface.setCancelable(true)
            surface.setOnCancelListener { finish() }
            surface.show()
            surface.window?.setLayout(ViewGroup.LayoutParams.MATCH_PARENT, ViewGroup.LayoutParams.MATCH_PARENT)
            WebViewBrowserLease.allow(this, request.policy.host.takeIf { request.policy.enabled },
                request.policy.port.takeIf { request.policy.enabled })
            web.settings.blockNetworkLoads = false
            web.loadUrl(url)
        } catch (_: RuntimeException) {
            finish(error = "BROWSER_UNAVAILABLE")
        }
    }

    fun close() {
        closed = true
        finish()
    }

    private fun finish(value: Map<String, String>? = null, error: String? = null) {
        val request = current ?: return
        if (request.finishing) return
        request.finishing = true
        WebViewBrowserLease.deny(this)
        request.pageRead?.cancel()
        handler.removeCallbacks(proxyInstallTimeout)
        request.value = value
        request.error = error
        if (watchingProxy) {
            proxyPreferences.unregisterOnSharedPreferenceChangeListener(proxyChanged)
            watchingProxy = false
        }
        runCatching {
            dialog?.setOnCancelListener(null)
            dialog?.dismiss()
        }
        dialog = null
        browser?.let { web ->
            runCatching { web.settings.blockNetworkLoads = true }
            runCatching { (web.parent as? ViewGroup)?.removeView(web) }
            runCatching { web.stopLoading() }
            runCatching { web.destroy() }
        }
        browser = null
        complete(request)
    }

    private fun complete(request: Request) {
        if (current !== request) return
        current = null
        WebViewBrowserLease.release(this)
        val error = request.error
        if (error == null) request.result.success(request.value)
        else request.result.error(error, null, null)
        request.closeResults.forEach { it.success(null) }
        request.closeResults.clear()
    }

    private fun readPolicy(): SavedProxy? = runCatching {
        val saved = proxyPreferences.getString("configuration", null)
            ?: return@runCatching SavedProxy(false, "127.0.0.1", 9050)
        val config = JSONObject(saved)
        val enabled = config.opt("enabled") as? Boolean ?: return@runCatching null
        val host = config.opt("host") as? String ?: return@runCatching null
        val number = config.opt("port") as? Number ?: return@runCatching null
        val port = number.toInt()
        if (number.toDouble() != port.toDouble()) return@runCatching null
        if (enabled && (host.isBlank() || host != host.trim() ||
                host.any { it.isWhitespace() || it in "/@?#" } || port !in 1..65535)) return@runCatching null
        SavedProxy(enabled, host, port)
    }.getOrNull()

    private fun allowedOrigin(uri: Uri): Boolean =
        uri.scheme == "https" && uri.host in setOf("invidious.nerdvpn.de", "www.invidious.nerdvpn.de") &&
            (uri.port == -1 || uri.port == 443) && uri.userInfo == null

    private fun sameOrigin(origin: Uri, target: Uri): Boolean =
        allowedOrigin(target) && origin.host == target.host

    private fun allowedNavigation(origin: Uri, target: Uri): Boolean =
        sameOrigin(origin, target) && target.path.orEmpty().trimEnd('/') !in
            setOf("/switchbackend", "/login", "/logout", "/register", "/token_manager")

}
