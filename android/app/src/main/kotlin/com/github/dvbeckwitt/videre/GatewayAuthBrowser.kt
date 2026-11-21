package com.github.dvbeckwitt.videre

import android.app.Activity
import android.app.AlertDialog
import android.app.Dialog
import android.content.Context
import android.content.SharedPreferences
import android.graphics.Color
import android.net.Uri
import android.os.Handler
import android.os.Looper
import android.os.SystemClock
import android.view.ViewGroup
import android.webkit.RenderProcessGoneDetail
import android.webkit.WebResourceRequest
import android.webkit.WebSettings
import android.webkit.WebView
import android.webkit.WebViewClient
import android.widget.Button
import android.widget.LinearLayout
import android.widget.TextView
import androidx.webkit.ProfileStore
import androidx.webkit.WebViewCompat
import com.github.dvbeckwitt.videre.proxy.GatewayContext
import com.github.dvbeckwitt.videre.proxy.BrowserPrivacySettings
import com.github.dvbeckwitt.videre.proxy.GatewaySessions
import com.github.dvbeckwitt.videre.proxy.invidiousTokenFromCallback
import com.github.dvbeckwitt.videre.proxy.NerdVpnPkce
import com.github.dvbeckwitt.videre.proxy.ProxyDataSource
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import java.util.UUID
import java.util.concurrent.Executor
import java.io.IOException
import okhttp3.Call
import okhttp3.Callback
import okhttp3.HttpUrl
import okhttp3.HttpUrl.Companion.toHttpUrlOrNull
import okhttp3.Response
import org.json.JSONObject

/** A dedicated, isolated gateway login; it never exports the browser cookie jar. */
class GatewayAuthBrowser(private val activity: Activity) {
    private data class Policy(val enabled: Boolean, val host: String, val port: Int)
    private class Request(val result: MethodChannel.Result, val context: GatewayContext,
        val policy: Policy, val loginUrl: String,
        val nonce: String, val pkce: NerdVpnPkce?, val persistSession: Boolean, val javaScriptOrigin: HttpUrl?,
        val title: String, val help: String, val cancel: String) {
        var revision: Long? = null
        var profileName: String? = null
        var finishing = false
        var token: String? = null
        var error: String? = null
        var errorDetails: Map<String, Any>? = null
        var exchange: Call? = null
        val allowed = mutableSetOf(context.origin.toString())
        val closeResults = mutableListOf<MethodChannel.Result>()
    }
    private val handler = Handler(Looper.getMainLooper())
    private val executor = Executor { handler.post(it) }
    private val preferences = activity.applicationContext.getSharedPreferences("videre_network_proxy", Context.MODE_PRIVATE)
    private val externalBrowser = NerdVpnBrowserAuth(activity, preferences)
    private var current: Request? = null
    private var dialog: Dialog? = null
    private var approval: AlertDialog? = null
    private var browser: WebView? = null
    private var closed = false
    private val proxyChanged = SharedPreferences.OnSharedPreferenceChangeListener { _, key ->
        val request = current
        if (key == "configuration" && request != null) handler.post {
            if (current === request) finish(error = "GATEWAY_PROXY_CHANGED")
        }
    }
    private val timeout = Runnable { finish(error = "GATEWAY_LOGIN_TIMEOUT") }
    private val proxyInstallTimeout = Runnable { finish(error = "GATEWAY_PROXY_UNAVAILABLE") }

    fun handle(call: MethodCall, result: MethodChannel.Result) {
        if (call.method == "close") {
            if (externalBrowser.close(call.argument<String>("context"))) {
                result.success(null)
                return
            }
            val request = current
            val target = call.argument<String>("context")
            val revision = call.argument<Number>("revision")?.toLong()
            val activeRevision = request?.revision
            val matching = (target == null || runCatching { GatewayContext.parse(target) == request?.context }.getOrDefault(false)) &&
                (revision == null || activeRevision == null || revision == activeRevision)
            if (request == null || !matching) result.success(null)
            else { request.closeResults.add(result); finish() }
            return
        }
        if (call.method != "signIn") { result.notImplemented(); return }
        if (closed || activity.isFinishing || activity.isDestroyed || current != null || externalBrowser.active) {
            result.error("GATEWAY_BROWSER_BUSY", null, null); return
        }
        val context = runCatching { GatewayContext.parse(call.argument<String>("context") ?: "") }.getOrNull()
        val server = call.argument<String>("serverUrl")?.toHttpUrlOrNull()
        val policy = readPolicy()
        if (context == null || server == null || !context.allows(server) ||
            server.query != null || server.fragment != null || policy == null) {
            result.error("GATEWAY_INVALID_ARGUMENT", null, null); return
        }
        val requiresProxy = !server.isHttps || server.host.trimEnd('.').endsWith(".onion", ignoreCase = true)
        if (requiresProxy && !policy.enabled) {
            result.error("GATEWAY_ONION_PROXY_REQUIRED", null, null); return
        }
        val external = NerdVpnBrowserAttempt.create(context, server,
            call.argument<Boolean>("persistSession") ?: true, policy.enabled, SystemClock.elapsedRealtime())
        if (external != null) {
            externalBrowser.start(external, result, call.argument<String>("cancel") ?: "Cancel",
                policyIsCurrent = { readPolicy() == policy },
                protectedBrowser = { startProtected(call, result, context, server, policy) })
            return
        }
        startProtected(call, result, context, server, policy)
    }

    private fun startProtected(call: MethodCall, result: MethodChannel.Result,
        context: GatewayContext, server: HttpUrl, policy: Policy) {
        if (closed || activity.isFinishing || activity.isDestroyed || current != null || externalBrowser.active) {
            result.error("GATEWAY_BROWSER_BUSY", null, null); return
        }
        if (readPolicy() != policy) { result.error("GATEWAY_PROXY_CHANGED", null, null); return }
        if (!GatewaySessions.supported()) {
            result.error("GATEWAY_UNSUPPORTED", null, null); return
        }
        if (!WebViewBrowserLease.supported()) {
            result.error("GATEWAY_PROXY_UNSUPPORTED", null, null); return
        }
        if (!WebViewBrowserLease.acquire(this)) {
            result.error("GATEWAY_BROWSER_BUSY", null, null); return
        }
        val nonce = UUID.randomUUID().toString()
        val pkce = NerdVpnPkce.forServer(server, nonce)
        val persistSession = call.argument<Boolean>("persistSession") ?: true
        val login = pkce?.authorizationUrl(server) ?: server.newBuilder().encodedPath(server.encodedPath.trimEnd('/') + "/authorize_token")
            .addQueryParameter("scopes", ":feed,:subscriptions*,:playlists*,:history*")
            .addQueryParameter("callback_url", "videre-gateway://callback/$nonce").build().toString()
        val request = Request(result, context, policy, login, nonce, pkce,
            persistSession, nerdVpnJavaScriptOrigin(context, server, persistSession, policy.enabled),
            call.argument<String>("title") ?: "Sign in to protected server",
            call.argument<String>("help") ?: "Sign in to your gateway, then authorize Invidious.",
            call.argument<String>("cancel") ?: "Cancel")
        current = request
        preferences.registerOnSharedPreferenceChangeListener(proxyChanged)
        handler.postDelayed(timeout, 10 * 60 * 1000L)
        if (readPolicy() != policy) { finish(error = "GATEWAY_PROXY_CHANGED"); return }
        try {
            handler.postDelayed(proxyInstallTimeout, 10_000L)
            WebViewBrowserLease.install(this, executor) {
                if (current !== request || request.finishing) return@install
                handler.removeCallbacks(proxyInstallTimeout)
                if (readPolicy() != policy) {
                    finish(error = "GATEWAY_PROXY_CHANGED")
                    return@install
                }
                // Creating the isolated profile can initialize browser state.
                // Wait until the process-wide (still denied) route is installed.
                try {
                    if (request.persistSession) {
                        val revision = GatewaySessions.beginSignIn(context)
                        request.revision = revision
                        request.profileName = GatewaySessions.signInProfileName(context, revision)
                    } else {
                        // A token-only login must never alter a saved gateway's
                        // status, cookies or revision, even while it is pending.
                        request.profileName = "${context.profileName}_token_$nonce"
                    }
                } catch (_: Exception) {
                    finish(error = "GATEWAY_UNAVAILABLE")
                    return@install
                }
                show(request)
            }
        } catch (_: Exception) {
            finish(error = "GATEWAY_PROXY_UNAVAILABLE")
        }
    }

    private fun show(request: Request) {
        if (current !== request || request.finishing) return
        if (closed || activity.isFinishing || activity.isDestroyed || readPolicy() != request.policy) {
            finish(error = "GATEWAY_BROWSER_UNAVAILABLE"); return
        }
        try {
            val surface = Dialog(activity, android.R.style.Theme_DeviceDefault_Light_NoActionBar)
            dialog = surface
            val content = LinearLayout(activity).apply {
                orientation = LinearLayout.VERTICAL
                fitsSystemWindows = true
                setBackgroundColor(Color.WHITE)
            }
            val pad = (16 * activity.resources.displayMetrics.density).toInt()
            val heading = TextView(activity).apply {
                text = "${request.title}\n${request.context.origin.host}"
                textSize = 18f
                setTextColor(Color.BLACK)
                setPadding(pad, pad, pad, pad / 2)
            }
            val hint = TextView(activity).apply {
                text = if (request.javaScriptOrigin == null) request.help else
                    "JavaScript is enabled for NerdVPN sign-in. This temporary session uses your direct connection."
                setTextColor(Color.DKGRAY)
                setPadding(pad, 0, pad, pad / 2)
            }
            content.addView(heading)
            content.addView(hint)
            val web = WebView(activity)
            browser = web
            BrowserPrivacySettings.apply(web)
            val profileName = checkNotNull(request.profileName)
            ProfileStore.getInstance().getOrCreateProfile(profileName).serviceWorkerController
                .serviceWorkerWebSettings.blockNetworkLoads = true
            WebViewCompat.setProfile(web, profileName)
            web.settings.apply {
                domStorageEnabled = true
                allowFileAccess = false
                allowContentAccess = false
                mixedContentMode = WebSettings.MIXED_CONTENT_NEVER_ALLOW
                setGeolocationEnabled(false)
                javaScriptCanOpenWindowsAutomatically = false
                setSupportMultipleWindows(false)
                cacheMode = WebSettings.LOAD_NO_CACHE
            }
            web.webViewClient = object : WebViewClient() {
                override fun shouldOverrideUrlLoading(view: WebView, target: WebResourceRequest): Boolean {
                    if (!target.isForMainFrame) {
                        if (target.url.scheme !in setOf("http", "https")) return true
                        return request.javaScriptOrigin != null &&
                            target.url.toString().toHttpUrlOrNull()?.let(request.context::allows) != true
                    }
                    return navigate(request, view, target.url)
                }
                @Deprecated("Required for older WebView implementations")
                override fun shouldOverrideUrlLoading(view: WebView, target: String): Boolean =
                    navigate(request, view, Uri.parse(target))
                override fun onRenderProcessGone(view: WebView, detail: RenderProcessGoneDetail): Boolean {
                    if (browser === view && current === request) finish(error = "GATEWAY_BROWSER_UNAVAILABLE")
                    return true
                }
            }
            content.addView(web, LinearLayout.LayoutParams(ViewGroup.LayoutParams.MATCH_PARENT, 0, 1f))
            content.addView(Button(activity).apply { text = request.cancel; setOnClickListener { finish() } })
            surface.setContentView(content)
            surface.setCancelable(true)
            surface.setOnCancelListener { finish() }
            surface.show()
            surface.window?.setLayout(ViewGroup.LayoutParams.MATCH_PARENT, ViewGroup.LayoutParams.MATCH_PARENT)
            WebViewBrowserLease.allow(this, request.policy.host.takeIf { request.policy.enabled },
                request.policy.port.takeIf { request.policy.enabled }, request.javaScriptOrigin)
            // Install the immutable origin restriction before any page script or
            // network load can start. Other sign-in and discovery browsers stay scriptless.
            web.settings.javaScriptEnabled = request.javaScriptOrigin != null
            web.settings.blockNetworkLoads = false
            web.loadUrl(request.loginUrl)
        } catch (_: Exception) { finish(error = "GATEWAY_BROWSER_UNAVAILABLE") }
    }

    private fun navigate(request: Request, web: WebView, uri: Uri): Boolean {
        if (current !== request || request.finishing || request.exchange != null) return true
        if (uri.scheme == "videre-gateway") {
            val previous = web.url?.toHttpUrlOrNull()
            if (request.pkce != null) {
                val code = request.pkce.codeFromCallback(uri.toString())
                if (previous != null && request.context.allows(previous) && code != null) {
                    exchangeCode(request, web, code)
                }
                return true
            }
            val token = invidiousTokenFromCallback(uri.toString(), request.nonce)
            if (previous != null && request.context.allows(previous) && token != null) {
                acceptToken(request, token)
            }
            return true
        }
        val target = uri.toString().toHttpUrlOrNull()
        if (target == null || !request.context.canNavigateDuringSignIn(target, request.policy.enabled)) return true
        if (request.javaScriptOrigin != null && !request.context.allows(target)) return true
        val origin = target.newBuilder().encodedPath("/").query(null).fragment(null).build().toString()
        if (origin in request.allowed) return false
        if (approval != null) return true
        approval = AlertDialog.Builder(activity)
            .setTitle("Continue sign-in?")
            .setMessage("Your server is opening a sign-in page at:\n${target.host}")
            .setPositiveButton("Continue") { _, _ ->
                approval = null
                if (current === request && !request.finishing) {
                    request.allowed.add(origin)
                    web.loadUrl(target.toString())
                }
            }.setNegativeButton(request.cancel) { _, _ -> approval = null; finish() }
            .setOnCancelListener { approval = null; finish() }.show()
        return true
    }

    private fun exchangeCode(request: Request, web: WebView, code: String) {
        val pkce = request.pkce ?: return
        try {
            // Keep the old session intact until the new code is exchanged. The
            // pending profile supplies cookies only to this exact origin.
            val profileName = checkNotNull(request.profileName)
            val manager = ProfileStore.getInstance().getOrCreateProfile(profileName).cookieManager
            val url = request.context.origin.newBuilder().encodedPath("/api/v1/token").build()
            val cookie = manager.getCookie(url.toString())
            val outgoing = NerdVpnTokenExchange.request(request.context.origin, pkce, code, cookie)
            val call = ProxyDataSource.newTokenExchangeCall(outgoing)
            request.exchange = call
            web.stopLoading()
            web.settings.blockNetworkLoads = true
            web.settings.javaScriptEnabled = false
            call.enqueue(object : Callback {
                override fun onFailure(call: Call, error: IOException) {
                    handler.post {
                        if (current === request && !request.finishing) finish(error = NerdVpnTokenExchange.transportError(error))
                    }
                }

                override fun onResponse(call: Call, response: Response) {
                    val exchanged = NerdVpnTokenExchange.read(response)
                    handler.post {
                        if (current !== request || request.finishing) return@post
                        if (readPolicy() != request.policy) { finish(error = "GATEWAY_PROXY_CHANGED"); return@post }
                        val token = exchanged.token
                        if (token == null) { finish(error = exchanged.error, details = exchanged.details); return@post }
                        try {
                            val pendingName = checkNotNull(request.profileName)
                            val pendingCookies = ProfileStore.getInstance().getOrCreateProfile(pendingName).cookieManager
                            exchanged.cookies.forEach { value -> pendingCookies.setCookie(url.toString(), value) }
                            acceptToken(request, token)
                        } catch (_: Exception) { finish(error = "GATEWAY_TOKEN_EXCHANGE_FAILED") }
                    }
                }
            })
        } catch (_: Exception) { finish(error = "GATEWAY_TOKEN_EXCHANGE_FAILED") }
    }

    fun acceptExternalCallback(value: String) { externalBrowser.acceptCallback(value) }

    fun close() { closed = true; externalBrowser.close(); finish() }

    private fun acceptToken(request: Request, token: String) {
        val accepted = !request.persistSession || request.revision?.let {
            GatewaySessions.completeSignIn(request.context, it)
        } == true
        if (accepted) finish(token = token)
        else finish(error = "GATEWAY_LOGIN_CANCELLED")
    }

    private fun finish(token: String? = null, error: String? = null, details: Map<String, Any>? = null) {
        val request = current ?: return
        if (request.finishing) return
        request.finishing = true
        WebViewBrowserLease.deny(this)
        request.token = token
        request.error = error
        request.errorDetails = details
        request.exchange?.cancel()
        handler.removeCallbacks(timeout)
        handler.removeCallbacks(proxyInstallTimeout)
        preferences.unregisterOnSharedPreferenceChangeListener(proxyChanged)
        approval?.setOnCancelListener(null)
        approval?.dismiss()
        approval = null
        dialog?.setOnCancelListener(null)
        dialog?.dismiss()
        dialog = null
        var browserDestroyed = true
        browser?.let {
            runCatching { it.settings.blockNetworkLoads = true }
            runCatching { it.settings.javaScriptEnabled = false }
            runCatching { it.stopLoading() }
            runCatching { (it.parent as? ViewGroup)?.removeView(it) }
            browserDestroyed = runCatching { it.destroy() }.isSuccess
        }
        browser = null
        if (!request.persistSession) request.profileName?.let { name ->
            // Keep the route denied and the lease held until the temporary
            // browser data is cleared. A late callback cannot finish a new login.
            fun finishClearing(cleared: Boolean) {
                if (current !== request) return
                if (!cleared || !browserDestroyed) {
                    request.token = null
                    request.error = "GATEWAY_BROWSER_UNAVAILABLE"
                }
                complete(request)
            }
            val cleanupTimeout = Runnable { finishClearing(false) }
            handler.postDelayed(cleanupTimeout, 10_000L)
            GatewaySessions.clearTemporaryBrowserProfile(name) { cleared ->
                handler.post {
                    handler.removeCallbacks(cleanupTimeout)
                    finishClearing(cleared)
                }
            }
            return
        }
        if (token == null) request.revision?.let { revision ->
            runCatching { GatewaySessions.cancelSignIn(request.context, revision) }
        }
        complete(request)
    }

    private fun complete(request: Request) {
        if (current !== request) return
        current = null
        WebViewBrowserLease.release(this)
        if (request.error != null) request.result.error(request.error!!, null, request.errorDetails)
        else request.result.success(request.token)
        request.closeResults.forEach { it.success(null) }
        request.closeResults.clear()
    }

    private fun readPolicy(): Policy? = runCatching {
        val saved = preferences.getString("configuration", null) ?: return@runCatching Policy(false, "127.0.0.1", 9050)
        val json = JSONObject(saved)
        val enabled = json.opt("enabled") as? Boolean ?: return@runCatching null
        val host = json.opt("host") as? String ?: return@runCatching null
        val number = json.opt("port") as? Number ?: return@runCatching null
        val port = number.toInt()
        if (number.toDouble() != port.toDouble() || (enabled &&
            (host.isBlank() || host != host.trim() || host.any { it.isWhitespace() || it in "/@?#" } || port !in 1..65535))) null
        else Policy(enabled, host.removeSurrounding("[", "]"), port)
    }.getOrNull()
}
