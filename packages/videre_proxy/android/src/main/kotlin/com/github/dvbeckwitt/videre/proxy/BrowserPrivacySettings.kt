package com.github.dvbeckwitt.videre.proxy

import android.webkit.WebView
import androidx.webkit.WebSettingsCompat
import androidx.webkit.WebViewFeature
import androidx.webkit.WebViewMediaIntegrityApiStatusConfig

/** Page scripts can create WebRTC UDP sockets outside Chromium's HTTP proxy.
 * Keep page JavaScript disabled; do not temporarily enable it for extraction. */
object BrowserPrivacySettings {
    fun apply(web: WebView) {
        web.settings.blockNetworkLoads = true
        web.settings.javaScriptEnabled = false
        if (WebViewFeature.isFeatureSupported(WebViewFeature.WEBVIEW_MEDIA_INTEGRITY_API_STATUS)) {
            WebSettingsCompat.setWebViewMediaIntegrityApiStatus(web.settings,
                WebViewMediaIntegrityApiStatusConfig.Builder(
                    WebViewMediaIntegrityApiStatusConfig.WEBVIEW_MEDIA_INTEGRITY_API_DISABLED).build())
        }
    }
}
