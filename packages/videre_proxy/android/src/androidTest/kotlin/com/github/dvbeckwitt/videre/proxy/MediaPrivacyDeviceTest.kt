package com.github.dvbeckwitt.videre.proxy

import android.net.Uri
import androidx.media3.datasource.DataSource
import androidx.media3.datasource.DataSpec
import androidx.media3.exoplayer.hls.playlist.HlsMediaPlaylist
import androidx.media3.exoplayer.hls.playlist.HlsPlaylistParser
import androidx.test.ext.junit.runners.AndroidJUnit4
import androidx.test.platform.app.InstrumentationRegistry
import java.io.ByteArrayOutputStream
import java.io.File
import java.io.IOException
import java.net.Proxy
import java.net.ProxySelector
import java.net.SocketAddress
import java.net.URI
import org.junit.Assert.assertArrayEquals
import org.junit.Assert.assertEquals
import org.junit.Assert.assertThrows
import org.junit.Assert.assertTrue
import org.junit.Test
import org.junit.runner.RunWith

/** The native factory shared by audio and video, including local adaptive media. */
@RunWith(AndroidJUnit4::class)
class MediaPrivacyDeviceTest {
    private val context get() = InstrumentationRegistry.getInstrumentation().targetContext

    @Test fun localManifestAndDataSourcesCannotOpenAnOfficialNetworkChild() {
        val previous = ProxySelector.getDefault()
        var routeLookups = 0
        ProxySelector.setDefault(object : ProxySelector() {
            override fun select(uri: URI): List<Proxy> {
                routeLookups++
                throw IOException("The native privacy fixture permits no network connections.")
            }
            override fun connectFailed(uri: URI?, address: SocketAddress?, error: IOException?) = Unit
        })
        ProxyDataSource.initialize(context)
        val saved = ProxyDataSource.configuration()
        val file = File.createTempFile("videre-local-manifest-", ".m3u8", context.cacheDir)
        try {
            // Force a fresh client to capture the fixture-only proxy selector.
            ProxyDataSource.configure(ProxyPolicy(true, "127.0.0.1", 9).toMap())
            ProxyDataSource.configure(ProxyPolicy().toMap())
            val manifest = "#EXTM3U\n#EXT-X-TARGETDURATION:10\n#EXTINF:10,\n" +
                "https://rr1.googlevideo.com/fixture.ts\n#EXT-X-ENDLIST\n"
            file.writeText(manifest)
            val uri = Uri.fromFile(file)
            val factory = ProxyDataSource.withLocalSources(context,
                ProxyDataSource.factory("Videre fixture", null, uri.toString()))
            val local = read(factory, uri)
            assertArrayEquals(manifest.toByteArray(), local)
            val playlist = HlsPlaylistParser().parse(uri, local.inputStream()) as HlsMediaPlaylist
            val failure = assertThrows(IOException::class.java) {
                read(factory, Uri.parse(playlist.segments.single().url))
            }
            assertTrue(generateSequence<Throwable>(failure) { it.cause }.any { it is YoutubeConnectionBlocked })
            assertArrayEquals("fixture".toByteArray(), read(factory, Uri.parse("data:text/plain,fixture")))
            for (scheme in listOf("udp", "rtmp", "rtsp")) {
                val error = assertThrows(IOException::class.java) {
                    read(factory, Uri.parse("$scheme://music.youtube.com:443/fixture"))
                }
                assertTrue(error.message.orEmpty().contains("protected network transport"))
            }
            assertEquals("A blocked child must not reach DNS or route selection", 0, routeLookups)
        } finally {
            file.delete()
            ProxySelector.setDefault(previous)
            ProxyDataSource.configure(ProxyPolicy(true, "127.0.0.1", 9).toMap())
            ProxyDataSource.configure(saved)
        }
    }

    private fun read(factory: DataSource.Factory, uri: Uri): ByteArray {
        val source = factory.createDataSource()
        try {
            source.open(DataSpec(uri))
            val result = ByteArrayOutputStream()
            val buffer = ByteArray(4096)
            while (true) {
                val count = source.read(buffer, 0, buffer.size)
                if (count < 0) return result.toByteArray()
                result.write(buffer, 0, count)
            }
        } finally {
            source.close()
        }
    }
}
