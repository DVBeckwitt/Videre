package com.github.dvbeckwitt.videre

/** UI-thread lease: proxy overrides affect every WebView in this process. */
internal object WebViewBrowserLease {
    private var owner: Any? = null
    private var blocked = false
    fun acquire(value: Any): Boolean {
        if (blocked || owner != null) return false
        owner = value
        return true
    }
    fun release(value: Any) { if (owner === value) owner = null }
    fun block() { blocked = true }
}
