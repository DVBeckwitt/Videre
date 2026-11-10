package com.github.dvbeckwitt.videre.proxy

import java.io.ByteArrayOutputStream
import java.io.IOException
import java.util.concurrent.TimeUnit
import okhttp3.Call
import okhttp3.HttpUrl
import okhttp3.Request
import okhttp3.Response

/** Read server-rendered markup without executing page scripts or following redirects.
 * The browser owner supplies cookies only after checking the exact current origin. */
object BrowserPageReader {
    const val MAX_HTML_BYTES = 2 * 1024 * 1024

    fun newCall(url: HttpUrl, cookies: String?, userAgent: String?): Call {
        val request = Request.Builder().url(url).apply {
            if (!cookies.isNullOrBlank()) header("Cookie", cookies)
            if (!userAgent.isNullOrBlank()) header("User-Agent", userAgent)
            header("Accept", "text/html,application/xhtml+xml")
        }.build()
        return ProxyDataSource.newApiCall(request, ApiRedirectOptions(false, 0)).also {
            it.timeout().timeout(15, TimeUnit.SECONDS)
        }
    }

    fun readHtml(response: Response): String? {
        if (!response.isSuccessful) return null
        val body = response.body ?: return null
        val type = body.contentType() ?: return null
        if (!(type.type == "text" && type.subtype == "html") &&
            !(type.type == "application" && type.subtype == "xhtml+xml")) return null
        if (body.contentLength() > MAX_HTML_BYTES) throw IOException("The browser page is too large.")
        val bytes = ByteArrayOutputStream()
        val input = body.byteStream()
        val buffer = ByteArray(8192)
        while (true) {
            val count = input.read(buffer, 0, minOf(buffer.size, MAX_HTML_BYTES - bytes.size() + 1))
            if (count < 0) break
            if (count > MAX_HTML_BYTES - bytes.size()) throw IOException("The browser page is too large.")
            bytes.write(buffer, 0, count)
        }
        return bytes.toString(type.charset(Charsets.UTF_8)!!.name())
    }
}
