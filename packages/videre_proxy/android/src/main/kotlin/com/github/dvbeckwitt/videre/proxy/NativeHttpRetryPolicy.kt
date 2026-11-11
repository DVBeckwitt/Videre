package com.github.dvbeckwitt.videre.proxy

/** Native player errors expose admission, not a server-cooldown scheduler. */
object NativeHttpRetryPolicy {
    @JvmStatic
    fun allowsTransientResponse(status: Int, headers: Map<String?, List<String>>): Boolean =
        status in setOf(502, 503, 504) &&
            headers.keys.none { it.equals("Retry-After", ignoreCase = true) }
}
