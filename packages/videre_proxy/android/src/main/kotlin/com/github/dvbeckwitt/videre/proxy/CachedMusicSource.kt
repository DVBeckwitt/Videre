package com.github.dvbeckwitt.videre.proxy

import androidx.media3.datasource.cache.ContentMetadata
import androidx.media3.datasource.cache.ContentMetadataMutations
import androidx.media3.datasource.cache.SimpleCache
import java.io.IOException
import org.json.JSONArray

class CachedMusicUnavailable : IOException("The song is no longer available in the playback cache.")

private val contentIdPattern = Regex("[A-Za-z0-9_-]{1,128}")
private val renditionPattern = Regex("[0-9a-f]{64}")

/** An exact representation selection with no request URL or authorization header. */
internal data class CachedMusicSelection(
    val owner: PlaybackCacheOwner,
    val contentId: String,
    val rendition: String,
) {
    val uri = "videre-cache://music/$rendition"
    val key = owner.persistentKey(contentId, rendition)

    companion object {
        fun parse(values: Map<*, *>, uri: String): CachedMusicSelection {
            val contentId = values["contentId"] as? String ?: throw CachedMusicUnavailable()
            val rendition = values["rendition"] as? String ?: throw CachedMusicUnavailable()
            if (!contentIdPattern.matches(contentId) || !renditionPattern.matches(rendition)) {
                throw CachedMusicUnavailable()
            }
            return CachedMusicSelection(PlaybackCacheOwner.parse(values), contentId, rendition)
                .also { if (it.uri != uri) throw CachedMusicUnavailable() }
        }
    }
}

/** Decoder-confirmed Music metadata kept on the evictable representation itself. */
internal data class CachedMusicSong(
    val selection: CachedMusicSelection,
    val title: String,
    val artist: String,
    val lengthSeconds: Int,
    val byteLength: Long,
) {
    fun recordIn(cache: SimpleCache) {
        cache.applyContentMetadataMutations(selection.key, ContentMetadataMutations()
            .set(OWNER, selection.owner.catalogKey)
            .set(CONTENT, selection.contentId)
            .set(TITLE, title)
            .set(ARTIST, artist)
            .set(DURATION, lengthSeconds.toLong())
            .set(SIZE, byteLength))
    }

    fun toMap(): Map<String, Any> = mapOf(
        "videoId" to selection.contentId,
        "title" to title,
        "artist" to artist,
        "lengthSeconds" to lengthSeconds,
        "rendition" to selection.rendition,
    )

    companion object {
        private const val OWNER = "videre.music.owner"
        private const val CONTENT = "videre.music.content"
        private const val TITLE = "videre.music.title"
        private const val ARTIST = "videre.music.artist"
        private const val DURATION = "videre.music.duration"
        private const val SIZE = "videre.music.size"
        private const val MAX_DURATION_SECONDS = 604800L
        private const val MAX_BYTES = 4L * 1024 * 1024 * 1024
        private val controls = Regex("[\\x00-\\x1f\\x7f]")

        fun fromSource(value: Any?, identity: PlaybackCacheIdentity, uri: String): CachedMusicSong? {
            val fields = value as? Map<*, *> ?: return null
            val contentId = identity.contentId.takeIf(contentIdPattern::matches) ?: return null
            val title = text(fields["title"])?.takeIf(String::isNotEmpty) ?: return null
            val artist = text(fields["artist"]) ?: return null
            val duration = boundedInteger(fields["lengthSeconds"], 0L..MAX_DURATION_SECONDS) ?: return null
            val size = boundedInteger(fields["byteLength"], 1L..MAX_BYTES) ?: return null
            val representation = identity.persistentRepresentation(uri) ?: return null
            // Match the immutable representation's declared filesize, rather than
            // treating an arbitrary ranged response as the whole song.
            val key = runCatching { JSONArray(representation) }.getOrNull() ?: return null
            if (key.length() != 7 || key.optString(0) != "representation" ||
                key.optString(2).toLongOrNull() != size) return null
            val selection = CachedMusicSelection(identity.owner, contentId,
                PlaybackCacheIdentity.digest(representation))
            return CachedMusicSong(selection, title, artist, duration.toInt(), size)
        }

        fun complete(cache: SimpleCache, owner: PlaybackCacheOwner, key: String): CachedMusicSong? {
            val values = cache.getContentMetadata(key)
            if (values.get(OWNER, "") != owner.catalogKey) return null
            val content = values.get(CONTENT, "") ?: return null
            val rendition = key.substringAfterLast(':')
            if (!contentIdPattern.matches(content) || !renditionPattern.matches(rendition)) return null
            val selection = CachedMusicSelection(owner, content, rendition)
            if (selection.key != key) return null
            val title = text(values.get(TITLE, ""))?.takeIf(String::isNotEmpty) ?: return null
            val artist = text(values.get(ARTIST, "")) ?: return null
            val duration = values.get(DURATION, -1L)
            val size = values.get(SIZE, -1L)
            if (duration !in 0L..MAX_DURATION_SECONDS || size !in 1L..MAX_BYTES ||
                ContentMetadata.getContentLength(values) != size || !cache.isCached(key, 0L, size)) return null
            val spans = cache.getCachedSpans(key)
            if (spans.isEmpty() || spans.any { it.file?.length() != it.length }) return null
            return CachedMusicSong(selection, title, artist, duration.toInt(), size)
        }

        private fun text(value: Any?): String? = (value as? String)
            ?.take(1024)?.replace(controls, " ")?.trim()

        private fun boundedInteger(value: Any?, range: LongRange): Long? {
            val number = value as? Number ?: return null
            val long = number.toLong()
            return long.takeIf { it in range && number.toDouble() == it.toDouble() }
        }
    }
}
