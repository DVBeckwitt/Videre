package com.github.dvbeckwitt.videre.proxy

import java.io.IOException
import okhttp3.HttpUrl
import okhttp3.HttpUrl.Companion.toHttpUrlOrNull
import okhttp3.Interceptor
import okhttp3.Request
import okhttp3.Response

/** Selected-instance requests keep their origin through redirects and children. */
internal data class SelectedOriginScope(val origin: HttpUrl)

internal const val INSTANCE_ORIGIN_HEADER = "X-Videre-Instance-Origin"

internal class SelectedOriginBlocked : IOException(
    "Content requests must stay on the selected Invidious instance.",
)

private fun requireSelectedOrigin(request: Request, target: HttpUrl) {
    val origin = request.tag(SelectedOriginScope::class.java)?.origin ?: return
    if (target.scheme != origin.scheme || target.host != origin.host || target.port != origin.port) {
        throw SelectedOriginBlocked()
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
        origin.username.isNotEmpty() || origin.password.isNotEmpty() ||
        request.url.scheme != origin.scheme || request.url.host != origin.host || request.url.port != origin.port) {
        throw SelectedOriginBlocked()
    }
    // An explicit media anchor cannot be replaced by a later child request.
    requireSelectedOrigin(request, origin)
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
            } catch (error: SelectedOriginBlocked) {
                response.close()
                throw error
            }
        }
        return response
    }
}
