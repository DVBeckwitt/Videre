package com.github.dvbeckwitt.videre.proxy

import java.io.IOException
import java.util.Locale

/** DefaultDataSource otherwise opens UDP/RTMP before consulting its HTTP delegate. */
internal fun requireSupportedMediaScheme(scheme: String?) {
    if (scheme?.lowercase(Locale.ROOT) !in setOf(null, "", "http", "https", "file", "content",
            "asset", "data", "rawresource", "android.resource")) {
        throw IOException("This media protocol cannot use Videre's protected network transport.")
    }
}
