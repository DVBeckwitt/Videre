package com.github.dvbeckwitt.videre.proxy

import java.io.ByteArrayOutputStream
import java.io.IOException
import java.io.InputStream
import java.util.Locale
import okhttp3.HttpUrl.Companion.toHttpUrlOrNull
import okhttp3.Request
import okhttp3.RequestBody.Companion.toRequestBody
import okhttp3.Response

internal const val MAX_API_BODY_BYTES = 4 * 1024 * 1024

internal class ApiBodyTooLarge : IOException("Network response exceeds 4 MiB.")

internal data class ApiRedirectOptions(val followRedirects: Boolean = true, val maxRedirects: Int = 5) {
    companion object {
        fun fromMap(values: Map<*, *>): ApiRedirectOptions {
            val follow = values["followRedirects"] ?: true
            val max = values["maxRedirects"] ?: 5
            require(follow is Boolean && max is Number &&
                max.toDouble() == max.toInt().toDouble() && max.toInt() in 0..20) {
                "Invalid HTTP redirect options."
            }
            return ApiRedirectOptions(follow, max.toInt())
        }
    }
}

/** The worker bridge is deliberately bounded and is not a media transport. */
internal fun buildApiRequest(arguments: Map<*, *>): Request {
    val method = arguments["method"] as? String
        ?: throw IllegalArgumentException("An HTTP method is required.")
    require(method in setOf("GET", "HEAD", "POST", "PUT", "PATCH", "DELETE", "OPTIONS")) {
        "Unsupported HTTP method."
    }
    val inputUrl = arguments["url"] as? String
        ?: throw IllegalArgumentException("An HTTP URL is required.")
    val url = inputUrl.toHttpUrlOrNull()
        ?: throw IllegalArgumentException("An HTTP or HTTPS URL is required.")
    val bytes = when (val body = arguments["body"]) {
        null -> ByteArray(0)
        is ByteArray -> body
        else -> throw IllegalArgumentException("HTTP body must contain bytes.")
    }
    require(bytes.size <= MAX_API_BODY_BYTES) { "HTTP request exceeds 4 MiB." }
    require(method !in setOf("GET", "HEAD") || bytes.isEmpty()) {
        "GET and HEAD requests cannot contain a body."
    }
    val builder = Request.Builder().url(url)
    val headers = when (val value = arguments["headers"]) {
        null -> emptyMap<Any, Any>()
        is Map<*, *> -> value
        else -> throw IllegalArgumentException("HTTP headers must contain strings.")
    }
    headers.forEach { (name, value) ->
        require(name is String && value is String) { "HTTP headers must contain strings." }
        builder.header(name, value)
    }
    val body = if (bytes.isNotEmpty() || method in setOf("POST", "PUT", "PATCH")) bytes.toRequestBody() else null
    return builder.method(method, body).build()
}

internal fun readLimitedApiBody(input: InputStream, contentLength: Long): ByteArray {
    if (contentLength > MAX_API_BODY_BYTES) throw ApiBodyTooLarge()
    val output = ByteArrayOutputStream()
    val buffer = ByteArray(8192)
    while (true) {
        val count = input.read(buffer)
        if (count == -1) break
        if (count > MAX_API_BODY_BYTES - output.size()) throw ApiBodyTooLarge()
        output.write(buffer, 0, count)
    }
    return output.toByteArray()
}

internal fun readApiResponse(response: Response): Map<String, Any> {
    val body = response.body
    val bytes = if (body == null) ByteArray(0)
        else readLimitedApiBody(body.byteStream(), body.contentLength())
    return mapOf(
        "statusCode" to response.code,
        "headers" to response.headers.names().associate { name ->
            name.lowercase(Locale.ROOT) to response.headers.values(name).joinToString(", ")
        },
        "body" to bytes,
    )
}
