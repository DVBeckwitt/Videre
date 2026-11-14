package com.github.dvbeckwitt.videre.proxy

import okhttp3.HttpUrl.Companion.toHttpUrl
import okhttp3.Request
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Assert.assertSame
import org.junit.Assert.assertThrows
import org.junit.Test

class InstanceOriginTest {
    private val origin = "http://instance.example:8080"

    @Test
    fun `plain instance marker is removed and pins the initial origin`() {
        val request = Request.Builder().url("$origin/image")
            .header(INSTANCE_ORIGIN_HEADER, origin).header("Range", "bytes=0-99").build()
        val prepared = prepareSelectedOriginRequest(request)
        assertNull(prepared.header(INSTANCE_ORIGIN_HEADER))
        assertEquals(origin.toHttpUrl(), prepared.tag(SelectedOriginScope::class.java)?.origin)
        assertEquals("bytes=0-99", prepared.header("Range"))
    }

    @Test
    fun `URI host normalization keeps valid instance origins comparable`() {
        val value = "http://INSTANCE.example:80"
        val request = Request.Builder().url("$value/image").header(INSTANCE_ORIGIN_HEADER, value).build()
        val prepared = prepareSelectedOriginRequest(request)
        assertEquals(request.url.host, prepared.tag(SelectedOriginScope::class.java)?.origin?.host)
        assertNull(prepared.header(INSTANCE_ORIGIN_HEADER))
    }

    @Test
    fun `no-follow removes and validates marker without changing redirect admission`() {
        val request = Request.Builder().url("$origin/image")
            .header(INSTANCE_ORIGIN_HEADER, origin).build()
        val prepared = prepareSelectedOriginRequest(request, followRedirects = false)
        assertNull(prepared.header(INSTANCE_ORIGIN_HEADER))
        assertNull(prepared.tag(SelectedOriginScope::class.java))
        assertThrows(SelectedOriginBlocked::class.java) {
            prepareSelectedOriginRequest(request.newBuilder().url("http://other.example/image").build(), false)
        }
    }

    @Test
    fun `invalid conflicting and repeated origin markers fail closed`() {
        for (value in listOf("http://other.example", "https://instance.example:8080", "$origin/path",
            "$origin/", "$origin?query=1", "$origin#fragment", "not an origin")) {
            val request = Request.Builder().url("$origin/image").header(INSTANCE_ORIGIN_HEADER, value).build()
            assertThrows(SelectedOriginBlocked::class.java) { prepareSelectedOriginRequest(request) }
        }
        val duplicate = Request.Builder().url("$origin/image")
            .addHeader(INSTANCE_ORIGIN_HEADER, origin).addHeader(INSTANCE_ORIGIN_HEADER, origin).build()
        assertThrows(SelectedOriginBlocked::class.java) { prepareSelectedOriginRequest(duplicate) }
    }

    @Test
    fun `marker cannot replace an existing media origin`() {
        val request = Request.Builder().url("$origin/image").header(INSTANCE_ORIGIN_HEADER, origin)
            .tag(SelectedOriginScope::class.java, SelectedOriginScope("http://selected.example".toHttpUrl())).build()
        assertThrows(SelectedOriginBlocked::class.java) { prepareSelectedOriginRequest(request) }
    }

    @Test
    fun `unmarked requests and matching existing anchors retain their policy`() {
        val scope = SelectedOriginScope(origin.toHttpUrl())
        val unmarked = Request.Builder().url("$origin/image").tag(SelectedOriginScope::class.java, scope).build()
        assertSame(unmarked, prepareSelectedOriginRequest(unmarked))
        val marked = unmarked.newBuilder().header(INSTANCE_ORIGIN_HEADER.lowercase(), origin).build()
        assertSame(scope, prepareSelectedOriginRequest(marked, false).tag(SelectedOriginScope::class.java))
        assertNull(prepareSelectedOriginRequest(marked).header(INSTANCE_ORIGIN_HEADER))
    }

    @Test
    fun `API request options cannot replace an existing source anchor`() {
        val scope = SelectedOriginScope("http://selected.example".toHttpUrl())
        val request = Request.Builder().url("$origin/image").tag(SelectedOriginScope::class.java, scope).build()
        val factory = PolicyCallFactory()
        try {
            factory.configure(ProxyPolicy())
            val call = factory.newApiCall(request, ApiRedirectOptions(sameOriginOnly = true))
            assertSame(scope, call.request().tag(SelectedOriginScope::class.java))
        } finally {
            factory.block()
        }
    }
}
