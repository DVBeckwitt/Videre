package com.github.dvbeckwitt.videre.proxy

import androidx.media3.common.C
import androidx.media3.common.PlaybackException
import androidx.media3.datasource.DataSpec
import androidx.media3.datasource.HttpDataSource.HttpDataSourceException
import androidx.media3.datasource.HttpDataSource.InvalidResponseCodeException
import androidx.media3.exoplayer.upstream.DefaultLoadErrorHandlingPolicy
import androidx.media3.exoplayer.upstream.LoadErrorHandlingPolicy.FallbackOptions
import androidx.media3.exoplayer.upstream.LoadErrorHandlingPolicy.FallbackSelection
import androidx.media3.exoplayer.upstream.LoadErrorHandlingPolicy.LoadErrorInfo
import okhttp3.HttpUrl.Companion.toHttpUrlOrNull

/** A short NerdVPN byte range gets one retry. A 429 always ends the load. */
open class NerdVpnMediaLoadErrorPolicy : DefaultLoadErrorHandlingPolicy() {
    override fun getRetryDelayMsFor(loadErrorInfo: LoadErrorInfo): Long {
        if (isRateLimited(loadErrorInfo.exception)) return C.TIME_UNSET
        if (isShortMediaRange(loadErrorInfo)) return if (loadErrorInfo.errorCount == 1) 0L else C.TIME_UNSET
        return super.getRetryDelayMsFor(loadErrorInfo)
    }

    private fun isShortMediaRange(info: LoadErrorInfo): Boolean {
        val type = info.mediaLoadData.dataType
        if (type != C.DATA_TYPE_MEDIA && type != C.DATA_TYPE_MEDIA_INITIALIZATION) return false
        // OkHttpDataSource reports this plain open error when a 200 body ends
        // before the requested offset. HTTP refusals have a separate exception.
        val error = info.exception as? HttpDataSourceException ?: return false
        return error !is InvalidResponseCodeException && error.cause == null &&
            error.type == HttpDataSourceException.TYPE_OPEN &&
            error.reason == PlaybackException.ERROR_CODE_IO_READ_POSITION_OUT_OF_RANGE &&
            error.dataSpec.httpMethod == DataSpec.HTTP_METHOD_GET && error.dataSpec.position > 0 &&
            error.dataSpec.uri.toString().toHttpUrlOrNull()?.let(::isNerdVpnOrigin) == true
    }

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
