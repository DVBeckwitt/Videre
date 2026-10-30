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
import android.webkit.WebResourceRequest
import android.webkit.WebSettings
import android.webkit.WebView
import android.webkit.WebViewClient
import android.widget.Button
import android.widget.LinearLayout
import android.widget.TextView
import androidx.webkit.ProxyConfig
import androidx.webkit.ProxyController
import androidx.webkit.WebViewFeature
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import org.json.JSONObject
import org.json.JSONTokener
import java.util.concurrent.Executor

/** A visible browser for reading public selector markup, never browser cookies. */
class BackendDiscoveryBrowser(private val activity: Activity) {
    private data class SavedProxy(val enabled: Boolean, val host: String, val port: Int) {
        fun proxyUrl(): String {
            val address = if (host.contains(':') && !host.startsWith('[')) "[$host]" else host
            return "socks5://$address:$port"
        }
    }

    private data class PageArguments(
        val url: String, val origin: Uri, val title: String, val help: String,
        val usePage: String, val cancel: String, val noOptions: String,
    )

    private class Request(
        val result: MethodChannel.Result, val policy: SavedProxy, val args: PageArguments,
    ) {
        var finishing = false
        var applying = false
        var overrideRequested = false
        var clearing = false
        var value: Map<String, String>? = null
        var error: String? = null
        val closeResults = mutableListOf<MethodChannel.Result>()
    }

    private var current: Request? = null
    private var dialog: Dialog? = null
    private var browser: WebView? = null
    private var closed = false
    private val handler = Handler(Looper.getMainLooper())
    private val executor = Executor { handler.post(it) }
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
        // ProxyController applies process-wide, so a recreated Activity must
        // wait for the previous owner's asynchronous teardown as well.
        if (current != null || activeOwner != null) {
            result.error("BROWSER_BUSY", null, null)
            return
        }
        if (proxyCleanupFailed) {
            result.error("BROWSER_PROXY_CLEANUP_FAILED", null, null)
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
        current = request
        activeOwner = this
        proxyPreferences.registerOnSharedPreferenceChangeListener(proxyChanged)
        watchingProxy = true
        if (readPolicy() != policy) {
            finish(error = "PROXY_CHANGED")
            return
        }
        if (!policy.enabled) {
            showBrowser(request)
            return
        }
        if (!runCatching { WebViewFeature.isFeatureSupported(WebViewFeature.PROXY_OVERRIDE) }.getOrDefault(false)) {
            finish(error = "BROWSER_PROXY_UNSUPPORTED")
            return
        }
        try {
            // All URL schemes use this one SOCKS5 endpoint. Do not add DIRECT,
            // bypass rules, or an empty fallback: an unavailable proxy must fail.
            // Chromium's SOCKSv5 transport resolves destination names at proxy.
            val config = ProxyConfig.Builder().addProxyRule(policy.proxyUrl())
                .removeImplicitRules().build()
            request.applying = true
            request.overrideRequested = true
            ProxyController.getInstance().setProxyOverride(config, executor) {
                if (current !== request) return@setProxyOverride
                request.applying = false
                if (request.finishing) clearProxy(request)
                else if (closed || readPolicy() != request.policy) finish(error = "PROXY_CHANGED")
                else showBrowser(request)
            }
        } catch (_: RuntimeException) {
            request.applying = false
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
            web.settings.apply {
                javaScriptEnabled = true
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
                useButton.isEnabled = false
                web.evaluateJavascript(READ_SELECTOR) { encoded ->
                    if (current !== request || request.finishing || browser !== web) return@evaluateJavascript
                    useButton.isEnabled = true
                    val value = runCatching {
                        val json = JSONTokener(encoded).nextValue() as? String ?: return@runCatching null
                        if (json.length > MAX_HTML_BYTES * 2) return@runCatching null
                        val data = JSONObject(json)
                        val page = Uri.parse(data.getString("url"))
                        val html = data.getString("html")
                        if (!sameOrigin(origin, page) || !sameOrigin(origin, Uri.parse(web.url.orEmpty())) ||
                            html.isBlank() || html.toByteArray(Charsets.UTF_8).size > MAX_HTML_BYTES) null
                        else mapOf("url" to page.toString(), "html" to html)
                    }.getOrNull()
                    if (value == null) {
                        status.text = noOptions
                        status.announceForAccessibility(noOptions)
                    } else {
                        finish(value)
                    }
                }
            }
            surface.setContentView(content)
            surface.setCancelable(true)
            surface.setOnCancelListener { finish() }
            surface.show()
            surface.window?.setLayout(ViewGroup.LayoutParams.MATCH_PARENT, ViewGroup.LayoutParams.MATCH_PARENT)
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
        // If close raced setProxyOverride, its callback clears the applied rule
        // before completing either the open result or any waiting close calls.
        clearProxy(request)
    }

    private fun clearProxy(request: Request) {
        if (current !== request || !request.finishing || request.applying || request.clearing) return
        if (!request.overrideRequested) {
            complete(request)
            return
        }
        request.clearing = true
        try {
            ProxyController.getInstance().clearProxyOverride(executor) {
                if (current !== request) return@clearProxyOverride
                request.overrideRequested = false
                request.clearing = false
                complete(request)
            }
        } catch (_: RuntimeException) {
            // Destroyed WebViews cannot issue new loads. Block future browser
            // sessions until process restart if the global override is unknown.
            proxyCleanupFailed = true
            request.error = "BROWSER_PROXY_CLEANUP_FAILED"
            complete(request)
        }
    }

    private fun complete(request: Request) {
        if (current !== request) return
        current = null
        if (activeOwner === this) activeOwner = null
        val error = request.error
        if (error == null) request.result.success(request.value)
        else request.result.error(error, null, null)
        request.closeResults.forEach { result ->
            if (proxyCleanupFailed) result.error("BROWSER_PROXY_CLEANUP_FAILED", null, null)
            else result.success(null)
        }
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

    companion object {
        // UI-thread only. A process-wide lease is needed because ProxyController
        // state outlives Activity recreation and its callbacks are asynchronous.
        private var activeOwner: BackendDiscoveryBrowser? = null
        private var proxyCleanupFailed = false
        private const val MAX_HTML_BYTES = 2 * 1024 * 1024
        private const val READ_SELECTOR = """
            (function() {
                var selector = document.querySelector('#backend-selector');
                var html = selector ? selector.outerHTML : '';
                return JSON.stringify({url: location.href, html: html.length <= 2097152 ? html : ''});
            })()
        """
    }
}
