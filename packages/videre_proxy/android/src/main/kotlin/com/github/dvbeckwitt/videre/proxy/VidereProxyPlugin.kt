package com.github.dvbeckwitt.videre.proxy

import android.content.Context
import android.content.SharedPreferences
import android.os.Handler
import android.os.Looper
import androidx.media3.datasource.HttpDataSource
import androidx.media3.datasource.okhttp.OkHttpDataSource
import io.flutter.embedding.engine.plugins.FlutterPlugin
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import io.flutter.plugin.common.StandardMethodCodec
import java.io.IOException
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
    internal fun configure(values: Map<*, *>) {
        val next = ProxyPolicy.fromMap(values)
        val store = checkNotNull(preferences) { "SOCKS5 transport is not initialized." }
        if (next == policy) return
        check(store.edit().putString("configuration", JSONObject(next.toMap()).toString()).commit()) {
            "Could not save SOCKS5 proxy settings."
        }
        calls.configure(next)
        policy = next
    }

    @Synchronized
    internal fun configuration(): Map<String, Any> = checkNotNull(policy) {
        "Saved SOCKS5 proxy settings are invalid."
    }.toMap()

    internal fun newApiCall(request: Request, options: ApiRedirectOptions): Call = calls.newApiCall(request, options)

    @JvmStatic
    fun factory(userAgent: String?, headers: Map<String, String>?, sourceUri: String?): HttpDataSource.Factory {
        // Plugin registration loads persisted policy before player creation.
        // If a caller beats registration, calls remain blocked until it finishes.
        return OkHttpDataSource.Factory(calls.forSource(sourceUri, headers?.keys ?: emptySet())).apply {
            setUserAgent(userAgent)
            if (headers != null) setDefaultRequestProperties(headers)
        }
    }
}

class VidereProxyPlugin : FlutterPlugin, MethodChannel.MethodCallHandler {
    private var channel: MethodChannel? = null
    private val mainHandler = Handler(Looper.getMainLooper())
    private val pendingLock = Any()
    private val pending = mutableSetOf<Call>()
    private var engineEpoch = 0L
    private var attached = false

    override fun onAttachedToEngine(binding: FlutterPlugin.FlutterPluginBinding) {
        ProxyDataSource.initialize(binding.applicationContext)
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
                    ProxyDataSource.configure(call.arguments as? Map<*, *>
                        ?: throw IllegalArgumentException("Proxy configuration is required."))
                    result.success(null)
                }
                "getConfiguration" -> result.success(ProxyDataSource.configuration())
                "request" -> request(call.arguments, result)
                else -> result.notImplemented()
            }
        } catch (error: Exception) {
            result.error("PROXY_CONFIGURATION", error.message, null)
        }
    }

    private fun request(arguments: Any?, result: MethodChannel.Result) {
        val httpCall: Call
        try {
            val values = arguments as? Map<*, *>
                ?: throw IllegalArgumentException("HTTP request arguments are required.")
            httpCall = ProxyDataSource.newApiCall(buildApiRequest(values), ApiRedirectOptions.fromMap(values))
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
