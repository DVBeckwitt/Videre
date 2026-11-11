package ir.r3r.river_player

import android.net.Uri
import androidx.media3.common.C
import androidx.media3.datasource.DataSpec
import androidx.media3.datasource.HttpDataSource.InvalidResponseCodeException
import androidx.media3.exoplayer.upstream.DefaultLoadErrorHandlingPolicy
import androidx.media3.exoplayer.upstream.LoadErrorHandlingPolicy.LoadErrorInfo

/** Give a failing Invidious DASH range one retry before Videre tries the next source. */
internal class DashStartupLoadErrorPolicy(private val manifest: Uri) : DefaultLoadErrorHandlingPolicy() {
    @Volatile
    private var starting = true

    fun finishStartup() {
        starting = false
    }

    override fun getRetryDelayMsFor(loadErrorInfo: LoadErrorInfo): Long {
        if (!isStartupRangeFailure(loadErrorInfo)) return super.getRetryDelayMsFor(loadErrorInfo)
        return if (loadErrorInfo.errorCount == 1) 0L else C.TIME_UNSET
    }

    private fun isStartupRangeFailure(info: LoadErrorInfo): Boolean {
        if (!starting || (info.mediaLoadData.dataType != C.DATA_TYPE_MEDIA &&
                info.mediaLoadData.dataType != C.DATA_TYPE_MEDIA_INITIALIZATION)) return false
        val error = info.exception as? InvalidResponseCodeException ?: return false
        if (error.responseCode != 500 || error.headerFields.keys.any {
                it.equals("Retry-After", ignoreCase = true)
            }) return false

        val request = error.dataSpec
        val uri = request.uri
        return request.httpMethod == DataSpec.HTTP_METHOD_GET &&
            (request.position > 0 || request.length != C.LENGTH_UNSET.toLong() ||
                request.httpRequestHeaders.keys.any { it.equals("Range", ignoreCase = true) }) &&
            uri.pathSegments.contains("videoplayback") &&
            uri.scheme.equals(manifest.scheme, ignoreCase = true) &&
            uri.host.equals(manifest.host, ignoreCase = true) &&
            effectivePort(uri) == effectivePort(manifest)
    }

    private fun effectivePort(uri: Uri): Int =
        if (uri.port != -1) uri.port else if (uri.scheme.equals("https", ignoreCase = true)) 443 else 80
}
