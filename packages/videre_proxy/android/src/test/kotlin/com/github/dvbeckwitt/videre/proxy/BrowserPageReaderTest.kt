package com.github.dvbeckwitt.videre.proxy

import java.io.IOException
import okhttp3.MediaType.Companion.toMediaType
import okhttp3.Protocol
import okhttp3.Request
import okhttp3.Response
import okhttp3.ResponseBody
import okhttp3.ResponseBody.Companion.toResponseBody
import okio.Buffer
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Assert.assertThrows
import org.junit.Test

class BrowserPageReaderTest {
    @Test fun `only successful HTML responses are returned without executing scripts`() {
        val html = "<div id=backend-selector><a href='/switchbackend?backend=fixture'>fixture</a></div>" +
            "<script>untrusted()</script>"
        response(html).use { assertEquals(html, BrowserPageReader.readHtml(it)) }
        response(html, status = 302).use { assertNull(BrowserPageReader.readHtml(it)) }
        response(html, status = 403).use { assertNull(BrowserPageReader.readHtml(it)) }
        response(html, contentType = "application/json").use { assertNull(BrowserPageReader.readHtml(it)) }
    }

    @Test fun `page reads refuse oversized responses`() {
        response("x".repeat(BrowserPageReader.MAX_HTML_BYTES + 1)).use {
            assertThrows(IOException::class.java) { BrowserPageReader.readHtml(it) }
        }
        val streamed = object : ResponseBody() {
            override fun contentType() = "text/html".toMediaType()
            override fun contentLength() = -1L
            override fun source() = Buffer().writeUtf8("x".repeat(BrowserPageReader.MAX_HTML_BYTES + 1))
        }
        response("").newBuilder().body(streamed).build().use {
            assertThrows(IOException::class.java) { BrowserPageReader.readHtml(it) }
        }
    }

    private fun response(body: String, status: Int = 200, contentType: String = "text/html; charset=utf-8") =
        Response.Builder().request(Request.Builder().url("https://instance.example/").build())
            .protocol(Protocol.HTTP_1_1).code(status).message("fixture")
            .body(body.toResponseBody(contentType.toMediaType())).build()
}
