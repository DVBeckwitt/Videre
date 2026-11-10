package ir.r3r.river_player

import android.content.Context
import androidx.media3.datasource.DataSource
import androidx.media3.datasource.cache.CacheDataSource
import androidx.media3.datasource.FileDataSource
import androidx.media3.datasource.cache.CacheDataSink
import androidx.media3.exoplayer.upstream.DefaultBandwidthMeter
import com.github.dvbeckwitt.videre.proxy.ProxyDataSource

internal class CacheDataSourceFactory(
    private val context: Context,
    private val maxCacheSize: Long,
    private val maxFileSize: Long,
    upstreamDataSource: DataSource.Factory?
) : DataSource.Factory {
    private var defaultDatasourceFactory: DataSource.Factory? = null
    override fun createDataSource(): CacheDataSource {
        val betterPlayerCache = RiverPlayerCache.createCache(context, maxCacheSize)
            ?: throw IllegalStateException("Cache can't be null.")

        return CacheDataSource(
            betterPlayerCache,
            defaultDatasourceFactory?.createDataSource(),
            FileDataSource(),
            CacheDataSink(betterPlayerCache, maxFileSize),
            CacheDataSource.FLAG_BLOCK_ON_CACHE or CacheDataSource.FLAG_IGNORE_CACHE_ON_ERROR,
            null
        )
    }

    init {
        val bandwidthMeter = DefaultBandwidthMeter.Builder(context).build()
        upstreamDataSource?.let {
            val sources = ProxyDataSource.withLocalSources(context, upstreamDataSource)
            defaultDatasourceFactory = DataSource.Factory {
                sources.createDataSource().apply { addTransferListener(bandwidthMeter) }
            }
        }
    }
}
