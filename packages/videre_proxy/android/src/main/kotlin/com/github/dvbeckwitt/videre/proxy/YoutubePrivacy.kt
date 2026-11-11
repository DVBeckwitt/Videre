package com.github.dvbeckwitt.videre.proxy

import java.io.IOException
import java.util.Locale
import okhttp3.HttpUrl
import okhttp3.Interceptor
import okhttp3.Response

/** Match destination host boundaries, never signed query parameters. */
internal fun isOfficialYoutubeHost(input: String): Boolean {
    val host = input.lowercase(Locale.ROOT).trimEnd('.')
    return listOf(
        "youtube.com", "youtu.be", "yt.be", "youtube-nocookie.com",
        "youtubekids.com", "youtubeeducation.com", "youtube",
        // Shared API batch endpoints and service aliases can also dispatch YouTube
        // requests. Path filtering cannot establish the privacy boundary here.
        "googleapis.com",
        "googlevideo.com", "ytimg.com", "ggpht.com", "googleusercontent.com", "gstatic.com",
    ).any { host == it || host.endsWith(".$it") }
}

internal fun isOfficialYoutubeUrl(url: HttpUrl): Boolean = isOfficialYoutubeHost(url.host)

internal class YoutubeConnectionBlocked : IOException(
    "Direct YouTube connections are disabled. Use the Invidious proxy.",
)

/** Application interceptor: each source, manifest child and API call is checked
 * before route lookup, DNS or connection acquisition. */
internal class YoutubeRequestGuard : Interceptor {
    override fun intercept(chain: Interceptor.Chain): Response {
        if (isOfficialYoutubeUrl(chain.request().url)) throw YoutubeConnectionBlocked()
        return chain.proceed(chain.request())
    }
}

/** OkHttp handles redirects internally, without re-running application
 * interceptors. Inspect Location before returning it to that redirect loop so
 * it cannot resolve or connect to an official host, even through SOCKS. */
internal class YoutubeRedirectGuard : Interceptor {
    override fun intercept(chain: Interceptor.Chain): Response {
        if (isOfficialYoutubeUrl(chain.request().url)) throw YoutubeConnectionBlocked()
        val response = chain.proceed(chain.request())
        val target = response.header("Location")?.let(response.request.url::resolve)
        if (response.isRedirect && target != null && isOfficialYoutubeUrl(target)) {
            response.close()
            throw YoutubeConnectionBlocked()
        }
        return response
    }
}
