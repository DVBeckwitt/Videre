package com.github.dvbeckwitt.videre.proxy

import android.content.Context
import android.graphics.SurfaceTexture
import android.opengl.EGL14
import android.opengl.EGLConfig
import android.opengl.GLES11Ext
import android.opengl.GLES20
import android.os.Handler
import android.os.HandlerThread
import android.os.SystemClock
import android.view.Surface
import androidx.media3.common.MediaItem
import androidx.media3.common.PlaybackException
import androidx.media3.common.Player
import androidx.media3.datasource.DataSpec
import androidx.media3.exoplayer.ExoPlayer
import androidx.media3.exoplayer.source.DefaultMediaSourceFactory
import androidx.test.ext.junit.runners.AndroidJUnit4
import androidx.test.platform.app.InstrumentationRegistry
import java.io.DataInputStream
import java.io.ByteArrayOutputStream
import java.io.EOFException
import java.io.IOException
import java.net.InetAddress
import java.net.ServerSocket
import java.net.Socket
import java.net.UnknownHostException
import java.util.Collections
import java.util.Locale
import java.util.concurrent.ConcurrentLinkedQueue
import java.util.concurrent.CountDownLatch
import java.util.concurrent.Executors
import java.util.concurrent.TimeUnit
import java.util.concurrent.atomic.AtomicInteger
import java.util.concurrent.atomic.AtomicLong
import java.util.concurrent.atomic.AtomicReference
import org.junit.After
import org.junit.Assert.assertArrayEquals
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Assume.assumeTrue
import org.junit.Before
import org.junit.Test
import org.junit.runner.RunWith

/** Native decoding tests, separate from Videre's installed application/data. */
@RunWith(AndroidJUnit4::class)
class SocksPlaybackDeviceTest {
    private val instrumentation = InstrumentationRegistry.getInstrumentation()
    private val context: Context get() = instrumentation.targetContext
    private var savedPolicy: Map<String, Any>? = null

    @Before
    fun loadPolicy() {
        ProxyDataSource.initialize(context)
        savedPolicy = ProxyDataSource.configuration()
    }

    @After
    fun restorePolicy() {
        savedPolicy?.let(ProxyDataSource::configure)
    }

    @Test(timeout = 45000)
    fun videoAudioAndSeekUseSocksWithRemoteDestinationDns() {
        val bytes = instrumentation.context.assets.open("socks_fixture.mp4").use { it.readBytes() }
        FixtureSocks(bytes).use { proxy ->
            ProxyDataSource.configure(ProxyPolicy(true, "127.0.0.1", proxy.port).toMap())
            val source = "http://videre-playback.invalid:8123/fixture.mp4"
            PlayerProbe(source).use { probe ->
                probe.await("video frames and decoded audio") {
                    probe.videoFrames.get() >= 3 && probe.position() >= 700 && probe.audioBuffers() > 0
                }
                main { probe.player.pause() }
                val paused = probe.position()
                SystemClock.sleep(350)
                assertTrue("Paused playhead moved", probe.position() <= paused + 100)
                val previousFrames = probe.videoFrames.get()
                main {
                    probe.player.seekTo(4500)
                    probe.player.play()
                }
                // Normal playback from ~700 ms cannot reach 4500 ms in this
                // budget. Require both the seek event and a new decoded frame.
                probe.await("playback after seeking", timeoutMs = 2000) {
                    probe.seekPosition.get() >= 4450 && probe.videoPresentationUs.get() >= 4500000 &&
                        probe.position() >= 4700 && probe.videoFrames.get() > previousFrames + 1
                }
            }

            // A short fixture may already be fully buffered when seeking. Verify
            // byte-range reopening directly through the exact same data source.
            val dataSource = ProxyDataSource.factory("Videre device acceptance", null, source).createDataSource()
            try {
                dataSource.open(DataSpec.Builder().setUri(source).setPosition(128).setLength(64).build())
                val actual = ByteArray(64)
                var offset = 0
                while (offset < actual.size) {
                    val count = dataSource.read(actual, offset, actual.size - offset)
                    if (count < 0) throw EOFException("Incomplete ranged fixture")
                    offset += count
                }
                assertArrayEquals(bytes.copyOfRange(128, 192), actual)
            } finally {
                dataSource.close()
            }
            assertTrue("No SOCKS destination was observed", proxy.destinations.isNotEmpty())
            assertTrue("Origin hostname was not sent through SOCKS", proxy.destinations.all {
                it == ("videre-playback.invalid" to 8123)
            })
            assertTrue("No byte-range request reached the proxy", proxy.ranges.get() > 0)
            proxy.failure.get()?.let { throw AssertionError("SOCKS fixture failed", it) }
        }
    }

    @Test(timeout = 20000)
    fun stoppedProxyFailsWithoutResolvingTheOriginLocally() {
        val closedPort = ServerSocket(0, 1, InetAddress.getByName("127.0.0.1")).use { it.localPort }
        ProxyDataSource.configure(ProxyPolicy(true, "127.0.0.1", closedPort).toMap())
        val source = "http://videre-no-direct-fallback.invalid:8123/fixture.mp4"
        val dataSource = ProxyDataSource.factory("Videre device acceptance", null, source).createDataSource()
        val start = SystemClock.elapsedRealtime()
        val failure = try {
            dataSource.open(DataSpec.Builder().setUri(source).build())
            throw AssertionError("A stopped SOCKS proxy unexpectedly connected")
        } catch (error: IOException) {
            error
        } finally {
            dataSource.close()
        }
        assertFalse("Failure attempted origin DNS instead of failing at the proxy", generateSequence<Throwable>(failure) {
            it.cause
        }.any { it is UnknownHostException })
        assertTrue("A refused local proxy should fail promptly", SystemClock.elapsedRealtime() - start < 5000)
    }

    @Test(timeout = 30000)
    fun policyChangeAbortsActiveVideoAudioReadsAndRetainedSourcesUseTheNewProxy() {
        val video = instrumentation.context.assets.open("socks_fixture.mp4").use { it.readBytes() }
        val audio = instrumentation.context.assets.open("socks_audio.m4a").use { it.readBytes() }
        val original = mapOf(
            "/fixture.mp4" to FixtureResource(video, "video/mp4"),
            "/audio.m4a" to FixtureResource(audio, "audio/mp4"),
        )
        val latest = original.mapValues { (_, resource) ->
            resource.copy(bytes = resource.bytes + byteArrayOf(42))
        }
        FixtureSocks(original, holdBodies = true).use { first ->
            FixtureSocks(latest).use { second ->
                ProxyDataSource.configure(ProxyPolicy(true, "127.0.0.1", first.port).toMap())
                val root = "http://videre-playback.invalid:8123"
                val urls = listOf("$root/fixture.mp4", "$root/audio.m4a")
                val factory = ProxyDataSource.factory("Videre policy acceptance", null, urls[0])
                val sources = urls.map { factory.createDataSource() }
                val reads = Executors.newFixedThreadPool(2)
                val started = CountDownLatch(2)
                try {
                    sources.forEachIndexed { index, source ->
                        source.open(DataSpec.Builder().setUri(urls[index]).build())
                        val prefix = ByteArray(128)
                        var offset = 0
                        while (offset < prefix.size) {
                            val count = source.read(prefix, offset, prefix.size - offset)
                            check(count > 0) { "Fixture prefix ended early" }
                            offset += count
                        }
                    }
                    val pending = sources.map { source ->
                        reads.submit<IOException> {
                            started.countDown()
                            try {
                                source.read(ByteArray(1), 0, 1)
                                throw AssertionError("The old policy's held media read was not aborted")
                            } catch (error: IOException) {
                                error
                            }
                        }
                    }
                    assertTrue("Both media body reads must be pending", started.await(5, TimeUnit.SECONDS))
                    ProxyDataSource.configure(ProxyPolicy(true, "127.0.0.1", second.port).toMap())
                    pending.forEach { it.get(5, TimeUnit.SECONDS) }
                    first.awaitAbortedBodies(2)

                    // Reuse sources created before the change. Their next calls
                    // must select the new live policy, not a captured old client.
                    sources.forEachIndexed { index, source ->
                        source.close()
                        source.open(DataSpec.Builder().setUri(urls[index]).build())
                        val expected = if (index == 0) video + byteArrayOf(42) else audio + byteArrayOf(42)
                        assertArrayEquals(expected, readAll(source))
                    }
                    assertEquals("Old proxy received a request after the change", 2, first.requests.size)
                    assertEquals("Both retained sources must use the new proxy", 2, second.requests.size)
                } finally {
                    sources.forEach { it.close() }
                    reads.shutdownNow()
                }
            }
        }
    }

    @Test(timeout = 45000)
    fun dashPlaybackSeekAndExternalChildHeadersUseSocks() = adaptivePlayback("dash", "manifest.mpd")

    @Test(timeout = 45000)
    fun hlsPlaybackSeekAndExternalChildHeadersUseSocks() = adaptivePlayback("hls", "manifest.m3u8")

    private fun adaptivePlayback(format: String, manifest: String) {
        val resources = adaptiveAssets(format)
        FixtureSocks(resources).use { proxy ->
            ProxyDataSource.configure(ProxyPolicy(true, "127.0.0.1", proxy.port).toMap())
            val source = "http://videre-playback.invalid:8123/$format/$manifest"
            val credentials = mapOf("Authorization" to "Bearer fixture", "Cookie" to "sid=fixture", "X-Instance-Key" to "fixture")
            PlayerProbe(source, credentials).use { probe ->
                probe.await("$format video and audio decoding") {
                    probe.videoFrames.get() >= 3 && probe.position() >= 700 && probe.audioBuffers() > 0
                }
                main { probe.player.pause() }
                val previousFrames = probe.videoFrames.get()
                main {
                    probe.player.seekTo(4500)
                    probe.player.play()
                }
                probe.await("$format seek to 4.5 seconds", timeoutMs = 2000) {
                    probe.seekPosition.get() >= 4450 && probe.position() >= 4700 &&
                        probe.videoPresentationUs.get() >= 4500000 && probe.videoFrames.get() > previousFrames + 1
                }
            }
            val root = proxy.requests.filter { it.path == "/$format/$manifest" }
            assertTrue("The manifest did not receive its own scoped headers", root.isNotEmpty() && root.all {
                it.headers["x-instance-key"] == "fixture"
            })
            val children = proxy.requests.filter { it.destination.first == "videre-segments.invalid" }
            assertTrue("No external adaptive segments reached SOCKS", children.isNotEmpty())
            assertTrue("Instance credentials leaked to an external child", children.all {
                listOf("authorization", "cookie", "x-instance-key").none(it.headers::containsKey)
            })
            assertTrue("A segment hostname was not forwarded through SOCKS", proxy.destinations.all {
                it.first in setOf("videre-playback.invalid", "videre-segments.invalid") && it.second == 8123
            })
            proxy.failure.get()?.let { throw AssertionError("Adaptive SOCKS fixture failed", it) }
        }
    }

    private fun adaptiveAssets(format: String): Map<String, FixtureResource> {
        val assets = instrumentation.context.assets
        return checkNotNull(assets.list(format)).associate { name ->
            var bytes = assets.open("$format/$name").use { it.readBytes() }
            // Make children independent, cross-origin requests. A redirect-only
            // credential guard cannot pass these tests.
            if (name.endsWith(".mpd")) {
                val external = "http://videre-segments.invalid:8123/$format/"
                bytes = bytes.toString(Charsets.UTF_8)
                    .replace("initialization=\"", "initialization=\"$external")
                    .replace("media=\"", "media=\"$external")
                    .toByteArray(Charsets.UTF_8)
            } else if (name.endsWith(".m3u8")) {
                bytes = bytes.toString(Charsets.UTF_8).lineSequence().joinToString("\n") { line ->
                    if (line.isNotBlank() && !line.startsWith("#")) {
                        "http://videre-segments.invalid:8123/$format/$line"
                    } else line
                }.toByteArray(Charsets.UTF_8)
            }
            val mime = when {
                name.endsWith(".mpd") -> "application/dash+xml"
                name.endsWith(".m3u8") -> "application/vnd.apple.mpegurl"
                name.endsWith(".ts") -> "video/mp2t"
                else -> "video/iso.segment"
            }
            "/$format/$name" to FixtureResource(bytes, mime)
        }
    }

    private fun readAll(source: androidx.media3.datasource.DataSource): ByteArray {
        val bytes = ByteArrayOutputStream()
        val buffer = ByteArray(4096)
        while (true) {
            val count = source.read(buffer, 0, buffer.size)
            if (count < 0) return bytes.toByteArray()
            bytes.write(buffer, 0, count)
        }
    }

    /** Optional: explicit runner arguments make real Tor traffic intentional. */
    @Test(timeout = 100000)
    fun optionalRealOrbotHttpsPlayback() {
        val arguments = InstrumentationRegistry.getArguments()
        val source = arguments.getString("orbotMediaUrl")
        assumeTrue("Pass orbotMediaUrl to run real Orbot acceptance", source != null)
        require(source!!.startsWith("https://")) { "Orbot fixture must use HTTPS" }
        val port = arguments.getString("orbotPort")?.toInt() ?: 9050
        ProxyDataSource.configure(ProxyPolicy(true, "127.0.0.1", port).toMap())
        PlayerProbe(source).use { probe ->
            probe.await("real Orbot HTTPS playback", timeoutMs = 90000) {
                probe.videoFrames.get() >= 3 && probe.position() >= 700
            }
        }
    }

    private fun main(action: () -> Unit) = instrumentation.runOnMainSync(action)

    private inner class PlayerProbe(source: String, headers: Map<String, String>? = null) : AutoCloseable {
        val videoFrames = AtomicInteger()
        val videoPresentationUs = AtomicLong(-1)
        val seekPosition = AtomicLong(-1)
        private val error = AtomicReference<PlaybackException>()
        private val output = VideoOutput(videoFrames)
        lateinit var player: ExoPlayer

        init {
            main {
                val media = DefaultMediaSourceFactory(context).setDataSourceFactory(
                    ProxyDataSource.factory("Videre device acceptance", headers, source),
                )
                player = ExoPlayer.Builder(context).setMediaSourceFactory(media).build()
                player.volume = 0f
                player.setVideoSurface(output.surface)
                player.setVideoFrameMetadataListener { presentationTimeUs, _, _, _ ->
                    videoPresentationUs.set(presentationTimeUs)
                }
                player.addListener(object : Player.Listener {
                    override fun onPlayerError(failure: PlaybackException) {
                        error.set(failure)
                    }

                    override fun onPositionDiscontinuity(
                        oldPosition: Player.PositionInfo,
                        newPosition: Player.PositionInfo,
                        reason: Int,
                    ) {
                        if (reason == Player.DISCONTINUITY_REASON_SEEK) {
                            seekPosition.set(newPosition.positionMs)
                        }
                    }
                })
                player.setMediaItem(MediaItem.fromUri(source))
                player.prepare()
                player.play()
            }
        }

        fun position(): Long {
            var value = 0L
            main { value = player.currentPosition }
            return value
        }

        fun audioBuffers(): Int {
            var value = 0
            main {
                val counters = player.audioDecoderCounters
                counters?.ensureUpdated()
                value = counters?.renderedOutputBufferCount ?: 0
            }
            return value
        }

        fun await(label: String, timeoutMs: Long = 15000, condition: () -> Boolean) {
            val deadline = SystemClock.elapsedRealtime() + timeoutMs
            while (SystemClock.elapsedRealtime() < deadline) {
                error.get()?.let { throw AssertionError("Player failed during $label", it) }
                if (condition()) return
                SystemClock.sleep(50)
            }
            throw AssertionError("Timed out waiting for $label; frames=${videoFrames.get()}, position=${position()}")
        }

        override fun close() {
            main { player.release() }
            output.close()
        }
    }

    /** Drain decoder frames on an EGL consumer so playback cannot block on a full surface queue. */
    private class VideoOutput(private val frameCount: AtomicInteger) : AutoCloseable {
        private val thread = HandlerThread("videre-test-video").apply { start() }
        private val handler = Handler(thread.looper)
        private val initialized = CountDownLatch(1)
        private val failure = AtomicReference<Throwable>()
        lateinit var surface: Surface
        private lateinit var texture: SurfaceTexture
        private var display = EGL14.EGL_NO_DISPLAY
        private var eglContext = EGL14.EGL_NO_CONTEXT
        private var pbuffer = EGL14.EGL_NO_SURFACE

        init {
            handler.post {
                try {
                    display = EGL14.eglGetDisplay(EGL14.EGL_DEFAULT_DISPLAY)
                    check(EGL14.eglInitialize(display, IntArray(2), 0, IntArray(2), 0))
                    val configs = arrayOfNulls<EGLConfig>(1)
                    val attributes = intArrayOf(EGL14.EGL_RENDERABLE_TYPE, EGL14.EGL_OPENGL_ES2_BIT,
                        EGL14.EGL_RED_SIZE, 8, EGL14.EGL_GREEN_SIZE, 8, EGL14.EGL_BLUE_SIZE, 8,
                        EGL14.EGL_SURFACE_TYPE, EGL14.EGL_PBUFFER_BIT, EGL14.EGL_NONE)
                    check(EGL14.eglChooseConfig(display, attributes, 0, configs, 0, 1, IntArray(1), 0))
                    eglContext = EGL14.eglCreateContext(display, configs[0], EGL14.EGL_NO_CONTEXT,
                        intArrayOf(EGL14.EGL_CONTEXT_CLIENT_VERSION, 2, EGL14.EGL_NONE), 0)
                    pbuffer = EGL14.eglCreatePbufferSurface(display, configs[0],
                        intArrayOf(EGL14.EGL_WIDTH, 1, EGL14.EGL_HEIGHT, 1, EGL14.EGL_NONE), 0)
                    check(EGL14.eglMakeCurrent(display, pbuffer, pbuffer, eglContext))
                    val names = IntArray(1)
                    GLES20.glGenTextures(1, names, 0)
                    GLES20.glBindTexture(GLES11Ext.GL_TEXTURE_EXTERNAL_OES, names[0])
                    texture = SurfaceTexture(names[0]).apply {
                        setDefaultBufferSize(160, 90)
                        setOnFrameAvailableListener({
                            try {
                                updateTexImage()
                                frameCount.incrementAndGet()
                            } catch (error: RuntimeException) {
                                failure.compareAndSet(null, error)
                            }
                        }, handler)
                    }
                    surface = Surface(texture)
                } catch (error: Throwable) {
                    failure.set(error)
                } finally {
                    initialized.countDown()
                }
            }
            check(initialized.await(10, TimeUnit.SECONDS)) { "EGL consumer did not initialize" }
            failure.get()?.let { throw AssertionError("EGL consumer failed", it) }
        }

        override fun close() {
            val done = CountDownLatch(1)
            handler.post {
                surface.release()
                texture.release()
                EGL14.eglMakeCurrent(display, EGL14.EGL_NO_SURFACE, EGL14.EGL_NO_SURFACE, EGL14.EGL_NO_CONTEXT)
                EGL14.eglDestroySurface(display, pbuffer)
                EGL14.eglDestroyContext(display, eglContext)
                EGL14.eglTerminate(display)
                done.countDown()
            }
            check(done.await(5, TimeUnit.SECONDS)) { "EGL consumer did not stop" }
            thread.quitSafely()
        }
    }

    private data class FixtureResource(val bytes: ByteArray, val mime: String)
    private data class FixtureRequest(val destination: Pair<String, Int>, val path: String, val headers: Map<String, String>)

    private class FixtureSocks(
        private val resources: Map<String, FixtureResource>,
        private val holdBodies: Boolean = false,
    ) : AutoCloseable {
        constructor(bytes: ByteArray) : this(mapOf("/fixture.mp4" to FixtureResource(bytes, "video/mp4")))

        private val server = ServerSocket(0, 8, InetAddress.getByName("127.0.0.1"))
        private val executor = Executors.newCachedThreadPool()
        private val sockets = Collections.synchronizedList(mutableListOf<Socket>())
        val port: Int get() = server.localPort
        val destinations = ConcurrentLinkedQueue<Pair<String, Int>>()
        val ranges = AtomicInteger()
        val requests = ConcurrentLinkedQueue<FixtureRequest>()
        private val abortedBodies = AtomicInteger()
        val failure = AtomicReference<Throwable>()

        init {
            executor.execute {
                try {
                    while (!server.isClosed) {
                        val socket = server.accept()
                        sockets.add(socket)
                        executor.execute { serve(socket) }
                    }
                } catch (error: IOException) {
                    if (!server.isClosed) failure.compareAndSet(null, error)
                }
            }
        }

        private fun serve(socket: Socket) {
            socket.use {
                var holding = false
                try {
                    socket.soTimeout = 10000
                    val input = DataInputStream(socket.getInputStream())
                    check(input.readUnsignedByte() == 5)
                    val methods = ByteArray(input.readUnsignedByte()).also(input::readFully)
                    check(methods.contains(0.toByte()))
                    val output = socket.getOutputStream()
                    output.write(byteArrayOf(5, 0))
                    output.flush()
                    check(input.readUnsignedByte() == 5 && input.readUnsignedByte() == 1 && input.readUnsignedByte() == 0)
                    check(input.readUnsignedByte() == 3) { "SOCKS destination must remain a hostname" }
                    val host = ByteArray(input.readUnsignedByte()).also(input::readFully).toString(Charsets.US_ASCII)
                    val destination = host to input.readUnsignedShort()
                    destinations.add(destination)
                    check(destination.first in setOf("videre-playback.invalid", "videre-segments.invalid") && destination.second == 8123)
                    output.write(byteArrayOf(5, 0, 0, 1, 127, 0, 0, 1, 0, 80))
                    output.flush()
                    val headers = readHeader(input)
                    val target = headers.lineSequence().first().split(' ')[1]
                    val path = android.net.Uri.parse(target).path ?: throw IOException("Missing fixture path")
                    val requestHeaders = headers.lineSequence().drop(1).filter { it.contains(':') }.associate { line ->
                        line.substringBefore(':').lowercase(Locale.ROOT) to line.substringAfter(':').trim()
                    }
                    requests.add(FixtureRequest(destination, path, requestHeaders))
                    val resource = resources[path] ?: throw IOException("Unknown fixture path")
                    val bytes = resource.bytes
                    val range = headers.lineSequence().firstOrNull { it.startsWith("Range:", ignoreCase = true) }
                    val match = range?.let { Regex("bytes=(\\d+)-(\\d*)", RegexOption.IGNORE_CASE).find(it) }
                    val start = match?.groupValues?.get(1)?.toInt() ?: 0
                    val end = match?.groupValues?.get(2)?.takeIf(String::isNotEmpty)?.toInt()
                        ?.coerceAtMost(bytes.lastIndex) ?: bytes.lastIndex
                    check(start in bytes.indices && end >= start)
                    if (match != null) ranges.incrementAndGet()
                    val length = end - start + 1
                    val status = if (match == null) "200 OK" else "206 Partial Content"
                    val response = buildString {
                        append("HTTP/1.1 $status\r\nContent-Type: ${resource.mime}\r\nAccept-Ranges: bytes\r\n")
                        append("Content-Length: $length\r\nConnection: close\r\n")
                        if (match != null) append("Content-Range: bytes $start-$end/${bytes.size}\r\n")
                        append("\r\n")
                    }
                    output.write(response.toByteArray(Charsets.US_ASCII))
                    output.write(bytes, start, if (holdBodies) minOf(128, length) else length)
                    output.flush()
                    if (holdBodies) {
                        holding = true
                        socket.soTimeout = 0
                        // No next request is legal on this Connection: close
                        // response. EOF/RST proves the old media call closed.
                        if (input.read() == -1) abortedBodies.incrementAndGet()
                    }
                } catch (error: IOException) {
                    // Media3 may abandon a request while seeking or releasing.
                    if (holding && !server.isClosed) abortedBodies.incrementAndGet()
                } catch (error: Throwable) {
                    failure.compareAndSet(null, error)
                } finally {
                    sockets.remove(socket)
                }
            }
        }

        fun awaitAbortedBodies(count: Int) {
            val deadline = SystemClock.elapsedRealtime() + 5000
            while (SystemClock.elapsedRealtime() < deadline && abortedBodies.get() < count) {
                SystemClock.sleep(20)
            }
            assertEquals("Old media sockets remained open after policy change", count, abortedBodies.get())
        }

        private fun readHeader(input: DataInputStream): String {
            val bytes = ArrayList<Byte>()
            while (bytes.size < 32768) {
                bytes.add(input.readByte())
                val size = bytes.size
                if (size >= 4 && bytes.subList(size - 4, size) == listOf(13.toByte(), 10.toByte(), 13.toByte(), 10.toByte())) {
                    return bytes.toByteArray().toString(Charsets.US_ASCII)
                }
            }
            throw IOException("HTTP fixture header exceeds limit")
        }

        override fun close() {
            server.close()
            synchronized(sockets) { sockets.toList() }.forEach { it.close() }
            executor.shutdownNow()
        }
    }
}
