package com.github.dvbeckwitt.videre

import android.app.Activity
import android.app.AlertDialog
import android.content.Intent
import android.content.SharedPreferences
import android.net.Uri
import android.os.Handler
import android.os.Looper
import android.os.SystemClock
import com.github.dvbeckwitt.videre.proxy.GatewayContext
import com.github.dvbeckwitt.videre.proxy.NerdVpnPkce
import com.github.dvbeckwitt.videre.proxy.ProxyDataSource
import io.flutter.plugin.common.MethodChannel
import java.io.IOException
import java.io.InterruptedIOException
import okhttp3.Call
import okhttp3.Callback
import okhttp3.HttpUrl
import okhttp3.MediaType.Companion.toMediaType
import okhttp3.Request
import okhttp3.RequestBody
import okhttp3.Response
import okio.BufferedSink
import okio.ByteString.Companion.encodeUtf8
import org.json.JSONObject

/** Explicit default-browser sign-in. This path never creates a WebView profile. */
internal class NerdVpnBrowserAuth(
    private val activity: Activity,
    private val preferences: SharedPreferences,
) {
    private class Pending(val attempt: NerdVpnBrowserAttempt, val result: MethodChannel.Result,
        val cancel: String, val policyIsCurrent: () -> Boolean, val protectedBrowser: () -> Unit) {
        var dialog: AlertDialog? = null
        var exchange: Call? = null
        var timeout: Runnable? = null
    }

    private val handler = Handler(Looper.getMainLooper())
    private var pending: Pending? = null
    val active: Boolean get() = pending != null
    private val proxyChanged = SharedPreferences.OnSharedPreferenceChangeListener { _, key ->
        val request = pending
        if (key == "configuration" && request != null) {
            handler.post { finish(request, error = "GATEWAY_PROXY_CHANGED") }
        }
    }

    fun start(attempt: NerdVpnBrowserAttempt, result: MethodChannel.Result, cancel: String,
        policyIsCurrent: () -> Boolean, protectedBrowser: () -> Unit) {
        check(pending == null)
        val request = Pending(attempt, result, cancel, policyIsCurrent, protectedBrowser)
        pending = request
        preferences.registerOnSharedPreferenceChangeListener(proxyChanged)
        request.timeout = Runnable { finish(request, error = "GATEWAY_LOGIN_TIMEOUT") }.also {
            handler.postDelayed(it, NerdVpnBrowserAttempt.TIMEOUT_MILLIS)
        }
        if (!current(request)) return
        try {
            request.dialog = AlertDialog.Builder(activity)
                .setTitle("Sign in to NerdVPN")
                .setMessage("Your default browser can complete NerdVPN's sign-in checks. " +
                    "It uses its own connection and cookies, outside Videre's proxy and privacy controls. " +
                    "Your password stays in that browser. Videre receives an authorization code. " +
                    "Or sign in inside Videre with JavaScript enabled for NerdVPN in a temporary session using your direct connection.")
                .setPositiveButton("Sign in with browser") { _, _ -> launch(request) }
                .setNeutralButton("Sign in in app") { _, _ ->
                    if (current(request)) {
                        clear(request)
                        request.protectedBrowser()
                    }
                }
                .setNegativeButton(cancel) { _, _ -> finish(request) }
                .setOnCancelListener { finish(request) }
                .show()
        } catch (_: Exception) { finish(request, error = "GATEWAY_EXTERNAL_BROWSER_UNAVAILABLE") }
    }

    fun close(context: String? = null): Boolean {
        val request = pending ?: return false
        if (context == null || runCatching { GatewayContext.parse(context) == request.attempt.context }.getOrDefault(false)) {
            finish(request)
        }
        return true
    }

    fun acceptCallback(value: String) {
        val request = pending ?: return
        if (!current(request)) return
        val code = request.attempt.takeCode(value, SystemClock.elapsedRealtime()) ?: return
        try {
            val call = ProxyDataSource.newTokenExchangeCall(
                NerdVpnTokenExchange.request(request.attempt.server, request.attempt.pkce, code))
            request.exchange = call
            call.enqueue(object : Callback {
                override fun onFailure(call: Call, error: IOException) {
                    handler.post { finish(request, error = NerdVpnTokenExchange.transportError(error)) }
                }

                override fun onResponse(call: Call, response: Response) {
                    val exchanged = NerdVpnTokenExchange.read(response)
                    handler.post {
                        if (!current(request)) return@post
                        if (exchanged.token == null) finish(request, error = exchanged.error, details = exchanged.details)
                        else finish(request, token = exchanged.token)
                    }
                }
            })
        } catch (_: Exception) { finish(request, error = "GATEWAY_TOKEN_EXCHANGE_FAILED") }
    }

    private fun launch(request: Pending) {
        if (!current(request) || !request.attempt.launch(SystemClock.elapsedRealtime())) return
        dismiss(request)
        try {
            request.dialog = AlertDialog.Builder(activity)
                .setTitle("Finish sign-in in your browser")
                .setMessage("Authorize Videre in your browser to return here. " +
                    "Canceling keeps your saved account unchanged.")
                .setNegativeButton(request.cancel) { _, _ -> finish(request) }
                .setOnCancelListener { finish(request) }
                .show()
            // Android opens the user's default browser, or its chooser when no
            // default exists. Do not select a package or change proxy settings.
            activity.startActivity(Intent(Intent.ACTION_VIEW,
                Uri.parse(request.attempt.pkce.authorizationUrl(request.attempt.server))).apply {
                    addCategory(Intent.CATEGORY_BROWSABLE)
                })
        } catch (_: Exception) { finish(request, error = "GATEWAY_EXTERNAL_BROWSER_UNAVAILABLE") }
    }

    private fun current(request: Pending): Boolean {
        if (pending !== request) return false
        val error = when {
            request.attempt.expired(SystemClock.elapsedRealtime()) -> "GATEWAY_LOGIN_TIMEOUT"
            !request.policyIsCurrent() -> "GATEWAY_PROXY_CHANGED"
            activity.isFinishing || activity.isDestroyed -> "GATEWAY_BROWSER_UNAVAILABLE"
            else -> null
        }
        if (error != null) finish(request, error = error)
        return error == null
    }

    private fun dismiss(request: Pending) {
        request.dialog?.setOnCancelListener(null)
        request.dialog?.dismiss()
        request.dialog = null
    }

    private fun clear(request: Pending) {
        pending = null
        request.attempt.close()
        request.timeout?.let(handler::removeCallbacks)
        preferences.unregisterOnSharedPreferenceChangeListener(proxyChanged)
        request.exchange?.cancel()
        dismiss(request)
    }

    private fun finish(request: Pending, token: String? = null, error: String? = null,
        details: Map<String, Any>? = null) {
        if (pending !== request) return
        clear(request)
        if (error == null) request.result.success(token)
        else request.result.error(error, null, details)
    }
}

/** Shared wire contract; response bodies and grants are never diagnostic text. */
internal object NerdVpnTokenExchange {
    class Result(val token: String?, val error: String, val details: Map<String, Any>?, val cookies: List<String>)

    fun transportError(error: IOException): String =
        if (error is InterruptedIOException) "GATEWAY_TOKEN_TIMEOUT" else "GATEWAY_TOKEN_UNAVAILABLE"

    fun exchangeBody(json: String): RequestBody {
        val bytes = json.encodeUtf8()
        return object : RequestBody() {
            override fun contentType() = "application/json; charset=utf-8".toMediaType()
            override fun contentLength() = bytes.size.toLong()
            // A 503 with Retry-After: 0 can otherwise make OkHttp resend a single-use code.
            override fun isOneShot() = true
            override fun writeTo(sink: BufferedSink) { sink.write(bytes) }
        }
    }

    fun request(origin: HttpUrl, pkce: NerdVpnPkce, code: String, cookie: String? = null): Request {
        val json = JSONObject().put("code", code).put("code_verifier", pkce.verifier)
            .put("callback_url", pkce.callbackUrl)
        return Request.Builder().url(origin.newBuilder().encodedPath("/api/v1/token").build())
            .post(exchangeBody(json.toString()))
            .header("Accept", "application/json")
            .apply { if (!cookie.isNullOrBlank()) header("Cookie", cookie) }.build()
    }

    fun read(response: Response): Result {
        var token: String? = null
        var error = "GATEWAY_TOKEN_EXCHANGE_FAILED"
        var cookies: List<String> = emptyList()
        try {
            response.use {
                if (it.code == 429 || it.code == 503) {
                    return Result(null, "GATEWAY_TOKEN_UNAVAILABLE",
                        mapOf("statusCode" to it.code, "retryAfter" to (it.header("Retry-After") ?: "")), emptyList())
                }
                val bytes = it.peekBody(65537).bytes()
                val json = if (bytes.size <= 65536) JSONObject(String(bytes, Charsets.UTF_8)) else null
                if (it.code == 200) {
                    token = (json?.opt("token") as? String)?.takeIf { value -> value.isNotBlank() && value.length <= 65536 }
                    cookies = it.headers("Set-Cookie")
                    if (cookies.size > 100 || cookies.any { value -> value.length > 16384 }) token = null
                } else if (it.code == 400 && json?.optString("error") == "invalid_grant") {
                    error = "GATEWAY_TOKEN_EXPIRED"
                }
            }
        } catch (failure: IOException) {
            return Result(null, transportError(failure), null, emptyList())
        } catch (_: Exception) { token = null /* Response bodies can contain credentials. */ }
        return Result(token, error, null, cookies)
    }
}
