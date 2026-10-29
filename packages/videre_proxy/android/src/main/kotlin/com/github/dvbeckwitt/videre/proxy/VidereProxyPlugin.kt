package com.github.dvbeckwitt.videre.proxy

import android.app.Activity
import android.app.Application
import android.content.Context
import android.content.Intent
import android.content.SharedPreferences
import android.os.Bundle
import android.os.Handler
import android.os.Looper
import androidx.lifecycle.Lifecycle
import androidx.lifecycle.LifecycleOwner
import androidx.media3.datasource.HttpDataSource
import androidx.media3.datasource.okhttp.OkHttpDataSource
import io.flutter.embedding.engine.plugins.FlutterPlugin
import io.flutter.embedding.engine.plugins.activity.ActivityAware
import io.flutter.embedding.engine.plugins.activity.ActivityPluginBinding
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import io.flutter.plugin.common.PluginRegistry
import io.flutter.plugin.common.StandardMethodCodec
import java.io.IOException
import java.util.concurrent.ExecutorService
import java.util.concurrent.Executors
import java.util.concurrent.RejectedExecutionException
import java.util.concurrent.TimeUnit
import okhttp3.Call
import okhttp3.Callback
import okhttp3.Request
import okhttp3.Response
import org.json.JSONObject

/** One transport shared by foreground video, audio-service and background engines. */
object ProxyDataSource {
    private val calls = PolicyCallFactory()
    private var preferences: SharedPreferences? = null
    private var policy: ProxyPolicy? = null

    @Synchronized
    internal fun initialize(context: Context) {
        if (preferences != null) return
        val store = context.applicationContext.getSharedPreferences("videre_network_proxy", Context.MODE_PRIVATE)
        preferences = store
        try {
            val saved = store.getString("configuration", null)
            val loaded = if (saved == null) ProxyPolicy() else {
                val json = JSONObject(saved)
                ProxyPolicy.fromMap(json.keys().asSequence().associateWith { json.get(it) })
            }
            calls.configure(loaded)
            policy = loaded
        } catch (_: Exception) {
            // Corrupt saved settings must never turn an enabled proxy into DIRECT.
            calls.block()
            policy = null
        }
    }

    @Synchronized
    internal fun configure(values: Map<*, *>): Boolean {
        val next = ProxyPolicy.fromMap(values)
        val store = checkNotNull(preferences) { "SOCKS5 transport is not initialized." }
        if (next == policy) return false
        check(store.edit().putString("configuration", JSONObject(next.toMap()).toString()).commit()) {
            "Could not save SOCKS5 proxy settings."
        }
        calls.configure(next)
        policy = next
        return true
    }

    @Synchronized
    internal fun configuration(): Map<String, Any> = checkNotNull(policy) {
        "Saved SOCKS5 proxy settings are invalid."
    }.toMap()

    @Synchronized
    internal fun newApiCall(request: Request, options: ApiRedirectOptions, expectedProxy: ProxyPolicy? = null): Call {
        // Configuration replacement uses this same monitor, so comparing a
        // worker's snapshot and choosing its transport are one operation.
        requireMatchingOnionProxy(expectedProxy, policy)
        return calls.newApiCall(request, options)
    }

    @JvmStatic
    @Synchronized
    fun factory(userAgent: String?, headers: Map<String, String>?, sourceUri: String?): HttpDataSource.Factory {
        // Plugin registration loads persisted policy before player creation.
        // If a caller beats registration, calls remain blocked until it finishes.
        val effectiveHeaders = headers.orEmpty().toMutableMap()
        val explicitUserAgent = effectiveHeaders.entries.firstOrNull { it.key.equals("User-Agent", true) }?.value
        val resolvedUserAgent = explicitUserAgent ?: userAgent
        if (explicitUserAgent == null && userAgent != null) effectiveHeaders["User-Agent"] = userAgent
        return OkHttpDataSource.Factory(calls.forSource(sourceUri, effectiveHeaders, policy)).apply {
            setUserAgent(resolvedUserAgent)
            setDefaultRequestProperties(effectiveHeaders)
        }
    }
}

class VidereProxyPlugin : FlutterPlugin, MethodChannel.MethodCallHandler, ActivityAware,
    PluginRegistry.ActivityResultListener {
    companion object {
        private const val LAST_VERIFICATION_REQUEST = 0x7FFF
        private const val VERIFICATION_TIMEOUT_MS = 125_000L
        private const val CANCELLED = "ONION_VERIFICATION_CANCELLED"
        private const val FAILED = "ONION_VERIFICATION_FAILED"
        private const val UNAVAILABLE = "ONION_VERIFICATION_UNAVAILABLE"
        private const val UNSUPPORTED_WEBVIEW = "ONION_VERIFICATION_UNSUPPORTED_WEBVIEW"

        // All access occurs on the main thread, including calls from background engines.
        private var activeVerifier: VidereProxyPlugin? = null
        // Never recycle a code in this process: a cancelled Activity can still
        // deliver its result after a newer verification has started.
        private var nextVerificationRequest = 0x5000
    }

    private class Verification(
        val origin: String,
        val policy: ProxyPolicy,
        val result: MethodChannel.Result,
        var host: Activity,
        val epoch: Long,
        val requestCode: Int,
    ) {
        var timeout: Runnable? = null
        var readingResult = false
    }

    private var channel: MethodChannel? = null
    private val mainHandler = Handler(Looper.getMainLooper())
    private val pendingLock = Any()
    private val pending = mutableSetOf<Call>()
    private var engineEpoch = 0L
    private var attached = false
    @Volatile private var applicationContext: Context? = null
    private var application: Application? = null
    private var activityBinding: ActivityPluginBinding? = null
    private var hostResumed = false
    private var verification: Verification? = null
    private var verificationWorker: ExecutorService? = null
    private val lifecycleCallbacks = object : Application.ActivityLifecycleCallbacks {
        override fun onActivityResumed(activity: Activity) {
            if (activityBinding?.activity === activity) hostResumed = true
        }

        override fun onActivityPaused(activity: Activity) {
            if (activityBinding?.activity === activity) hostResumed = false
        }

        override fun onActivityStopped(activity: Activity) {
            if (activityBinding?.activity === activity) hostResumed = false
        }

        override fun onActivityDestroyed(activity: Activity) {
            if (activityBinding?.activity === activity) {
                hostResumed = false
                if (!activity.isChangingConfigurations) cancelVerification(CANCELLED)
            }
        }

        override fun onActivityCreated(activity: Activity, state: Bundle?) = Unit
        override fun onActivityStarted(activity: Activity) = Unit
        override fun onActivitySaveInstanceState(activity: Activity, state: Bundle) = Unit
    }

    override fun onAttachedToEngine(binding: FlutterPlugin.FlutterPluginBinding) {
        ProxyDataSource.initialize(binding.applicationContext)
        applicationContext = binding.applicationContext.applicationContext
        application = applicationContext as? Application
        application?.registerActivityLifecycleCallbacks(lifecycleCallbacks)
        verificationWorker = Executors.newSingleThreadExecutor()
        synchronized(pendingLock) {
            attached = true
            engineEpoch++
        }
        // Policy saves commit preferences and close idle TLS sockets. Keep that
        // work serial and off Android's main thread, including TLS shutdown.
        channel = MethodChannel(
            binding.binaryMessenger,
            "videre/proxy",
            StandardMethodCodec.INSTANCE,
            binding.binaryMessenger.makeBackgroundTaskQueue(),
        ).also {
            it.setMethodCallHandler(this)
        }
    }

    override fun onDetachedFromEngine(binding: FlutterPlugin.FlutterPluginBinding) {
        onMain {
            cancelVerification(CANCELLED)
            detachActivity()
            application?.unregisterActivityLifecycleCallbacks(lifecycleCallbacks)
            application = null
            verificationWorker?.shutdownNow()
            verificationWorker = null
            applicationContext = null
        }
        val staleCalls = synchronized(pendingLock) {
            attached = false
            engineEpoch++
            pending.toList().also { pending.clear() }
        }
        staleCalls.forEach(Call::cancel)
        channel?.setMethodCallHandler(null)
        channel = null
    }

    override fun onMethodCall(call: MethodCall, result: MethodChannel.Result) {
        try {
            when (call.method) {
                "configure" -> {
                    val changed = ProxyDataSource.configure(call.arguments as? Map<*, *>
                        ?: throw IllegalArgumentException("Proxy configuration is required."))
                    onMain {
                        if (changed) activeVerifier?.cancelVerification(CANCELLED)
                        result.success(null)
                    }
                }
                "getConfiguration" -> result.success(ProxyDataSource.configuration())
                "getOnionSessions" -> getOnionSessions(result)
                "verifyOnionSession" -> verifyOnionSession(call.arguments, result)
                "request" -> request(call.arguments, result)
                else -> result.notImplemented()
            }
        } catch (error: Exception) {
            result.error("PROXY_CONFIGURATION", error.message, null)
        }
    }

    override fun onAttachedToActivity(binding: ActivityPluginBinding) {
        activityBinding = binding
        binding.addActivityResultListener(this)
        // Registration normally precedes resume. This also handles an engine
        // attached to an already-visible FlutterActivity.
        hostResumed = (binding.activity as? LifecycleOwner)?.lifecycle?.currentState
            ?.isAtLeast(Lifecycle.State.RESUMED) == true
        verification?.host = binding.activity
    }

    override fun onDetachedFromActivityForConfigChanges() = detachActivity()

    override fun onReattachedToActivityForConfigChanges(binding: ActivityPluginBinding) = onAttachedToActivity(binding)

    override fun onDetachedFromActivity() {
        cancelVerification(CANCELLED)
        detachActivity()
    }

    private fun detachActivity() {
        activityBinding?.removeActivityResultListener(this)
        activityBinding = null
        hostResumed = false
    }

    private fun currentPolicy(): ProxyPolicy? = try {
        ProxyPolicy.fromMap(ProxyDataSource.configuration())
    } catch (_: Exception) {
        null
    }

    private fun getOnionSessions(result: MethodChannel.Result) {
        val context = applicationContext
        val policy = currentPolicy()
        if (context == null || policy == null) {
            verificationError(result, UNAVAILABLE)
            return
        }
        try {
            result.success(OnionSessionStore.getAll(context, policy))
        } catch (_: Exception) {
            verificationError(result, UNAVAILABLE)
        }
    }

    private fun verifyOnionSession(arguments: Any?, result: MethodChannel.Result) {
        val rawOrigin = (arguments as? Map<*, *>)?.get("url") as? String
        val origin = rawOrigin?.let(::canonicalOnionOrigin)
        val policy = currentPolicy()
        if (origin == null || policy?.enabled != true) {
            verificationError(result, UNAVAILABLE)
            return
        }
        onMain {
            val host = activityBinding?.activity
            val epoch = synchronized(pendingLock) { if (attached) engineEpoch else null }
            if (host == null || !hostResumed || host.isFinishing || host.isDestroyed || epoch == null ||
                currentPolicy() != policy || applicationContext == null || activeVerifier != null ||
                nextVerificationRequest > LAST_VERIFICATION_REQUEST) {
                verificationError(result, UNAVAILABLE)
                return@onMain
            }
            val next = Verification(origin, policy, result, host, epoch, nextVerificationRequest++)
            verification = next
            activeVerifier = this
            next.timeout = Runnable { completeVerification(next, error = FAILED, closeActivity = true) }
            mainHandler.postDelayed(checkNotNull(next.timeout), VERIFICATION_TIMEOUT_MS)
            try {
                host.startActivityForResult(
                    Intent(host, OnionVerificationActivity::class.java)
                        .putExtra(OnionVerificationActivity.ORIGIN, origin)
                        .putExtra(OnionVerificationActivity.PROXY_CONFIGURATION, JSONObject(policy.toMap()).toString()),
                    next.requestCode,
                )
            } catch (_: Exception) {
                completeVerification(next, error = UNAVAILABLE)
            }
        }
    }

    override fun onActivityResult(requestCode: Int, resultCode: Int, data: Intent?): Boolean {
        val current = verification ?: return false
        if (requestCode != current.requestCode) return false
        if (current.readingResult) return true
        if (resultCode != Activity.RESULT_OK) {
            val reported = data?.getStringExtra(OnionVerificationActivity.ERROR)
            completeVerification(current, error = when (reported) {
                CANCELLED, FAILED, UNAVAILABLE, UNSUPPORTED_WEBVIEW -> reported
                else -> if (resultCode == Activity.RESULT_CANCELED) CANCELLED else FAILED
            })
            return true
        }
        current.readingResult = true
        val context = applicationContext
        val worker = verificationWorker
        if (context == null || worker == null) {
            completeVerification(current, error = UNAVAILABLE)
            return true
        }
        try {
            worker.execute {
                val session = try {
                    if (currentPolicy() == current.policy) OnionSessionStore.getAll(context, current.policy)[current.origin]
                    else null
                } catch (_: Exception) {
                    null
                }
                onMain {
                    val isAttached = synchronized(pendingLock) { attached && engineEpoch == current.epoch }
                    if (session == null || !isAttached || currentPolicy() != current.policy) {
                        completeVerification(current, error = FAILED)
                    } else {
                        completeVerification(current, session = session)
                    }
                }
            }
        } catch (_: RejectedExecutionException) {
            completeVerification(current, error = UNAVAILABLE)
        }
        return true
    }

    private fun cancelVerification(error: String) {
        verification?.let { completeVerification(it, error = error, closeActivity = true) }
    }

    private fun completeVerification(
        current: Verification,
        session: Map<String, Any>? = null,
        error: String = FAILED,
        closeActivity: Boolean = false,
    ) {
        if (verification !== current) return
        verification = null
        if (activeVerifier === this) activeVerifier = null
        current.timeout?.let(mainHandler::removeCallbacks)
        if (closeActivity) {
            try {
                current.host.finishActivity(current.requestCode)
            } catch (_: Exception) {
                // The Activity may already have been destroyed.
            }
        }
        if (session != null) current.result.success(session) else verificationError(current.result, error)
    }

    private fun verificationError(result: MethodChannel.Result, code: String) {
        val message = when (code) {
            CANCELLED -> "Onion verification was cancelled."
            UNAVAILABLE -> "Onion verification requires an active screen and an enabled SOCKS5 proxy."
            UNSUPPORTED_WEBVIEW -> "Update Android System WebView to verify this onion instance securely."
            else -> "The onion instance could not be verified."
        }
        result.error(code, message, null)
    }

    private fun onMain(action: () -> Unit) {
        if (Looper.myLooper() == Looper.getMainLooper()) action() else mainHandler.post(action)
    }

    private fun request(arguments: Any?, result: MethodChannel.Result) {
        val httpCall: Call
        try {
            val values = arguments as? Map<*, *>
                ?: throw IllegalArgumentException("HTTP request arguments are required.")
            val request = buildApiRequest(values)
            httpCall = ProxyDataSource.newApiCall(
                request,
                ApiRedirectOptions.fromMap(values),
                expectedOnionProxy(values, request),
            )
            httpCall.timeout().timeout(30, TimeUnit.SECONDS)
        } catch (_: IllegalArgumentException) {
            result.error("INVALID_HTTP_REQUEST", "Invalid HTTP request arguments.", null)
            return
        } catch (_: IOException) {
            result.error("NATIVE_HTTP_ERROR", "The network request could not start.", null)
            return
        }
        val epoch = synchronized(pendingLock) {
            if (!attached) {
                httpCall.cancel()
                result.error("NATIVE_HTTP_ERROR", "The network request was cancelled.", null)
                return
            }
            pending.add(httpCall)
            engineEpoch
        }
        httpCall.enqueue(object : Callback {
            override fun onFailure(call: Call, error: IOException) {
                finish(httpCall, epoch) {
                    result.error("NATIVE_HTTP_ERROR", "The network request failed or was cancelled.", null)
                }
            }

            override fun onResponse(call: Call, response: Response) {
                try {
                    val value = response.use(::readApiResponse)
                    finish(httpCall, epoch) { result.success(value) }
                } catch (_: ApiBodyTooLarge) {
                    finish(httpCall, epoch) {
                        result.error("NATIVE_HTTP_BODY_TOO_LARGE", "Network response exceeds 4 MiB.", null)
                    }
                } catch (_: IOException) {
                    finish(httpCall, epoch) {
                        result.error("NATIVE_HTTP_ERROR", "The network response failed or was cancelled.", null)
                    }
                }
            }
        })
    }

    private fun finish(call: Call, epoch: Long, deliver: () -> Unit) {
        synchronized(pendingLock) {
            pending.remove(call)
            if (!attached || engineEpoch != epoch) return
        }
        mainHandler.post {
            val current = synchronized(pendingLock) { attached && engineEpoch == epoch }
            if (current) deliver()
        }
    }
}
