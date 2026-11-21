package com.github.dvbeckwitt.videre.proxy

import androidx.media3.datasource.HttpDataSource
import java.io.InterruptedIOException
import java.nio.channels.ClosedChannelException
import java.security.GeneralSecurityException
import java.util.Collections
import java.util.IdentityHashMap
import java.util.concurrent.CancellationException
import javax.net.ssl.SSLException

/** Safe to send to the player: the rejected destination and its headers stay native. */
object MediaOriginFailure {
    @JvmStatic
    fun isBlocked(error: Throwable): Boolean {
        val seen = Collections.newSetFromMap(IdentityHashMap<Throwable, Boolean>())
        var cause: Throwable? = error
        var blocked = false
        while (cause != null && seen.add(cause)) {
            when (cause) {
                is SelectedOriginBlocked -> {
                    if (!cause.mediaDestination) return false
                    blocked = true
                }
                is HttpDataSource.InvalidResponseCodeException, is GatewayAuthenticationRequired,
                is GatewaySessionUnavailable, is NerdVpnAccessRequired, is YoutubeConnectionBlocked,
                is PodcastConnectionBlocked, is SSLException, is GeneralSecurityException,
                is InterruptedIOException, is InterruptedException, is ClosedChannelException,
                is CancellationException, is LocalDownloadUnavailable -> return false
            }
            cause = cause.cause
        }
        return blocked
    }
}
