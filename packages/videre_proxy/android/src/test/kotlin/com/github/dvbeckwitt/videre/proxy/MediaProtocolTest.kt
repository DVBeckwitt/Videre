package com.github.dvbeckwitt.videre.proxy

import java.io.IOException
import org.junit.Assert.assertThrows
import org.junit.Test

class MediaProtocolTest {
    @Test fun `local resources and guarded HTTP preserve existing media protocols`() {
        listOf(null, "", "file", "content", "asset", "data", "rawresource", "android.resource",
            "http", "https", "HTTPS").forEach(::requireSupportedMediaScheme)
    }

    @Test fun `manifest children cannot select unguarded network transports`() {
        listOf("udp", "rtmp", "rtsp", "rtp", "srt", "ftp", "ws", "wss", "UDP").forEach { scheme ->
            assertThrows(IOException::class.java) { requireSupportedMediaScheme(scheme) }
        }
    }
}
