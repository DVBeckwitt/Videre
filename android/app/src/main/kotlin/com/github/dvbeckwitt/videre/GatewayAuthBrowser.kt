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
import android.view.ViewGroup
import android.webkit.RenderProcessGoneDetail
import android.webkit.WebResourceRequest
import android.webkit.WebSettings
import android.webkit.WebView
import android.webkit.WebViewClient
import android.widget.Button
import android.widget.LinearLayout
import android.widget.TextView
import androidx.webkit.ProxyConfig
import androidx.webkit.ProxyController
import androidx.webkit.ProfileStore
import androidx.webkit.WebViewCompat
import androidx.webkit.WebViewFeature
import com.github.dvbeckwitt.videre.proxy.GatewayContext
import com.github.dvbeckwitt.videre.proxy.GatewaySessions
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
import okhttp3.MediaType.Companion.toMediaType
import okhttp3.Request as HttpRequest
import okhttp3.RequestBody.Companion.toRequestBody
import okhttp3.Response
import org.json.JSONObject

/** A dedicated, isolated gateway login; it never exports the browser cookie jar. */
class GatewayAuthBrowser(private val activity: Activity) {
    private data class Policy(val enabled: Boolean, val host: String, val port: Int) {
        fun proxyUrl(): String = "socks5://${if (host.contains(':')) "[$host]" else host}:$port"
    }
    private class Request(val result: MethodChannel.Result, val context: GatewayContext,
        val revision: Long, val policy: Policy, val loginUrl: String,
        val nonce: String, val pkce: NerdVpnPkce?, val title: String, val help: String, val cancel: String) {
        var finishing = false
        var applying = false
        var overridden = false
        var clearing = false
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
    private var current: Request? = null
    private var dialog: Dialog? = null
    private var approval: AlertDialog? = null
    private var browser: WebView? = null
    private var closed = false
    private val proxyChanged = SharedPreferences.OnSharedPreferenceChangeListener { _, key ->
        if (key == "configuration") handler.post { finish(error = "GATEWAY_PROXY_CHANGED") }
    }
    private val timeout = Runnable { finish(error = "GATEWAY_LOGIN_TIMEOUT") }

    fun handle(call: MethodCall, result: MethodChannel.Result) {
        if (call.method == "close") {
            val request = current
            val target = call.argument<String>("context")
            val revision = call.argument<Number>("revision")?.toLong()
            val matching = (target == null || runCatching { GatewayContext.parse(target) == request?.context }.getOrDefault(false)) &&
                (revision == null || revision == request?.revision)
            if (request == null || !matching) result.success(null)
            else { request.closeResults.add(result); finish() }
            return
        }
        if (call.method != "signIn") { result.notImplemented(); return }
        if (closed || activity.isFinishing || activity.isDestroyed || current != null) {
            result.error("GATEWAY_BROWSER_BUSY", null, null); return
        }
        val context = runCatching { GatewayContext.parse(call.argument<String>("context") ?: "") }.getOrNull()
        val server = call.argument<String>("serverUrl")?.toHttpUrlOrNull()
        val policy = readPolicy()
        if (context == null || server == null || !context.allows(server) ||
            server.query != null || server.fragment != null || policy == null) {
            result.error("GATEWAY_INVALID_ARGUMENT", null, null); return
        }
        if (!server.isHttps && !policy.enabled) {
            result.error("GATEWAY_ONION_PROXY_REQUIRED", null, null); return
        }
        if (!GatewaySessions.supported()) {
            result.error("GATEWAY_UNSUPPORTED", null, null); return
        }
        if (policy.enabled && !WebViewFeature.isFeatureSupported(WebViewFeature.PROXY_OVERRIDE)) {
            result.error("GATEWAY_PROXY_UNSUPPORTED", null, null); return
        }
        if (!WebViewBrowserLease.acquire(this)) {
            result.error("GATEWAY_BROWSER_BUSY", null, null); return
        }
        val revision = try { GatewaySessions.beginSignIn(context) } catch (_: Exception) {
            WebViewBrowserLease.release(this)
            result.error("GATEWAY_UNAVAILABLE", null, null); return
        }
        val nonce = UUID.randomUUID().toString()
        val pkce = NerdVpnPkce.forServer(server, nonce)
        val login = pkce?.authorizationUrl(server) ?: server.newBuilder().encodedPath(server.encodedPath.trimEnd('/') + "/authorize_token")
            .addQueryParameter("scopes", ":feed,:subscriptions*,:playlists*,:history*")
            .addQueryParameter("callback_url", "videre-gateway://callback/$nonce").build().toString()
        val request = Request(result, context, revision, policy, login, nonce, pkce,
            call.argument<String>("title") ?: "Sign in to protected server",
            call.argument<String>("help") ?: "Sign in to your gateway, then authorize Invidious.",
            call.argument<String>("cancel") ?: "Cancel")
        current = request
        preferences.registerOnSharedPreferenceChangeListener(proxyChanged)
        handler.postDelayed(timeout, 10 * 60 * 1000L)
        if (readPolicy() != policy) { finish(error = "GATEWAY_PROXY_CHANGED"); return }
        if (!policy.enabled) { show(request); return }
        try {
            request.applying = true
            request.overridden = true
            val config = ProxyConfig.Builder().addProxyRule(policy.proxyUrl()).removeImplicitRules().build()
            ProxyController.getInstance().setProxyOverride(config, executor) {
                if (current !== request) return@setProxyOverride
                request.applying = false
                if (request.finishing) clearProxy(request)
                else if (readPolicy() != policy) finish(error = "GATEWAY_PROXY_CHANGED")
                else show(request)
            }
        } catch (_: Exception) {
            request.applying = false
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
                text = request.help
                setTextColor(Color.DKGRAY)
                setPadding(pad, 0, pad, pad / 2)
            }
            content.addView(heading)
            content.addView(hint)
            val web = WebView(activity)
            browser = web
            WebViewCompat.setProfile(web, GatewaySessions.signInProfileName(request.context, request.revision))
            web.settings.apply {
                javaScriptEnabled = true
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
                    if (!target.isForMainFrame) return target.url.scheme !in setOf("http", "https")
                    return navigate(request, view, target.url)
                }
                @Deprecated("Required for older WebView implementations")
                override fun shouldOverrideUrlLoading(view: WebView, target: String): Boolean =
                    navigate(request, view, Uri.parse(target))
                override fun onRenderProcessGone(view: WebView, detail: RenderProcessGoneDetail): Boolean {
                    finish(error = "GATEWAY_BROWSER_UNAVAILABLE"); return true
                }
            }
            content.addView(web, LinearLayout.LayoutParams(ViewGroup.LayoutParams.MATCH_PARENT, 0, 1f))
            content.addView(Button(activity).apply { text = request.cancel; setOnClickListener { finish() } })
            surface.setContentView(content)
            surface.setCancelable(true)
            surface.setOnCancelListener { finish() }
            surface.show()
            surface.window?.setLayout(ViewGroup.LayoutParams.MATCH_PARENT, ViewGroup.LayoutParams.MATCH_PARENT)
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
            val token = uri.getQueryParameter("token")
            if (uri.host == "callback" && uri.path == "/${request.nonce}" &&
                previous != null && request.context.allows(previous) &&
                !token.isNullOrBlank() && token.length <= 65536) {
                if (GatewaySessions.completeSignIn(request.context, request.revision)) finish(token = token)
                else finish(error = "GATEWAY_LOGIN_CANCELLED")
            }
            return true
        }
        val target = uri.toString().toHttpUrlOrNull()
        if (target == null || !request.context.canNavigateDuringSignIn(target, request.policy.enabled)) return true
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
            val profileName = GatewaySessions.signInProfileName(request.context, request.revision)
            val manager = ProfileStore.getInstance().getOrCreateProfile(profileName).cookieManager
            val url = request.context.origin.newBuilder().encodedPath("/api/v1/token").build()
            val cookie = manager.getCookie(url.toString())
            val json = JSONObject().put("code", code).put("code_verifier", pkce.verifier)
                .put("callback_url", pkce.callbackUrl)
            val outgoing = HttpRequest.Builder().url(url)
                .post(json.toString().toRequestBody("application/json".toMediaType()))
                .header("Accept", "application/json")
                .apply { if (!cookie.isNullOrBlank()) header("Cookie", cookie) }.build()
            val call = ProxyDataSource.newTokenExchangeCall(outgoing)
            request.exchange = call
            web.stopLoading()
            web.settings.blockNetworkLoads = true
            call.enqueue(object : Callback {
                override fun onFailure(call: Call, error: IOException) {
                    handler.post {
                        if (current === request && !request.finishing) finish(error = "GATEWAY_TOKEN_UNAVAILABLE")
                    }
                }

                override fun onResponse(call: Call, response: Response) {
                    var token: String? = null
                    var error = "GATEWAY_TOKEN_EXCHANGE_FAILED"
                    var errorDetails: Map<String, Any>? = null
                    var cookies: List<String> = emptyList()
                    response.use {
                        if (it.code == 429 || it.code == 503) {
                            error = "GATEWAY_TOKEN_UNAVAILABLE"
                            errorDetails = mapOf("statusCode" to it.code, "retryAfter" to (it.header("Retry-After") ?: ""))
                        }
                        try {
                            val bytes = it.peekBody(65537).bytes()
                            val json = if (bytes.size <= 65536) JSONObject(String(bytes, Charsets.UTF_8)) else null
                            if (it.code == 200) {
                                token = (json?.opt("token") as? String)?.takeIf { value ->
                                    value.isNotBlank() && value.length <= 65536
                                }
                                cookies = it.headers("Set-Cookie")
                                if (cookies.size > 100 || cookies.any { value -> value.length > 16384 }) token = null
                            } else if (it.code == 400 && json?.optString("error") == "invalid_grant") {
                                error = "GATEWAY_TOKEN_EXPIRED"
                            }
                        } catch (_: Exception) {
                            // Server response bodies can contain credentials.
                        }
                    }
                    val exchanged = token
                    val returnedCookies = cookies
                    val failure = error
                    val failureDetails = errorDetails
                    handler.post {
                        if (current !== request || request.finishing) return@post
                        if (readPolicy() != request.policy) { finish(error = "GATEWAY_PROXY_CHANGED"); return@post }
                        if (exchanged == null) { finish(error = failure, details = failureDetails); return@post }
                        try {
                            val pendingName = GatewaySessions.signInProfileName(request.context, request.revision)
                            val pendingCookies = ProfileStore.getInstance().getOrCreateProfile(pendingName).cookieManager
                            returnedCookies.forEach { value -> pendingCookies.setCookie(url.toString(), value) }
                            if (GatewaySessions.completeSignIn(request.context, request.revision)) finish(token = exchanged)
                            else finish(error = "GATEWAY_LOGIN_CANCELLED")
                        } catch (_: Exception) { finish(error = "GATEWAY_TOKEN_EXCHANGE_FAILED") }
                    }
                }
            })
        } catch (_: Exception) { finish(error = "GATEWAY_TOKEN_EXCHANGE_FAILED") }
    }

    fun close() { closed = true; finish() }

    private fun finish(token: String? = null, error: String? = null, details: Map<String, Any>? = null) {
        val request = current ?: return
        if (request.finishing) return
        request.finishing = true
        request.token = token
        request.error = error
        request.errorDetails = details
        request.exchange?.cancel()
        handler.removeCallbacks(timeout)
        preferences.unregisterOnSharedPreferenceChangeListener(proxyChanged)
        approval?.setOnCancelListener(null)
        approval?.dismiss()
        approval = null
        dialog?.setOnCancelListener(null)
        dialog?.dismiss()
        dialog = null
        browser?.let {
            runCatching { it.settings.blockNetworkLoads = true }
            runCatching { it.stopLoading() }
            runCatching { (it.parent as? ViewGroup)?.removeView(it) }
            runCatching { it.destroy() }
        }
        browser = null
        if (token == null) runCatching { GatewaySessions.cancelSignIn(request.context, request.revision) }
        clearProxy(request)
    }

    private fun clearProxy(request: Request) {
        if (current !== request || !request.finishing || request.applying || request.clearing) return
        if (!request.overridden) { complete(request); return }
        request.clearing = true
        try {
            ProxyController.getInstance().clearProxyOverride(executor) {
                request.overridden = false
                request.clearing = false
                complete(request)
            }
        } catch (_: Exception) {
            WebViewBrowserLease.block()
            request.error = "GATEWAY_PROXY_UNAVAILABLE"
            complete(request)
        }
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
