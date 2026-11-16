package com.github.dvbeckwitt.videre.proxy

import java.io.IOException
import java.util.Locale
import okhttp3.HttpUrl
import okhttp3.Interceptor
import okhttp3.Request
import okhttp3.Response

/** Only an explicit podcast audio source installs this transport policy. */
internal object PodcastSourceScope

internal class PodcastConnectionBlocked : IOException(
    "Use a publisher podcast URL without Google, YouTube, or account credentials.",
)

internal fun requirePodcastUrl(url: HttpUrl) {
    val host = url.host.lowercase(Locale.ROOT).trimEnd('.')
    if (isOfficialYoutubeHost(host) || host == "feedburner.com" || host.endsWith(".feedburner.com") ||
        url.username.isNotEmpty() || url.password.isNotEmpty() || url.fragment != null ||
        url.toString().length > 4096) {
        throw PodcastConnectionBlocked()
    }
}

/** No inherited instance headers or gateway context may enter podcast traffic. */
internal fun preparePodcastRequest(request: Request): Request {
    requirePodcastUrl(request.url)
    return request.newBuilder()
        .tag(PodcastSourceScope::class.java, PodcastSourceScope)
        .tag(SelectedOriginScope::class.java, null)
        .tag(GatewayRequestScope::class.java, null)
        .apply {
            listOf("Authorization", "Proxy-Authorization", "Cookie", "Cookie2", "WWW-Authenticate",
                NERDVPN_KEY_HEADER, GATEWAY_CONTEXT_HEADER, INSTANCE_ORIGIN_HEADER).forEach { removeHeader(it) }
        }.build()
}

internal class PodcastRequestGuard : Interceptor {
    override fun intercept(chain: Interceptor.Chain): Response {
        val request = chain.request()
        if (request.tag(PodcastSourceScope::class.java) != null) requirePodcastUrl(request.url)
        return chain.proceed(request)
    }
}

/** Inspect every Location before OkHttp can route, resolve or connect to it. */
internal class PodcastRedirectGuard : Interceptor {
    override fun intercept(chain: Interceptor.Chain): Response {
        val request = chain.request()
        if (request.tag(PodcastSourceScope::class.java) == null) return chain.proceed(request)
        requirePodcastUrl(request.url)
        val response = chain.proceed(request)
        val target = response.header("Location")?.let(response.request.url::resolve)
        if (response.isRedirect && target != null) {
            try {
                requirePodcastUrl(target)
            } catch (error: PodcastConnectionBlocked) {
                response.close()
                throw error
            }
        }
        return response
    }
}
