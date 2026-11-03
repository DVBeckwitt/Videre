package com.github.dvbeckwitt.videre.proxy

import okhttp3.Interceptor
import okhttp3.Request
import okhttp3.Response

internal data class GatewayRequestScope(val context: GatewayContext)

internal fun prepareGatewayRequest(request: Request, sourceContext: GatewayContext? = null): Request {
    val marker = request.header(GATEWAY_CONTEXT_HEADER)
    val context = sourceContext ?: request.tag(GatewayRequestScope::class.java)?.context ?: marker?.let(GatewayContext::parse)
    return request.newBuilder().removeHeader(GATEWAY_CONTEXT_HEADER).apply {
        if (context != null) tag(GatewayRequestScope::class.java, GatewayRequestScope(context))
    }.build()
}

/** Runs once for every actual URI, including native manifest segments/redirects. */
internal class GatewayTransportInterceptor : Interceptor {
    override fun intercept(chain: Interceptor.Chain): Response {
        val request = prepareGatewayRequest(chain.request())
        val context = request.tag(GatewayRequestScope::class.java)?.context
        if (context == null || !context.allows(request.url)) return chain.proceed(request)
        val sessions = GatewayCookieAccessRegistry.provider ?: throw GatewaySessionUnavailable()
        val session = sessions.resolve(context, request.url)
        if (session.needsSignIn) throw GatewayAuthenticationRequired()
        val outgoing = if (session.enabled) request.newBuilder().apply {
            val cookie = mergeGatewayCookies(session.cookies, request.header("Cookie"))
            if (cookie == null) removeHeader("Cookie") else header("Cookie", cookie)
        }.build() else request
        val response = chain.proceed(outgoing)
        if (session.enabled) {
            try {
                val required = sessions.ingest(context, request.url, response.headers("Set-Cookie"),
                    response.code, response.header("Content-Type"), response.header("Location"), session.revision)
                if (required) throw GatewayAuthenticationRequired()
            } catch (error: Exception) {
                response.close()
                throw error
            }
        }
        return response
    }
}
