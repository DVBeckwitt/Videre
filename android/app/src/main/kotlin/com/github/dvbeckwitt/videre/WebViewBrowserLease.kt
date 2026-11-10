package com.github.dvbeckwitt.videre

import androidx.webkit.ProxyConfig
import androidx.webkit.ProxyController
import androidx.webkit.ServiceWorkerControllerCompat
import androidx.webkit.WebViewFeature
import com.github.dvbeckwitt.videre.proxy.BrowserPrivacyProxy
import java.util.concurrent.Executor

/** UI-thread lease: proxy overrides affect every WebView in this process. */
internal object WebViewBrowserLease {
    private var owner: Any? = null
    private var proxy: BrowserPrivacyProxy? = null

    fun supported(): Boolean = runCatching {
        WebViewFeature.isFeatureSupported(WebViewFeature.PROXY_OVERRIDE) &&
            WebViewFeature.isFeatureSupported(WebViewFeature.SERVICE_WORKER_BASIC_USAGE) &&
            WebViewFeature.isFeatureSupported(WebViewFeature.SERVICE_WORKER_BLOCK_NETWORK_LOADS)
    }.getOrDefault(false)

    fun acquire(value: Any): Boolean {
        if (owner != null) return false
        owner = value
        return true
    }

    fun install(value: Any, executor: Executor, applied: () -> Unit) {
        check(owner === value)
        // Reserve the same loopback listener for the process lifetime. Every
        // installed override points to it, even when application races close.
        val filter = proxy ?: BrowserPrivacyProxy().also { proxy = it }
        ServiceWorkerControllerCompat.getInstance().serviceWorkerWebSettings.blockNetworkLoads = true
        val config = ProxyConfig.Builder().addProxyRule(filter.url).removeImplicitRules().build()
        ProxyController.getInstance().setProxyOverride(config, executor) { applied() }
    }

    fun allow(value: Any, socksHost: String?, socksPort: Int?) {
        check(owner === value)
        checkNotNull(proxy).allow(socksHost, socksPort)
    }

    fun deny(value: Any) {
        if (owner === value) proxy?.deny()
    }

    fun release(value: Any) {
        if (owner !== value) return
        deny(value)
        owner = null
        // Leave WebView pinned to the denying route. Clearing the override
        // would put late requests and background activity back on system routing.
    }
}
