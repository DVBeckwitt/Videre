package com.github.dvbeckwitt.videre.proxy

import android.content.Context
import android.net.Uri
import androidx.media3.common.C
import androidx.media3.datasource.ByteArrayDataSource
import androidx.media3.datasource.DataSource
import androidx.media3.datasource.DataSpec
import androidx.media3.datasource.TransferListener
import androidx.test.ext.junit.runners.AndroidJUnit4
import androidx.test.platform.app.InstrumentationRegistry
import java.io.ByteArrayOutputStream
import java.io.File
import java.io.IOException
import java.util.UUID
import java.util.concurrent.CountDownLatch
import java.util.concurrent.Executors
import java.util.concurrent.TimeUnit
import java.util.concurrent.atomic.AtomicBoolean
import java.util.concurrent.atomic.AtomicInteger
import java.util.concurrent.atomic.AtomicLong
import okio.ByteString.Companion.encodeUtf8
import org.junit.After
import org.junit.Assert.assertArrayEquals
import org.junit.Assert.assertEquals
import org.junit.Assert.assertThrows
import org.junit.Assert.assertTrue
import org.junit.Before
import org.junit.Test
import org.junit.runner.RunWith

/** Real native disk spans in the isolated plugin test APK; no network or user downloads. */
@RunWith(AndroidJUnit4::class)
class PlaybackCacheDeviceTest {
    private val context: Context get() = InstrumentationRegistry.getInstrumentation().targetContext
    private val origin = "https://instance.example"
    private val media = "$origin/videoplayback?sig=old"
    private val quota = 64L * 1024 * 1024
    private val payload = ByteArray(64 * 1024) { (it % 251).toByte() }
    private var savedPolicy: Map<String, Any>? = null
    private var savedCache: Map<String, Any>? = null

    @Before
    fun prepareIsolatedCache() {
        // A misconfigured instrumentation target must never clear the installed user's cache.
        check(context.packageName != "com.github.dvbeckwitt.videre")
        ProxyDataSource.initialize(context)
        savedPolicy = ProxyDataSource.configuration()
        ProxyDataSource.configure(ProxyPolicy().toMap())
        PlaybackMediaCache.initialize(context)
        savedCache = PlaybackMediaCache.status()
        PlaybackMediaCache.configure(mapOf("enabled" to true, "maxBytes" to quota))
        PlaybackMediaCache.clear()
    }

    @After
    fun restoreConfiguration() {
        if (savedCache != null) {
            PlaybackMediaCache.clear()
            PlaybackMediaCache.configure(savedCache!!)
        }
        savedPolicy?.let(ProxyDataSource::configure)
    }

    private fun resource(url: String = media, key: String = "audio:140:65536:100:en",
                         persistent: Boolean = true, manifest: Boolean = false): Map<String, Any> =
        mapOf("url" to url, "key" to key, "persistent" to persistent, "manifest" to manifest)

    private fun descriptor(resources: List<Map<String, Any>> = listOf(resource()),
                           profile: String = "test-person", account: String = "test-account",
                           session: String = "test-session"): Map<String, Any> =
        mapOf("version" to 1, "profileId" to profile, "accountId" to account,
            "origin" to origin, "contentId" to "fixture", "sessionId" to session,
            "adaptiveVod" to true, "resources" to resources)

    private fun factory(upstream: DataSource.Factory, values: Map<String, Any> = descriptor(),
                        source: String = media, manifest: Boolean = false): DataSource.Factory =
        PlaybackMediaCache.factory(context, upstream, source, values, manifest)

    private fun songDescriptor(source: String = media, size: Long = payload.size.toLong(),
                               id: String = "fixture"): Map<String, Any> {
        val representation = """["representation","140","$size","100","type",null,"track"]"""
        return descriptor(listOf(resource(source, representation))) + mapOf(
            "contentId" to id,
            "musicSong" to mapOf("title" to "Fixture song", "artist" to "Fixture artist",
                "lengthSeconds" to 45, "byteLength" to size),
        )
    }

    private fun cachedSongFactory(owner: Map<String, Any>, row: Map<String, Any>): Pair<DataSource.Factory, String> {
        val rendition = row.getValue("rendition")
        val uri = "videre-cache://music/$rendition"
        return PlaybackMediaCache.cachedMusicFactory(context, uri,
            owner + mapOf("contentId" to row.getValue("videoId"), "rendition" to rendition)) to uri
    }

    private data class Read(val bytes: ByteArray, val uri: Uri?)

    private fun read(factory: DataSource.Factory, url: String = media,
                     offset: Long = 0, length: Long? = null): Read {
        val source = factory.createDataSource()
        return try {
            source.open(DataSpec.Builder().setUri(url).setPosition(offset).apply {
                if (length != null) setLength(length)
            }.build())
            val output = ByteArrayOutputStream()
            val buffer = ByteArray(8192)
            while (true) {
                val count = source.read(buffer, 0, buffer.size)
                if (count == C.RESULT_END_OF_INPUT) break
                output.write(buffer, 0, count)
            }
            Read(output.toByteArray(), source.uri)
        } finally {
            source.close()
        }
    }

    private fun drain(factory: DataSource.Factory, url: String): Long {
        val source = factory.createDataSource()
        return try {
            source.open(DataSpec.Builder().setUri(url).build())
            val buffer = ByteArray(64 * 1024)
            var total = 0L
            while (true) {
                val count = source.read(buffer, 0, buffer.size)
                if (count == C.RESULT_END_OF_INPUT) break
                total += count
            }
            total
        } finally {
            source.close()
        }
    }

    @Test(timeout = 15000)
    fun replayAndBackwardByteRangeReadNoUpstreamBytes() {
        val upstream = CountingFactory(mapOf("/videoplayback" to payload))
        val cached = factory(upstream)
        assertArrayEquals(payload, read(cached).bytes)
        assertEquals(1, upstream.opens.get())
        assertEquals(payload.size.toLong(), upstream.bytes.get())
        assertEquals(payload.size.toLong(), PlaybackMediaCache.status()["usedBytes"])

        assertArrayEquals(payload, read(cached).bytes)
        assertArrayEquals(payload.copyOfRange(1024, 4096),
            read(cached, offset = 1024, length = 3072).bytes)
        assertEquals("Cached replay and rewind opened the upstream", 1, upstream.opens.get())
        assertEquals(payload.size.toLong(), upstream.bytes.get())
    }

    @Test(timeout = 15000)
    fun onlyCompleteDecoderConfirmedSongsAreListedAndReadCacheOnly() {
        val upstream = CountingFactory(mapOf("/videoplayback" to payload))
        val values = songDescriptor()
        val source = factory(upstream, values)
        val partial = source.createDataSource()
        try {
            partial.open(DataSpec(Uri.parse(media)))
            assertEquals(1024, partial.read(ByteArray(1024), 0, 1024))
        } finally {
            partial.close()
        }
        PlaybackMediaCache.confirmDecodedMusic(source)
        assertTrue(PlaybackMediaCache.cachedMusicSongs(values).isEmpty())
        assertArrayEquals(payload, read(source).bytes)

        val rows = PlaybackMediaCache.cachedMusicSongs(values)
        val row = rows.single()
        assertEquals("fixture", row["videoId"])
        assertEquals("Fixture song", row["title"])
        assertEquals("Fixture artist", row["artist"])
        assertEquals(45, row["lengthSeconds"])
        assertEquals(setOf("videoId", "title", "artist", "lengthSeconds", "rendition"), row.keys)

        val (cacheOnly, synthetic) = cachedSongFactory(values, row)
        val networkOpens = upstream.opens.get()
        val used = PlaybackMediaCache.status()["usedBytes"]
        assertArrayEquals(payload, read(cacheOnly, synthetic).bytes)
        assertArrayEquals(payload.copyOfRange(1024, 4096),
            read(cacheOnly, synthetic, offset = 1024, length = 3072).bytes)
        assertEquals(networkOpens, upstream.opens.get())
        assertEquals(used, PlaybackMediaCache.status()["usedBytes"])
        assertThrows(CachedMusicUnavailable::class.java) { read(cacheOnly, media) }

        for ((field, other) in mapOf("profileId" to "another-profile", "accountId" to "another-account",
            "origin" to "https://another.example")) {
            val another = values + (field to other)
            assertTrue(PlaybackMediaCache.cachedMusicSongs(another).isEmpty())
            val (anotherSource, anotherUri) = cachedSongFactory(another, row)
            assertThrows(CachedMusicUnavailable::class.java) { read(anotherSource, anotherUri) }
        }

        PlaybackMediaCache.clear()
        assertTrue(PlaybackMediaCache.cachedMusicSongs(values).isEmpty())
        assertThrows(IOException::class.java) { read(cacheOnly, synthetic) }
        val (stale, staleUri) = cachedSongFactory(values, row)
        assertThrows(CachedMusicUnavailable::class.java) { read(stale, staleUri) }
        assertEquals(networkOpens, upstream.opens.get())
    }

    @Test(timeout = 15000)
    fun completeCacheNeedsDecoderProofAndMatchingRepresentationLength() {
        val upstream = CountingFactory(mapOf("/videoplayback" to payload))
        val valid = songDescriptor()
        val unconfirmed = factory(upstream, valid)
        assertArrayEquals(payload, read(unconfirmed).bytes)
        assertTrue(PlaybackMediaCache.cachedMusicSongs(valid).isEmpty())

        val wrongSize = songDescriptor(size = payload.size.toLong() + 1, id = "wrong-size")
        val short = factory(upstream, wrongSize)
        assertArrayEquals(payload, read(short).bytes)
        PlaybackMediaCache.confirmDecodedMusic(short)
        assertTrue(PlaybackMediaCache.cachedMusicSongs(wrongSize).isEmpty())

        PlaybackMediaCache.confirmDecodedMusic(unconfirmed)
        assertEquals("fixture", PlaybackMediaCache.cachedMusicSongs(valid).single()["videoId"])
        PlaybackMediaCache.configure(mapOf("enabled" to false, "maxBytes" to quota))
        assertTrue(PlaybackMediaCache.cachedMusicSongs(valid).isEmpty())
    }

    @Test(timeout = 15000)
    fun companionSourcesBypassExistingAndNewBytesAndFollowAccountRevocation() {
        val (gateway, marker) = gatewayFixture(origin)
        val extraOrigin = "https://media.example"
        val child = "$extraOrigin/videoplayback"
        val policy = mapOf("origin" to origin, "origins" to listOf(extraOrigin), "gatewayContext" to marker)
        val upstream = CountingFactory(mapOf("/videoplayback" to payload))
        val cache = descriptor() + ("gatewayContext" to marker)
        // An earlier strict source has populated this selected-host URL.
        read(factory(upstream, cache))
        val delegated = PlaybackMediaCache.factory(context, upstream, media, cache,
            PlaybackCacheRequest.PROGRESSIVE, policy)
        val directLive = PlaybackMediaCache.factory(context, upstream, child, null,
            PlaybackCacheRequest.ADAPTIVE_MEDIA, policy)
        assertArrayEquals(payload, read(delegated).bytes)
        assertArrayEquals(payload, read(delegated, child).bytes)
        assertArrayEquals(payload, read(directLive, child).bytes)
        assertEquals(4, upstream.opens.get())
        assertEquals(payload.size.toLong(), PlaybackMediaCache.status()["usedBytes"])
        assertThrows(IOException::class.java) { read(directLive, "file:///fixture") }
        assertThrows(IOException::class.java) { read(delegated, "https://other.example/videoplayback") }
        PlaybackMediaCache.revokeAccount(gateway.key)
        assertThrows(IOException::class.java) { read(directLive, child) }
        assertThrows(IOException::class.java) { read(delegated, media) }
        assertEquals(4, upstream.opens.get())
        // A stale source map delivered *after* the account-epoch change must
        // not create a new companion factory once the grant has been removed.
        ProxyDataSource.setMediaCompanionOrigins(policy + ("origins" to emptyList<String>()))
        assertThrows(IOException::class.java) {
            PlaybackMediaCache.factory(context, upstream, child, null, PlaybackCacheRequest.ADAPTIVE_MEDIA, policy)
        }
        assertThrows(IOException::class.java) { ProxyDataSource.factory(null, null, child, policy) }
        assertArrayEquals(payload, read(factory(upstream, cache)).bytes)
    }

    @Test(timeout = 15000)
    fun refreshedSignedUrlReusesBytesWithoutRestoringOldRedirect() {
        val staleRedirect = "$origin/redirected-media?signature=expired"
        val upstream = CountingFactory(mapOf("/videoplayback" to payload), staleRedirect)
        read(factory(upstream))
        val fresh = "$origin/videoplayback?sig=fresh"
        val refreshed = factory(upstream,
            descriptor(listOf(resource(fresh)), session = "fresh-session"), fresh)
        val result = read(refreshed, fresh)
        assertArrayEquals(payload, result.bytes)
        assertEquals(Uri.parse(fresh), result.uri)
        assertEquals("URL refresh fetched an already cached representation", 1, upstream.opens.get())
    }

    @Test(timeout = 15000)
    fun namespacesAndSessionOnlySourcesCannotReuseOtherOwnersBytes() {
        val upstream = CountingFactory(mapOf("/videoplayback" to payload))
        read(factory(upstream))
        read(factory(upstream, descriptor(profile = "other-person")))
        read(factory(upstream, descriptor(account = "other-account")))
        read(factory(upstream, descriptor(listOf(resource(persistent = false)))))
        read(factory(upstream, descriptor(listOf(resource(persistent = false)), session = "other-session")))
        assertEquals(5, upstream.opens.get())
        assertEquals(payload.size.toLong() * 5, upstream.bytes.get())
    }

    @Test(timeout = 15000)
    fun deletingAnInactiveProfileLeavesOtherProfilesOpenPlaybackAndBytesIntact() {
        val upstream = CountingFactory(mapOf("/videoplayback" to payload))
        val profileA = factory(upstream, descriptor(profile = "person-a"))
        val profileB = factory(upstream, descriptor(profile = "person-b"))
        read(profileA)
        read(profileB)
        assertEquals(payload.size.toLong() * 2, PlaybackMediaCache.status()["usedBytes"])

        val openB = profileB.createDataSource()
        openB.open(DataSpec.Builder().setUri(media).build())
        try {
            PlaybackMediaCache.removeProfile("person-a")
            assertEquals(payload.size.toLong(), PlaybackMediaCache.status()["usedBytes"])
            assertThrows(IOException::class.java) { read(profileA) }
            val prefix = ByteArray(32)
            assertEquals(prefix.size, openB.read(prefix, 0, prefix.size))
            assertArrayEquals(payload.copyOfRange(0, prefix.size), prefix)
            assertEquals(2, upstream.opens.get())

            assertThrows(IllegalStateException::class.java) {
                PlaybackMediaCache.removeProfile("person-b")
            }
            val continuation = ByteArray(32)
            assertEquals(continuation.size, openB.read(continuation, 0, continuation.size))
            assertArrayEquals(payload.copyOfRange(32, 64), continuation)
            assertEquals(payload.size.toLong(), PlaybackMediaCache.status()["usedBytes"])

            assertArrayEquals(payload,
                read(factory(upstream, descriptor(profile = "person-a"))).bytes)
            assertEquals("Deleted profile A must refill its own bytes", 3, upstream.opens.get())
            assertArrayEquals(payload, read(profileB).bytes)
            assertEquals("Profile B must keep its cached bytes", 3, upstream.opens.get())
        } finally {
            openB.close()
        }
    }

    @Test(timeout = 15000)
    fun adaptiveMediaKeepsSeparateSpansWhileManifestsAndUnknownChildrenBypass() {
        val manifest = "$origin/opaque-document?sig=manifest"
        val audio = "$origin/audio"
        val video = "$origin/video"
        val child = "$origin/opaque-child?sig=child"
        val audioBytes = byteArrayOf(1, 2, 3, 4)
        val videoBytes = byteArrayOf(9, 8, 7, 6)
        val upstream = CountingFactory(mapOf("/opaque-document" to byteArrayOf(0),
            "/audio" to audioBytes, "/video" to videoBytes, "/opaque-child" to byteArrayOf(5)))
        val values = descriptor(listOf(resource(manifest, manifest = true),
            resource(audio, "audio:140:4:100"), resource(video, "video:137:4:100")))
        val cached = factory(upstream, values, manifest, manifest = true)
        repeat(2) {
            assertArrayEquals(audioBytes, read(cached, audio).bytes)
            assertArrayEquals(videoBytes, read(cached, video).bytes)
            read(cached, manifest)
            read(cached, child)
        }
        assertEquals(6, upstream.opens.get())
        assertEquals(8L, PlaybackMediaCache.status()["usedBytes"])
    }

    @Test(timeout = 15000)
    fun typedAdaptiveChildrenCacheDistinctRangesWithinTheirSessionAndOwner() {
        val manifest = "$origin/opaque-playlist"
        val audio = "$origin/segment/audio?part=1"
        val video = "$origin/segment/video?part=1"
        val otherBytes = payload.reversedArray()
        val upstream = CountingFactory(mapOf("/segment/audio" to payload, "/segment/video" to otherBytes))
        val resources = listOf(resource(manifest, manifest = true))
        fun media(profile: String = "test-person", session: String = "test-session") =
            PlaybackMediaCache.factory(context, upstream, manifest,
                descriptor(resources, profile = profile, session = session), PlaybackCacheRequest.ADAPTIVE_MEDIA)
        val cached = media()
        assertArrayEquals(payload, read(cached, audio).bytes)
        assertArrayEquals(otherBytes, read(cached, video).bytes)
        assertArrayEquals(payload.copyOfRange(1024, 4096), read(cached, audio, 1024, 3072).bytes)
        assertEquals("A repeated segment range fetched upstream bytes", 2, upstream.opens.get())
        assertEquals(payload.size.toLong() * 2, upstream.bytes.get())
        read(cached, "$origin/segment/audio?part=2")
        read(media(session = "next-session"), audio)
        read(media(profile = "other-person"), audio)
        assertEquals("Child URI, session and profile identities must remain distinct", 5, upstream.opens.get())
        assertEquals(payload.size.toLong() * 5, PlaybackMediaCache.status()["usedBytes"])
    }

    @Test(timeout = 15000)
    fun typedManifestsAndEncryptionKeysNeverReadOrWriteCachedBytes() {
        val manifest = "$origin/opaque-playlist"
        val key = "$origin/opaque-key"
        val knownManifest = "$origin/other-playlist"
        val previousKey = byteArrayOf(1, 2, 3, 4)
        val currentKey = byteArrayOf(9, 8, 7, 6)
        val bytes = mutableMapOf("/opaque-playlist" to byteArrayOf(0),
            "/opaque-key" to previousKey, "/other-playlist" to byteArrayOf(5))
        val upstream = CountingFactory(bytes)
        val values = descriptor(listOf(resource(manifest, manifest = true),
            resource(key, "mapped-resource"), resource(knownManifest, manifest = true)))
        val media = PlaybackMediaCache.factory(context, upstream, manifest, values, PlaybackCacheRequest.ADAPTIVE_MEDIA)
        // Even an existing same-URI cache entry must not supply an HLS key.
        assertArrayEquals(previousKey, read(media, key).bytes)
        bytes["/opaque-key"] = currentKey
        val keys = PlaybackMediaCache.factory(context, upstream, manifest, values,
            PlaybackMediaCache.requestForMedia3DataType(C.DATA_TYPE_DRM))
        val playlists = PlaybackMediaCache.factory(context, upstream, manifest, values,
            PlaybackMediaCache.requestForMedia3DataType(C.DATA_TYPE_MANIFEST))
        repeat(2) {
            assertArrayEquals(currentKey, read(keys, key).bytes)
            read(playlists, manifest)
            // A descriptor-marked manifest remains excluded even if a caller
            // accidentally classifies that URL as a media request.
            read(media, knownManifest)
        }
        assertEquals(7, upstream.opens.get())
        assertEquals(previousKey.size.toLong(), PlaybackMediaCache.status()["usedBytes"])
    }

    @Test(timeout = 15000)
    fun typedChildHitsStillRejectStaleProxyEpochBeforeAnyUpstreamRead() {
        val manifest = "$origin/opaque-playlist"
        val child = "$origin/opaque-child"
        val upstream = CountingFactory(mapOf("/opaque-child" to payload))
        val values = descriptor(listOf(resource(manifest, manifest = true)))
        val cached = PlaybackMediaCache.factory(context, upstream, manifest, values, PlaybackCacheRequest.ADAPTIVE_MEDIA)
        read(cached, child)
        val reader = cached.createDataSource().also { it.open(DataSpec.Builder().setUri(child).build()) }
        try {
            ProxyDataSource.configure(ProxyPolicy(enabled = true, port = 19050).toMap())
            assertThrows(IOException::class.java) { reader.read(ByteArray(16), 0, 16) }
            assertThrows(IOException::class.java) { read(cached, child) }
            assertEquals(1, upstream.opens.get())
            assertEquals(payload.size.toLong(), upstream.bytes.get())
        } finally { reader.close() }
    }

    @Test(timeout = 20000)
    fun typedChildHitsStillRejectRevokedAccountBeforeAnyUpstreamRead() {
        val manifest = "$origin/opaque-playlist"
        val child = "$origin/opaque-child"
        val (gateway, marker) = gatewayFixture(origin)
        val upstream = CountingFactory(mapOf("/opaque-child" to payload))
        val values = descriptor(listOf(resource(manifest, manifest = true)), account = gateway.key) +
            mapOf("gatewayContext" to marker)
        var reader: DataSource? = null
        try {
            val cached = PlaybackMediaCache.factory(context, upstream, manifest, values, PlaybackCacheRequest.ADAPTIVE_MEDIA)
            read(cached, child)
            val active = cached.createDataSource().also { it.open(DataSpec.Builder().setUri(child).build()) }
            reader = active
            GatewaySessions.signOut(gateway)
            assertThrows(GatewayAuthenticationRequired::class.java) { active.read(ByteArray(16), 0, 16) }
            assertThrows(GatewayAuthenticationRequired::class.java) { read(cached, child) }
            assertEquals(1, upstream.opens.get())
        } finally {
            reader?.close()
            removeGatewayFixture(gateway)
        }
    }

    @Test(timeout = 15000)
    fun liveSourcesWithoutCacheIdentityKeepTypedMediaUncached() {
        val upstream = CountingFactory(mapOf("/videoplayback" to payload))
        val live = PlaybackMediaCache.factory(context, upstream, media, null, PlaybackCacheRequest.ADAPTIVE_MEDIA)
        repeat(2) { assertArrayEquals(payload, read(live).bytes) }
        assertEquals(2, upstream.opens.get())
        assertEquals(0L, PlaybackMediaCache.status()["usedBytes"])
    }

    @Test(timeout = 15000)
    fun unclassifiedAdaptiveChildrenKeepTheConservativeBypass() {
        val manifest = "$origin/opaque-playlist"
        val child = "$origin/opaque-child"
        val upstream = CountingFactory(mapOf("/opaque-child" to payload))
        val values = descriptor(listOf(resource(manifest, manifest = true)))
        for (unclassified in listOf(values - "adaptiveVod", values + ("adaptiveVod" to false),
            values + ("adaptiveVod" to null))) {
            val source = PlaybackMediaCache.factory(context, upstream, manifest, unclassified, PlaybackCacheRequest.ADAPTIVE_MEDIA)
            repeat(2) { assertArrayEquals(payload, read(source, child).bytes) }
        }
        assertEquals(6, upstream.opens.get())
        assertEquals(0L, PlaybackMediaCache.status()["usedBytes"])
    }

    @Test(timeout = 15000)
    fun failedCacheInitializationKeepsTypedChildrenOnTheirAdmittedUpstream() {
        val manifest = "$origin/opaque-playlist"
        val child = "$origin/opaque-child"
        val upstream = CountingFactory(mapOf("/opaque-child" to payload))
        val values = descriptor(listOf(resource(manifest, manifest = true)))
        // The isolated test cache is released before temporarily making its
        // directory unavailable; neither production storage nor downloads are touched.
        PlaybackMediaCache.configure(mapOf("enabled" to true, "maxBytes" to quota))
        val directory = File(context.cacheDir, "videre-playback-v1")
        val backup = File(context.cacheDir, "cache-fixture-${UUID.randomUUID()}")
        assertTrue(directory.renameTo(backup))
        try {
            directory.writeText("fixture directory unavailable")
            val cached = PlaybackMediaCache.factory(context, upstream, manifest, values, PlaybackCacheRequest.ADAPTIVE_MEDIA)
            assertArrayEquals(payload.copyOfRange(1024, 4096), read(cached, child, 1024, 3072).bytes)
            assertEquals(1, upstream.opens.get())
            assertThrows(IOException::class.java) { read(cached, "https://www.youtube.com/opaque-child") }
            assertThrows(IOException::class.java) { read(cached, "https://foreign.example/opaque-child") }
            ProxyDataSource.configure(ProxyPolicy(enabled = true, port = 19050).toMap())
            assertThrows(IOException::class.java) { read(cached, child) }
            assertEquals("Disk fallback must not bypass destination or session admission", 1, upstream.opens.get())
        } finally {
            assertTrue(directory.delete())
            assertTrue(backup.renameTo(directory))
        }
    }

    @Test(timeout = 15000)
    fun staleFactoriesAndOpenReadersFailAfterContextInvalidation() {
        val upstream = CountingFactory(mapOf("/videoplayback" to payload))
        val cached = factory(upstream)
        read(cached)
        val open = cached.createDataSource()
        open.open(DataSpec.Builder().setUri(media).build())
        try {
            PlaybackMediaCache.invalidate()
            assertThrows(IOException::class.java) { open.read(ByteArray(8), 0, 8) }
            assertThrows(IOException::class.java) { read(cached) }
            assertEquals(1, upstream.opens.get())
            assertArrayEquals(payload, read(factory(upstream)).bytes)
            assertEquals(1, upstream.opens.get())
        } finally {
            open.close()
        }
    }

    @Test(timeout = 15000)
    fun cacheTransitionRejectsNewSourcesUntilReaderCloseAndReleaseComplete() {
        val enteredClose = CountDownLatch(1)
        val releaseClose = CountDownLatch(1)
        val blockFirstClose = AtomicBoolean(true)
        val counted = CountingFactory(mapOf("/videoplayback" to payload))
        val upstream = DataSource.Factory {
            val delegate = counted.createDataSource()
            object : DataSource by delegate {
                override fun close() {
                    if (blockFirstClose.compareAndSet(true, false)) {
                        enteredClose.countDown()
                        if (!releaseClose.await(10, TimeUnit.SECONDS)) {
                            throw IOException("Fixture close was not released")
                        }
                    }
                    delegate.close()
                }
            }
        }
        val existing = factory(upstream)
        val active = existing.createDataSource()
        val unopened = existing.createDataSource()
        val worker = Executors.newSingleThreadExecutor()
        try {
            active.open(DataSpec.Builder().setUri(media).build())
            assertEquals(32, active.read(ByteArray(32), 0, 32))
            val transition = worker.submit {
                PlaybackMediaCache.configure(mapOf("enabled" to true, "maxBytes" to quota * 2))
            }
            assertTrue("Transition did not reach the held source close",
                enteredClose.await(5, TimeUnit.SECONDS))
            assertThrows(IOException::class.java) { factory(upstream) }
            assertThrows(IOException::class.java) {
                unopened.open(DataSpec.Builder().setUri(media).build())
            }
            assertEquals("A transition admitted a new upstream reader", 1, counted.opens.get())

            releaseClose.countDown()
            transition.get(5, TimeUnit.SECONDS)
            assertEquals(quota * 2, PlaybackMediaCache.status()["maxBytes"])
            assertArrayEquals(payload, read(factory(upstream)).bytes)
        } finally {
            releaseClose.countDown()
            worker.shutdown()
            assertTrue("Cache transition worker did not terminate", worker.awaitTermination(5, TimeUnit.SECONDS))
            active.close()
            unopened.close()
        }
    }

    @Test(timeout = 20000)
    fun revokedNerdVpnKeyBlocksCachedBytesWithoutInterruptingPublicPlayback() {
        val nerdOrigin = "https://invidious.nerdvpn.de"
        val (gateway, marker) = gatewayFixture(nerdOrigin)
        val nerdMedia = "$nerdOrigin/videoplayback?sig=fixture-only"
        val upstream = CountingFactory(mapOf("/videoplayback" to payload))
        val protectedValues = descriptor(listOf(resource(nerdMedia)), account = gateway.key) +
            mapOf("origin" to nerdOrigin, "gatewayContext" to marker)
        var protectedReader: DataSource? = null
        var publicReader: DataSource? = null
        try {
            NerdVpnAccess.setKey(gateway, "nvpn_" + "A".repeat(32))
            assertEquals("ready", NerdVpnAccess.status(gateway)["state"])
            val protectedCache = factory(upstream, protectedValues, nerdMedia)
            val publicCache = factory(upstream)
            assertArrayEquals(payload, read(protectedCache, nerdMedia).bytes)
            assertArrayEquals(payload, read(publicCache).bytes)
            val activeProtected = protectedCache.createDataSource().also {
                it.open(DataSpec.Builder().setUri(nerdMedia).build())
            }
            protectedReader = activeProtected
            val activePublic = publicCache.createDataSource().also {
                it.open(DataSpec.Builder().setUri(media).build())
            }
            publicReader = activePublic
            assertEquals(2, upstream.opens.get())

            NerdVpnAccess.clear(gateway)
            assertThrows(IOException::class.java) { activeProtected.read(ByteArray(8), 0, 8) }
            assertThrows(IOException::class.java) { read(protectedCache, nerdMedia) }
            assertThrows(NerdVpnAccessRequired::class.java) {
                factory(upstream, protectedValues, nerdMedia)
            }
            val prefix = ByteArray(32)
            assertEquals(prefix.size, activePublic.read(prefix, 0, prefix.size))
            assertArrayEquals(payload.copyOfRange(0, prefix.size), prefix)
            assertArrayEquals(payload, read(publicCache).bytes)
            assertEquals("Revocation performed an upstream read or disturbed public bytes", 2, upstream.opens.get())
        } finally {
            protectedReader?.close()
            publicReader?.close()
            NerdVpnAccess.clear(gateway)
            assertTrue(context.getSharedPreferences(NERDVPN_PREFERENCES, Context.MODE_PRIVATE)
                .edit().remove("account_${gateway.key}").commit())
            removeGatewayFixture(gateway)
        }
    }

    @Test(timeout = 20000)
    fun changedGatewaySessionRevisionRejectsCachedReaderAndFactoryWithoutFetching() {
        val (gateway, marker) = gatewayFixture(origin)
        val upstream = CountingFactory(mapOf("/videoplayback" to payload))
        val values = descriptor(account = gateway.key) + mapOf("gatewayContext" to marker)
        var reader: DataSource? = null
        try {
            assertEquals(0L, GatewaySessions.cacheAdmissionRevision(gateway))
            val cached = factory(upstream, values)
            assertArrayEquals(payload, read(cached).bytes)
            val activeReader = cached.createDataSource().also {
                it.open(DataSpec.Builder().setUri(media).build())
            }
            reader = activeReader
            GatewaySessions.signOut(gateway)
            assertEquals(1L, GatewaySessions.cacheAdmissionRevision(gateway))
            assertThrows(GatewayAuthenticationRequired::class.java) { activeReader.read(ByteArray(8), 0, 8) }
            assertThrows(GatewayAuthenticationRequired::class.java) { read(cached) }
            assertEquals("Stale authenticated cache access fetched upstream bytes", 1, upstream.opens.get())
            assertEquals(payload.size.toLong(), upstream.bytes.get())
        } finally {
            reader?.close()
            removeGatewayFixture(gateway)
        }
    }

    @Test(timeout = 15000)
    fun invalidDestinationIsRejectedBeforeAnUpstreamOpenEvenWhenBytesExist() {
        val upstream = CountingFactory(mapOf("/videoplayback" to payload))
        val cached = factory(upstream)
        read(cached)
        for (url in listOf("https://www.youtube.com/videoplayback", "https://rr1.googlevideo.com/videoplayback",
            "https://foreign.example/videoplayback", "http://instance.example/videoplayback")) {
            assertThrows(IOException::class.java) { read(cached, url) }
        }
        assertEquals(1, upstream.opens.get())
    }

    @Test(timeout = 15000)
    fun disablingAndClearingCachePreservePolicyAndReportActualUsage() {
        val upstream = CountingFactory(mapOf("/videoplayback" to payload))
        read(factory(upstream))
        PlaybackMediaCache.configure(mapOf("enabled" to false, "maxBytes" to quota))
        val disabled = factory(upstream)
        read(disabled)
        read(disabled)
        assertEquals(3, upstream.opens.get())
        assertEquals(false, PlaybackMediaCache.status()["enabled"])
        PlaybackMediaCache.clear()
        assertEquals(0L, PlaybackMediaCache.status()["usedBytes"])
        PlaybackMediaCache.configure(mapOf("enabled" to true, "maxBytes" to quota))
        read(factory(upstream))
        assertEquals(4, upstream.opens.get())
        assertEquals(payload.size.toLong(), PlaybackMediaCache.status()["usedBytes"])
    }

    @Test(timeout = 60000)
    fun lruEvictionRespectsTheConfiguredProductionQuota() {
        val size = 40L * 1024 * 1024
        val upstream = PatternFactory(size)
        val first = "$origin/large-first"
        val second = "$origin/large-second"
        val cached = factory(upstream, descriptor(listOf(resource(first, "first:40MiB"),
            resource(second, "second:40MiB"))), first)
        assertEquals(size, drain(cached, first))
        assertEquals(size, drain(cached, second))
        assertTrue((PlaybackMediaCache.status()["usedBytes"] as Long) <= quota)
        val opens = upstream.opens.get()
        read(cached, second, length = 1024)
        assertEquals("The newest entry should remain cached", opens, upstream.opens.get())
        read(cached, first, length = 1024)
        assertTrue("The oldest span should require an upstream read", upstream.opens.get() > opens)
        assertTrue((PlaybackMediaCache.status()["usedBytes"] as Long) <= quota)
    }

    @Test(timeout = 60000)
    fun partiallyEvictedSongDisappearsAndItsOldSelectionFailsClosed() {
        val size = 40L * 1024 * 1024
        val upstream = PatternFactory(size)
        val first = "$origin/cached-song"
        val second = "$origin/uncataloged-media"
        val values = songDescriptor(first, size)
        val song = factory(upstream, values, first)
        assertEquals(size, drain(song, first))
        PlaybackMediaCache.confirmDecodedMusic(song)
        val (cacheOnly, synthetic) = cachedSongFactory(values, PlaybackMediaCache.cachedMusicSongs(values).single())
        assertEquals(1024, read(cacheOnly, synthetic, length = 1024).bytes.size)

        val uncataloged = factory(upstream, descriptor(listOf(resource(second, "eviction-fixture"))), second)
        assertEquals(size, drain(uncataloged, second))
        val opens = upstream.opens.get()
        assertTrue(PlaybackMediaCache.cachedMusicSongs(values).isEmpty())
        assertThrows(CachedMusicUnavailable::class.java) { read(cacheOnly, synthetic, length = 1024) }
        assertEquals(opens, upstream.opens.get())
    }

    private fun gatewayFixture(origin: String): Pair<GatewayContext, String> {
        // Fresh fixture-only v5-shaped identity; no existing browser/account slot is used.
        val key = UUID.randomUUID().toString().replaceRange(14, 15, "5")
        val marker = "v1.$key.${origin.encodeUtf8().base64Url()}"
        return GatewayContext.parse(marker) to marker
    }

    private fun removeGatewayFixture(gateway: GatewayContext) {
        val edit = context.getSharedPreferences("videre_gateway_sessions", Context.MODE_PRIVATE).edit()
        for (field in listOf("origin", "expired", "profile", "cancelledRevision", "pending", "pendingProfile", "revision")) {
            edit.remove("${field}_${gateway.key}")
        }
        assertTrue(edit.commit())
    }

    private class CountingFactory(private val resources: Map<String, ByteArray>,
                                  private val redirectedUri: String? = null) : DataSource.Factory {
        val opens = AtomicInteger()
        val bytes = AtomicLong()
        override fun createDataSource(): DataSource = object : DataSource {
            private var delegate: ByteArrayDataSource? = null
            override fun open(dataSpec: DataSpec): Long {
                opens.incrementAndGet()
                val data = resources[dataSpec.uri.path] ?: throw IOException("Unknown fixture")
                return ByteArrayDataSource(data).also { delegate = it }.open(dataSpec)
            }
            override fun read(buffer: ByteArray, offset: Int, length: Int): Int =
                checkNotNull(delegate).read(buffer, offset, length).also {
                    if (it > 0) bytes.addAndGet(it.toLong())
                }
            override fun getUri(): Uri? = redirectedUri?.let(Uri::parse) ?: delegate?.uri
            override fun getResponseHeaders(): Map<String, List<String>> = emptyMap()
            override fun addTransferListener(transferListener: TransferListener) = Unit
            override fun close() { delegate?.close(); delegate = null }
        }
    }

    /** Generates a large deterministic fixture without retaining it in the test heap. */
    private class PatternFactory(private val size: Long) : DataSource.Factory {
        val opens = AtomicInteger()
        override fun createDataSource(): DataSource = object : DataSource {
            private var position = 0L
            private var remaining = 0L
            private var currentUri: Uri? = null
            override fun open(dataSpec: DataSpec): Long {
                opens.incrementAndGet()
                currentUri = dataSpec.uri
                position = dataSpec.position
                if (position > size) throw IOException("Fixture range outside content")
                remaining = if (dataSpec.length == C.LENGTH_UNSET.toLong()) size - position
                    else minOf(dataSpec.length, size - position)
                return remaining
            }
            override fun read(buffer: ByteArray, offset: Int, length: Int): Int {
                if (length == 0) return 0
                if (remaining == 0L) return C.RESULT_END_OF_INPUT
                val count = minOf(length.toLong(), remaining).toInt()
                repeat(count) { buffer[offset + it] = ((position + it) % 251).toByte() }
                position += count
                remaining -= count
                return count
            }
            override fun getUri(): Uri? = currentUri
            override fun getResponseHeaders(): Map<String, List<String>> = emptyMap()
            override fun addTransferListener(transferListener: TransferListener) = Unit
            override fun close() { currentUri = null }
        }
    }
}
