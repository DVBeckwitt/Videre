package com.github.dvbeckwitt.videre.proxy

import okhttp3.Interceptor
import okhttp3.Request
import okhttp3.Response
import org.json.JSONObject

internal data class GatewayRequestScope(val context: GatewayContext)
internal data class NerdVpnRequestRevision(val revision: Long?, val key: String?, val intent: Long?) {
    override fun toString() = "NerdVpnRequestRevision(revision=$revision)"
}
internal data class NerdVpnExpectedIntent(val intent: Long)

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
        val explicitKey = request.header(NERDVPN_KEY_HEADER)
        val access = NerdVpnAccess.resolve(context, request.url, explicitKey)
        val expectedIntent = request.tag(NerdVpnExpectedIntent::class.java)?.intent
        if (expectedIntent != null && expectedIntent != access.intent) throw NerdVpnAccessRequired("superseded")
        if (access.error != null && !(access.revision == 0L && access.error in setOf("missing", "signInRequired") &&
                explicitKey != null && validNerdVpnKey(explicitKey))) throw NerdVpnAccessRequired(access.error)
        val outgoing = request.newBuilder().apply {
            if (session.enabled) {
                val cookie = mergeGatewayCookies(session.cookies, request.header("Cookie"))
                if (cookie == null) removeHeader("Cookie") else header("Cookie", cookie)
            }
            access.apiKey?.let { header(NERDVPN_KEY_HEADER, it) }
            if (isNerdVpnOrigin(context.origin)) tag(NerdVpnRequestRevision::class.java,
                NerdVpnRequestRevision(access.revision, access.apiKey ?: explicitKey, access.intent))
        }.build()
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

/** An application interceptor may replay a GET once. Network interceptors still
 * resolve credentials for each redirected URI and every media segment. */
internal class NerdVpnRecoveryInterceptor : Interceptor {
    override fun intercept(chain: Interceptor.Chain): Response {
        val request = chain.request()
        val context = request.tag(GatewayRequestScope::class.java)?.context
        if (context == null || !isNerdVpnOrigin(context.origin) || !context.allows(request.url) ||
            isNerdVpnBootstrap(request.url)) return chain.proceed(request)
        var response = chain.proceed(request)
        val error = errorCode(response) ?: return response
        val recovered = recover(context, response, error)
        if (error in setOf("access_denied", "rate_limited", "unavailable")) {
            response.close()
            throw NerdVpnAccessRequired(recovered["state"] as? String ?: "unavailable")
        }
        if (error !in setOf("credentials_required", "invalid_credentials") ||
            request.method !in setOf("GET", "HEAD") || recovered["retryAllowed"] != true) return response
        response.close()
        val expectedIntent = recovered["apiKeyIntent"] as? Long
            ?: throw NerdVpnAccessRequired("superseded")
        response = chain.proceed(request.newBuilder()
            .tag(NerdVpnExpectedIntent::class.java, NerdVpnExpectedIntent(expectedIntent)).build())
        val repeated = errorCode(response)
        if (repeated != null) {
            val state = recover(context, response, repeated, retry = false)
            response.close()
            throw NerdVpnAccessRequired(state["state"] as? String ?: "signInRequired")
        }
        return response
    }

    private fun recover(context: GatewayContext, response: Response, error: String, retry: Boolean = true): Map<String, Any> {
        val attempt = response.request.tag(NerdVpnRequestRevision::class.java)
        return try {
            NerdVpnAccess.recover(context, error, response.code, response.header("Retry-After")?.toLongOrNull(),
                attempt?.key, attempt?.revision, retry, attempt?.intent)
        } catch (failure: Exception) {
            response.close()
            throw java.io.IOException("NerdVPN API access recovery failed.")
        }
    }

    private fun errorCode(response: Response): String? {
        val context = response.request.tag(GatewayRequestScope::class.java)?.context ?: return null
        if (!context.allows(response.request.url) || response.code !in setOf(401, 403, 429, 503)) return null
        val type = response.header("Content-Type")?.substringBefore(';')?.trim().orEmpty()
        if (type != "application/json" && !type.endsWith("+json")) return null
        return runCatching {
            val body = response.peekBody(8193)
            if (body.contentLength() > 8192) null else JSONObject(body.string()).optString("error").takeIf {
                it in setOf("credentials_required", "invalid_credentials", "access_denied", "rate_limited", "unavailable")
            }
        }.getOrNull()
    }
}
