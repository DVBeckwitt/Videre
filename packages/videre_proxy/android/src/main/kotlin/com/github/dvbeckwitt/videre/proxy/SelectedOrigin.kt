package com.github.dvbeckwitt.videre.proxy

import java.io.IOException
import okhttp3.HttpUrl
import okhttp3.HttpUrl.Companion.toHttpUrlOrNull
import okhttp3.Interceptor
import okhttp3.Request
import okhttp3.Response

/** Selected-instance requests keep their origin through redirects and children. */
internal data class SelectedOriginScope(val origin: HttpUrl, val media: Boolean = false, val companions: MediaCompanions? = null)

internal const val INSTANCE_ORIGIN_HEADER = "X-Videre-Instance-Origin"

internal class SelectedOriginBlocked(val mediaDestination: Boolean = false) : IOException(
    "Content requests must stay on the selected Invidious instance.",
)

internal fun requireSelectedOrigin(origin: HttpUrl, target: HttpUrl, media: Boolean) {
    if (!sameOrigin(origin, target)) {
        throw SelectedOriginBlocked(mediaDestination = media && target.username.isEmpty() &&
            target.password.isEmpty() && !isOfficialYoutubeUrl(target))
    }
}

private fun requireSelectedOrigin(request: Request, target: HttpUrl) {
    val scope = request.tag(SelectedOriginScope::class.java) ?: return
    if (scope.companions == null) {
        requireSelectedOrigin(scope.origin, target, scope.media)
    } else {
        scope.companions.requireDestination(target)
        if (!sameOrigin(scope.origin, target) && (request.method !in setOf("GET", "HEAD") || request.body != null)) {
            throw SelectedOriginBlocked()
        }
    }
}

/** Plain HTTP instance assets carry routing context, never a wire header. */
internal fun prepareSelectedOriginRequest(request: Request, followRedirects: Boolean = true): Request {
    val values = request.headers.values(INSTANCE_ORIGIN_HEADER)
    if (values.isEmpty()) return request
    val value = values.singleOrNull() ?: throw SelectedOriginBlocked()
    val origin = value.toHttpUrlOrNull() ?: throw SelectedOriginBlocked()
    val prefix = "${origin.scheme}://"
    val authority = value.removePrefix(prefix)
    if (!value.startsWith(prefix) || authority.isEmpty() ||
        authority.any { it in "/\\?#" || it.isWhitespace() } ||
        origin.username.isNotEmpty() || origin.password.isNotEmpty()) {
        throw SelectedOriginBlocked()
    }
    // A mismatched marker is an invalid routing context. A valid marker can
    // also accompany an independently requested child of an anchored source.
    val scope = request.tag(SelectedOriginScope::class.java)
    if (scope != null && !sameOrigin(scope.origin, origin)) throw SelectedOriginBlocked()
    if (scope == null) requireSelectedOrigin(origin, request.url, media = false)
    else requireSelectedOrigin(request, request.url)
    return request.newBuilder().removeHeader(INSTANCE_ORIGIN_HEADER).apply {
        if (followRedirects && request.tag(SelectedOriginScope::class.java) == null) {
            tag(SelectedOriginScope::class.java, SelectedOriginScope(origin))
        }
    }.build()
}

/** Independent manifest children must be checked before routing or DNS. */
internal class SelectedOriginRequestGuard : Interceptor {
    override fun intercept(chain: Interceptor.Chain): Response {
        requireSelectedOrigin(chain.request(), chain.request().url)
        return chain.proceed(chain.request())
    }
}

/** OkHttp does not rerun application interceptors for redirects. */
internal class SelectedOriginRedirectGuard : Interceptor {
    override fun intercept(chain: Interceptor.Chain): Response {
        val request = chain.request()
        requireSelectedOrigin(request, request.url)
        val response = chain.proceed(request)
        val target = response.header("Location")?.let(response.request.url::resolve)
        if (response.isRedirect && target != null) {
            try {
                requireSelectedOrigin(request, target)
            } catch (error: IOException) {
                response.close()
                throw error
            }
        }
        return response
    }
}
