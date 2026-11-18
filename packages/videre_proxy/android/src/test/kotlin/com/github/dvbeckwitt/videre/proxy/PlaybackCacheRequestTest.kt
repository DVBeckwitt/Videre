package com.github.dvbeckwitt.videre.proxy

import androidx.media3.common.C
import org.junit.Assert.assertEquals
import org.junit.Test

class PlaybackCacheRequestTest {
    @Test fun `typed media and initialization chunks are cacheable`() {
        for (type in listOf(C.DATA_TYPE_MEDIA, C.DATA_TYPE_MEDIA_INITIALIZATION)) {
            assertEquals(PlaybackCacheRequest.ADAPTIVE_MEDIA, PlaybackMediaCache.requestForMedia3DataType(type))
        }
    }

    @Test fun `playlists encryption keys live and unknown request types bypass caching`() {
        for (type in listOf(C.DATA_TYPE_UNKNOWN, C.DATA_TYPE_DRM, C.DATA_TYPE_MANIFEST,
            C.DATA_TYPE_TIME_SYNCHRONIZATION, C.DATA_TYPE_AD, C.DATA_TYPE_MEDIA_PROGRESSIVE_LIVE,
            C.DATA_TYPE_CUSTOM_BASE, -1)) {
            assertEquals(PlaybackCacheRequest.BYPASS, PlaybackMediaCache.requestForMedia3DataType(type))
        }
    }

    @Test fun `unknown adaptive children require positive VOD classification`() {
        assertEquals(PlaybackCacheRequest.ADAPTIVE_MEDIA,
            PlaybackMediaCache.admittedRequest(PlaybackCacheRequest.ADAPTIVE_MEDIA, true))
        for (classification in listOf(null, false, "true", 1)) {
            assertEquals(PlaybackCacheRequest.ADAPTIVE_UNTYPED,
                PlaybackMediaCache.admittedRequest(PlaybackCacheRequest.ADAPTIVE_MEDIA, classification))
        }
        assertEquals(PlaybackCacheRequest.ADAPTIVE_UNTYPED,
            PlaybackMediaCache.admittedRequest(PlaybackCacheRequest.ADAPTIVE_MEDIA,
                emptyMap<String, Any?>()["adaptiveVod"]))
    }

    @Test fun `VOD classification does not promote bypass or other request roles`() {
        for (request in listOf(PlaybackCacheRequest.BYPASS, PlaybackCacheRequest.PROGRESSIVE,
            PlaybackCacheRequest.ADAPTIVE_UNTYPED)) {
            for (classification in listOf(null, false, true)) {
                assertEquals(request, PlaybackMediaCache.admittedRequest(request, classification))
            }
        }
    }
}
