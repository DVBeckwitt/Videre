package com.github.dvbeckwitt.videre.proxy

import android.content.Context
import android.net.Uri
import androidx.media3.common.C
import androidx.media3.database.StandaloneDatabaseProvider
import androidx.media3.datasource.DataSource
import androidx.media3.datasource.DataSpec
import androidx.media3.datasource.TransferListener
import androidx.media3.datasource.cache.Cache
import androidx.media3.datasource.cache.CacheDataSource
import androidx.media3.datasource.cache.CacheDataSink
import androidx.media3.datasource.cache.ContentMetadataMutations
import androidx.media3.datasource.cache.LeastRecentlyUsedCacheEvictor
import androidx.media3.datasource.cache.SimpleCache
import java.io.File
import java.io.IOException
import java.util.WeakHashMap
import java.util.concurrent.ArrayBlockingQueue
import java.util.concurrent.ThreadPoolExecutor
import java.util.concurrent.TimeUnit
import okhttp3.HttpUrl.Companion.toHttpUrlOrNull

/** Request roles are supplied by Media3's source factories, never inferred from an opaque child URL. */
enum class PlaybackCacheRequest {
    PROGRESSIVE,
    ADAPTIVE_MEDIA,
    ADAPTIVE_UNTYPED,
    BYPASS,
}

/** One private byte-span cache shared by both native players; never downloaded files. */
object PlaybackMediaCache {
    private const val DEFAULT_BYTES = 512L * 1024 * 1024
    private const val MIN_BYTES = 64L * 1024 * 1024
    private const val MAX_BYTES = 4L * 1024 * 1024 * 1024
    private val lock = Any()
    private var application: Context? = null
    private var enabled = true
    private var maxBytes = DEFAULT_BYTES
    private var generation = 0L
    private var transitioning = false
    private val profileGenerations = mutableMapOf<String, Long>()
    private val accountGenerations = mutableMapOf<String, Long>()
    private var cache: SimpleCache? = null
    private val readers = mutableSetOf<GuardedSource>()
    // Guarded by lock. Decoder callbacks may outlive their readers.
    private val pendingMusicProofs = WeakHashMap<MusicProof, String>()
    private val musicProofWriter = ThreadPoolExecutor(0, 1, 15L, TimeUnit.SECONDS,
        ArrayBlockingQueue(32), { task -> Thread(task, "Videre Music cache proof") },
        ThreadPoolExecutor.DiscardPolicy())

    internal fun initialize(context: Context) = synchronized(lock) {
        if (application != null) return@synchronized
        application = context.applicationContext
        val store = context.getSharedPreferences("videre_playback_cache", Context.MODE_PRIVATE)
        try {
            enabled = store.getBoolean("enabled", true)
            maxBytes = store.getLong("maxBytes", DEFAULT_BYTES).coerceIn(MIN_BYTES, MAX_BYTES)
        } catch (_: Exception) {
            // Corrupt optional cache settings must not prevent player startup.
            enabled = false
            maxBytes = DEFAULT_BYTES
        }
    }

    private fun cacheLocked(): SimpleCache {
        cache?.let { return it }
        val context = checkNotNull(application)
        val next = SimpleCache(File(context.cacheDir, "videre-playback-v1"),
            LeastRecentlyUsedCacheEvictor(maxBytes), StandaloneDatabaseProvider(context))
        try {
            next.checkInitialization()
            // Unidentified representations are reusable only within their originating run.
            next.keys.filter { it.startsWith("s:") }.forEach(next::removeResource)
            cache = next
            return next
        } catch (error: Exception) {
            next.release()
            throw error
        }
    }

    /** No raw URLs, redirect metadata, headers or credentials are written to the index. */
    private fun withoutRedirectMetadata(delegate: Cache): Cache = object : Cache by delegate {
        override fun applyContentMetadataMutations(key: String, mutations: ContentMetadataMutations) {
            ContentMetadataMutations.setRedirectedUri(mutations, null)
            delegate.applyContentMetadataMutations(key, mutations)
        }
    }

    @JvmStatic
    @JvmOverloads
    fun factory(context: Context, upstream: DataSource.Factory, sourceUri: String, values: Map<*, *>?,
                request: PlaybackCacheRequest = PlaybackCacheRequest.PROGRESSIVE,
                mediaCompanions: Map<*, *>? = null): DataSource.Factory {
        if (values == null && mediaCompanions == null) return upstream
        initialize(context)
        val companions = mediaCompanions?.let { MediaCompanions.parse(it, sourceUri) }
        val downloaded = DownloadedRenditionDescriptor.parse(values?.get("download"), sourceUri)
        require(companions == null || downloaded == null) { "Companion streaming requires a network source." }
        val networkUri = if (downloaded == null) sourceUri else downloaded.remoteUri
        val identity = values?.let { PlaybackCacheIdentity.parse(it, networkUri, companions) }
        val rendition = downloaded?.let { DownloadedRendition(context.applicationContext, checkNotNull(identity), it) }
        val admittedRequest = admittedRequest(request, values?.get("adaptiveVod"))
        val gateway = companions?.gateway ?: identity?.gateway
        val admission = ReaderAdmission(identity?.profileKey, gateway)
        val metadata = values?.get("musicSong")
        val proof = if (identity != null && downloaded == null && companions == null &&
            admittedRequest == PlaybackCacheRequest.PROGRESSIVE && metadata != null) {
            CachedMusicSong.fromSource(metadata, identity, sourceUri)?.let { MusicProof(it, admission) }
        } else null
        val sources = DataSource.Factory {
            GuardedSource(upstream, identity, admission, sourceUri, admittedRequest, rendition, companions,
                musicProof = proof)
        }
        return if (proof == null) sources else MusicAudioFactory(sources, proof)
    }

    /** Compatibility for callers without a typed adaptive request boundary. */
    @JvmStatic
    fun factory(context: Context, upstream: DataSource.Factory, sourceUri: String, values: Map<*, *>?, manifestSource: Boolean): DataSource.Factory =
        factory(context, upstream, sourceUri, values, if (manifestSource) PlaybackCacheRequest.ADAPTIVE_UNTYPED else PlaybackCacheRequest.PROGRESSIVE)

    /** Confirmation comes from Media3 after it selects audio and reaches READY. */
    @JvmStatic
    fun musicConfirmation(factory: DataSource.Factory): Runnable? =
        (factory as? MusicAudioFactory)?.let {
            Runnable { if (!it.proof.recorded) musicProofWriter.execute { confirmDecodedMusic(it) } }
        }

    internal fun confirmDecodedMusic(factory: DataSource.Factory) {
        (factory as? MusicAudioFactory)?.proof?.confirm()
    }

    /** Cache misses can only fail. There is no HTTP source or byte writer here. */
    @JvmStatic
    fun cachedMusicFactory(context: Context, sourceUri: String, value: Any?): DataSource.Factory {
        initialize(context)
        val selection = CachedMusicSelection.parse(value as? Map<*, *> ?: throw CachedMusicUnavailable(), sourceUri)
        val admission = ReaderAdmission(selection.owner.profileKey, selection.owner.gateway)
        return cachedMusicFactory(selection, admission)
    }

    private fun cachedMusicFactory(selection: CachedMusicSelection, admission: ReaderAdmission): DataSource.Factory =
        DataSource.Factory {
            GuardedSource(null, null, admission, selection.uri, PlaybackCacheRequest.PROGRESSIVE, null, null,
                cachedMusic = selection)
        }

    internal fun cachedMusicSongs(values: Map<*, *>): List<Map<String, Any>> {
        val owner = PlaybackCacheOwner.parse(values)
        val admission = ReaderAdmission(owner.profileKey, owner.gateway)
        admission.requireCurrent()
        return synchronized(lock) {
            admission.requireEpochLocked()
            if (!enabled) return@synchronized emptyList()
            val current = cacheLocked()
            val prefix = "p:${owner.profileKey}:"
            current.keys.asSequence().filter { it.startsWith(prefix) }.sorted()
                .mapNotNull { CachedMusicSong.complete(current, owner, it) }
                .distinctBy { it.selection.contentId }.map(CachedMusicSong::toMap).toList()
        }
    }

    internal fun removeCachedMusicSong(values: Map<*, *>): String {
        val selection = CachedMusicSelection.parse(values)
        val admission = ReaderAdmission(selection.owner.profileKey, selection.owner.gateway)
        admission.requireCurrent()
        return synchronized(lock) {
            admission.requireEpochLocked()
            if (!enabled) return@synchronized "missing"
            val current = cacheLocked()
            val key = selection.key
            if (!CachedMusicSong.hasCatalogEntry(current, selection) ||
                current.getCachedSpans(key).isEmpty()) return@synchronized "missing"
            if (readers.any { it.cacheKeyInUse == key }) return@synchronized "inUse"
            current.removeResource(key)
            pendingMusicProofs.entries.removeAll { it.value == key }
            "removed"
        }
    }

    /** Creates a private staging file from the exact, complete cache-only source. */
    internal fun copyCachedMusicSong(values: Map<*, *>): String? {
        val rendition = values["rendition"] as? String ?: return null
        val selection = try {
            CachedMusicSelection.parse(values, "videre-cache://music/$rendition")
        } catch (_: CachedMusicUnavailable) {
            return null
        }
        val admission = ReaderAdmission(selection.owner.profileKey, selection.owner.gateway)
        admission.requireCurrent()
        val length = synchronized(lock) {
            admission.requireEpochLocked()
            if (!enabled) return null
            CachedMusicSong.complete(cacheLocked(), selection.owner, selection.key)?.byteLength
        } ?: return null
        val request = DataSpec.Builder().setUri(selection.uri).setLength(length).build()
        val destination = File.createTempFile("videre-cached-song-", ".part", checkNotNull(application).cacheDir)
        var complete = false
        try {
            val source = cachedMusicFactory(selection, admission).createDataSource()
            try {
                val opened = try {
                    source.open(request)
                } catch (_: IOException) {
                    return null
                }
                if (opened != length) return null
                destination.outputStream().use { output ->
                    val buffer = ByteArray(64 * 1024)
                    var remaining = length
                    while (remaining > 0L) {
                        val count = try {
                            source.read(buffer, 0, minOf(remaining, buffer.size.toLong()).toInt())
                        } catch (_: IOException) {
                            return null
                        }
                        if (count <= 0) return null
                        output.write(buffer, 0, count)
                        remaining -= count
                    }
                }
            } finally {
                source.close()
            }
            complete = true
            return destination.absolutePath
        } finally {
            if (!complete) destination.delete()
        }
    }

    /** HLS playlists, encryption keys and every non-media request bypass the byte cache. */
    @JvmStatic
    fun requestForMedia3DataType(dataType: Int): PlaybackCacheRequest = when (dataType) {
        C.DATA_TYPE_MEDIA, C.DATA_TYPE_MEDIA_INITIALIZATION -> PlaybackCacheRequest.ADAPTIVE_MEDIA
        else -> PlaybackCacheRequest.BYPASS
    }

    // Missing live classification is not evidence of immutable segments.
    // Only positively identified VOD may cache previously unknown children;
    // other sources retain the earlier exact-representation-only behavior.
    internal fun admittedRequest(request: PlaybackCacheRequest, adaptiveVod: Any?): PlaybackCacheRequest =
        if (request == PlaybackCacheRequest.ADAPTIVE_MEDIA && adaptiveVod != true)
            PlaybackCacheRequest.ADAPTIVE_UNTYPED else request

    private fun requireLocalAuthorization(context: GatewayContext?) {
        if (context != null && isNerdVpnOrigin(context.origin)) {
            val state = NerdVpnAccess.status(context)["state"] as? String
            if (state != "ready") throw NerdVpnAccessRequired(state ?: "missing")
        }
    }

    /** Explicit key changes revoke readers without evicting another account. */
    internal fun revokeAccount(key: String) {
        val active = synchronized(lock) {
            accountGenerations[key] = (accountGenerations[key] ?: 0L) + 1
            readers.filter { it.accountKey == key }
        }
        if (active.isNotEmpty()) ProxyDataSource.cancelMediaCalls(key)
        active.forEach { try { it.close() } catch (_: IOException) {} }
    }

    internal fun closeRevokedCompanions(accounts: Set<MediaCompanionAccount>) {
        val active = synchronized(lock) { readers.filter { it.usesRevokedCompanion(accounts) } }
        active.forEach { try { it.close() } catch (_: IOException) {} }
    }

    /** Invalidates active readers before a profile, account or transport transition. */
    @JvmStatic
    fun invalidate() = transition { }

    private fun transition(operation: () -> Unit) {
        val active = synchronized(lock) {
            if (transitioning) throw IOException("Playback cache is changing.")
            transitioning = true
            generation++
            readers.toList()
        }
        // Closing the source is serialized against read/open to avoid releasing
        // a cache during a write. Cancel sockets first so teardown cannot wait
        // for the ordinary media read timeout.
        try {
            if (active.isNotEmpty()) ProxyDataSource.cancelMediaCalls()
            active.forEach { try { it.close() } catch (_: IOException) {} }
            synchronized(lock) { operation() }
        } finally {
            synchronized(lock) { transitioning = false }
        }
    }

    internal fun configure(values: Map<*, *>) {
        val nextEnabled = values["enabled"] as? Boolean ?: throw IllegalArgumentException()
        val nextBytes = (values["maxBytes"] as? Number)?.toLong() ?: throw IllegalArgumentException()
        require(nextBytes in MIN_BYTES..MAX_BYTES)
        transition {
            val context = checkNotNull(application)
            check(context.getSharedPreferences("videre_playback_cache", Context.MODE_PRIVATE).edit()
                .putBoolean("enabled", nextEnabled).putLong("maxBytes", nextBytes).commit())
            cache?.release()
            cache = null
            enabled = nextEnabled
            maxBytes = nextBytes
        }
    }

    internal fun clear() {
        transition { cacheLocked().let { current -> current.keys.toList().forEach(current::removeResource) } }
    }

    /** Deleting an inactive profile must not disturb another profile's playback. */
    internal fun removeProfile(profileId: String) = synchronized(lock) {
        if (transitioning) throw IOException("Playback cache is changing.")
        require(profileId.isNotEmpty() && profileId.length <= 4096)
        val profileKey = PlaybackCacheIdentity.digest(profileId)
        check(readers.none { it.profileKey == profileKey }) { "Stop this profile's playback before deleting it." }
        profileGenerations[profileKey] = (profileGenerations[profileKey] ?: 0L) + 1
        cacheLocked().let { current ->
            current.keys.filter { it.startsWith("p:$profileKey:") || it.startsWith("s:$profileKey:") }
                .forEach(current::removeResource)
        }
    }

    internal fun status(): Map<String, Any> = synchronized(lock) {
        mapOf("supported" to true, "enabled" to enabled, "maxBytes" to maxBytes,
            "usedBytes" to cacheLocked().cacheSpace)
    }

    private class ReaderAdmission(val profileKey: String?, val gateway: GatewayContext?) {
        val accountKey = gateway?.key
        private val gatewayRevision = gateway?.let(GatewaySessions::cacheAdmissionRevision)
        private val epochs: Triple<Long, Long, Long>

        init {
            requireLocalAuthorization(gateway)
            epochs = synchronized(lock) {
                if (transitioning) throw IOException("Playback cache is changing.")
                currentEpochs()
            }
        }

        private fun currentEpochs() = Triple(generation, profileGenerations[profileKey] ?: 0L,
            accountGenerations[accountKey] ?: 0L)

        fun requireEpochLocked() {
            if (transitioning || epochs.first != generation || epochs.second != (profileGenerations[profileKey] ?: 0L) ||
                epochs.third != (accountGenerations[accountKey] ?: 0L)) throw IOException("Playback context changed.")
        }

        fun requireCurrent() {
            // A cache hit must not evade failed startup/configuration admission.
            ProxyDataSource.configuration()
            gateway?.let {
                if (GatewaySessions.cacheAdmissionRevision(it) != gatewayRevision)
                    throw GatewayAuthenticationRequired()
            }
            synchronized(lock) { requireEpochLocked() }
        }
    }

    private class MusicAudioFactory(
        private val delegate: DataSource.Factory,
        val proof: MusicProof,
    ) : DataSource.Factory by delegate

    private class MusicProof(private val song: CachedMusicSong, private val admission: ReaderAdmission) {
        @Volatile private var opened: SimpleCache? = null
        @Volatile var recorded = false
            private set

        fun openedFrom(sourceCache: SimpleCache, key: String) {
            if (key != song.selection.key) return
            synchronized(lock) {
                opened = sourceCache
                if (!recorded) pendingMusicProofs[this] = key
            }
        }

        // The ordinary player is unaffected by optional catalog persistence.
        @Synchronized fun confirm() {
            val usedCache = opened ?: return
            if (recorded) return
            try {
                admission.requireCurrent()
                synchronized(lock) {
                    admission.requireEpochLocked()
                    if (enabled && usedCache === cache && this in pendingMusicProofs) {
                        song.recordIn(usedCache)
                        recorded = true
                        pendingMusicProofs.remove(this)
                    }
                }
            } catch (_: Exception) {}
        }
    }

    private class GuardedSource(
        private val upstream: DataSource.Factory?,
        private val identity: PlaybackCacheIdentity?,
        private val admission: ReaderAdmission,
        private val sourceUri: String,
        private val request: PlaybackCacheRequest,
        private val downloaded: DownloadedRendition?,
        private val companions: MediaCompanions?,
        private val musicProof: MusicProof? = null,
        private val cachedMusic: CachedMusicSelection? = null,
    ) : DataSource {
        val profileKey: String? get() = admission.profileKey
        val accountKey: String? get() = admission.accountKey
        // Guarded by lock, from source admission through completion of close.
        var cacheKeyInUse: String? = null
            private set
        @Volatile private var delegate: DataSource? = null
        private val listeners = mutableListOf<TransferListener>()

        fun usesRevokedCompanion(accounts: Set<MediaCompanionAccount>): Boolean = companions != null &&
            companions.account in accounts && !MediaCompanionGrants.isCurrent(companions)

        private fun admit() {
            companions?.let(MediaCompanionGrants::requireCurrent)
            admission.requireCurrent()
        }

        @Synchronized override fun open(dataSpec: DataSpec): Long {
            admit()
            requireLocalAuthorization(admission.gateway)
            val uri = dataSpec.uri.toString()
            if (downloaded != null && uri != sourceUri) throw LocalDownloadUnavailable()
            if (cachedMusic != null && (uri != sourceUri || dataSpec.httpMethod != DataSpec.HTTP_METHOD_GET ||
                dataSpec.httpBody != null)) throw CachedMusicUnavailable()
            // An in-origin URL may redirect to a companion. Bypass byte storage
            // for the entire opted-in source, including manifests and local URL
            // cache hits, but retain session admission on every open and read.
            companions?.requireDestination(uri.toHttpUrlOrNull() ?: throw SelectedOriginBlocked())
            val admittedKey = if (downloaded == null && companions == null) identity?.key(uri) else null
            // Typed chunk/media requests can safely use session-scoped unknown
            // child keys. Untyped adaptive requests may still be manifests or
            // keys, so preserve their conservative exact-resource admission.
            val key = when (request) {
                PlaybackCacheRequest.BYPASS -> null
                PlaybackCacheRequest.ADAPTIVE_UNTYPED -> if (uri == sourceUri || identity?.knownMediaResource(uri) != true) null else admittedKey
                PlaybackCacheRequest.PROGRESSIVE, PlaybackCacheRequest.ADAPTIVE_MEDIA -> admittedKey
            }
            var writingCache: SimpleCache? = null
            val selected = try { synchronized(lock) {
                admission.requireEpochLocked()
                readers.add(this)
                if (cachedMusic != null) {
                    cachedSource(cachedMusic, dataSpec).also { cacheKeyInUse = cachedMusic.key }
                } else if (downloaded != null) {
                    // A muxed saved rendition has its own byte offsets. It is
                    // always a complete progressive source, never cache spans
                    // under an original network representation's key.
                    downloaded.source(::admit)
                } else if (enabled && key != null && dataSpec.httpMethod == DataSpec.HTTP_METHOD_GET) {
                    // Evictable storage is optional. A disk/index failure may
                    // use only the same guarded upstream, after admission above.
                    val localCache = try { cacheLocked() } catch (_: Exception) { null }
                    if (localCache == null) checkNotNull(upstream).createDataSource() else {
                        writingCache = localCache
                        CacheDataSource.Factory().setCache(withoutRedirectMetadata(localCache))
                            .setUpstreamDataSourceFactory(checkNotNull(upstream))
                            .setCacheWriteDataSinkFactory(CacheDataSink.Factory().setCache(localCache)
                                .setFragmentSize(2L * 1024 * 1024))
                            .setCacheKeyFactory { key }
                            .setFlags(CacheDataSource.FLAG_IGNORE_CACHE_ON_ERROR)
                            .createDataSource().also { cacheKeyInUse = key }
                    }
                } else checkNotNull(upstream).createDataSource()
            } } catch (error: Exception) {
                releaseReader()
                throw error
            }
            delegate = selected
            return try {
                listeners.forEach(selected::addTransferListener)
                admit()
                val length = selected.open(if (selected is CacheDataSource && cachedMusic == null) dataSpec.buildUpon()
                    .setFlags(dataSpec.flags or DataSpec.FLAG_ALLOW_CACHE_FRAGMENTATION).build() else dataSpec)
                if (key != null && uri == sourceUri) writingCache?.let { musicProof?.openedFrom(it, key) }
                length
            } catch (error: Exception) {
                close()
                throw error
            }
        }

        private fun cachedSource(selection: CachedMusicSelection, dataSpec: DataSpec): DataSource {
            if (!enabled) throw CachedMusicUnavailable()
            val local = cacheLocked()
            val song = CachedMusicSong.complete(local, selection.owner, selection.key) ?: throw CachedMusicUnavailable()
            if (dataSpec.position !in 0..song.byteLength ||
                (dataSpec.length != C.LENGTH_UNSET.toLong() && dataSpec.length > song.byteLength - dataSpec.position)) {
                throw CachedMusicUnavailable()
            }
            return CacheDataSource.Factory().setCache(withoutRedirectMetadata(local))
                .setUpstreamDataSourceFactory(null).setCacheWriteDataSinkFactory(null)
                .setCacheKeyFactory { selection.key }.createDataSource()
        }

        @Synchronized override fun read(buffer: ByteArray, offset: Int, length: Int): Int {
            admit()
            return (delegate ?: throw IOException("Media source closed.")).read(buffer, offset, length)
        }
        override fun getUri(): Uri? = delegate?.uri
        override fun getResponseHeaders(): Map<String, List<String>> = delegate?.responseHeaders ?: emptyMap()
        override fun addTransferListener(transferListener: TransferListener) { listeners.add(transferListener) }
        @Synchronized override fun close() {
            val previous = delegate
            delegate = null
            try { previous?.close() } finally { releaseReader() }
        }

        private fun releaseReader() = synchronized(lock) {
            cacheKeyInUse = null
            readers.remove(this)
        }
    }
}
