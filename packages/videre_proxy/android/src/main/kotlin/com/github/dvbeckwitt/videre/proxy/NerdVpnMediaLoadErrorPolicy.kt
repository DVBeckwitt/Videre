package com.github.dvbeckwitt.videre.proxy

import androidx.media3.common.C
import androidx.media3.datasource.HttpDataSource.InvalidResponseCodeException
import androidx.media3.exoplayer.upstream.DefaultLoadErrorHandlingPolicy
import androidx.media3.exoplayer.upstream.LoadErrorHandlingPolicy.FallbackOptions
import androidx.media3.exoplayer.upstream.LoadErrorHandlingPolicy.FallbackSelection
import androidx.media3.exoplayer.upstream.LoadErrorHandlingPolicy.LoadErrorInfo
import okhttp3.HttpUrl.Companion.toHttpUrlOrNull

/** A NerdVPN 429 ends the current media load. A new play starts a fresh load. */
open class NerdVpnMediaLoadErrorPolicy : DefaultLoadErrorHandlingPolicy() {
    override fun getRetryDelayMsFor(loadErrorInfo: LoadErrorInfo): Long =
        if (isRateLimited(loadErrorInfo.exception)) C.TIME_UNSET else super.getRetryDelayMsFor(loadErrorInfo)

    override fun getFallbackSelectionFor(fallbackOptions: FallbackOptions, loadErrorInfo: LoadErrorInfo): FallbackSelection? =
        if (isRateLimited(loadErrorInfo.exception)) null else super.getFallbackSelectionFor(fallbackOptions, loadErrorInfo)

    companion object {
        fun isRateLimited(error: Throwable): Boolean =
            generateSequence(error) { it.cause }.take(16).any { cause ->
                when (cause) {
                    is NerdVpnAccessRequired -> cause.state == "rateLimited"
                    is InvalidResponseCodeException -> cause.responseCode == 429 &&
                        cause.dataSpec.uri.toString().toHttpUrlOrNull()?.let(::isNerdVpnOrigin) == true
                    else -> false
                }
            }
    }
}
