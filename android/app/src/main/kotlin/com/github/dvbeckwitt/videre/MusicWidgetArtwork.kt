package com.github.dvbeckwitt.videre

import android.graphics.Bitmap
import android.graphics.BitmapFactory
import android.os.Handler
import android.os.Looper
import android.view.View
import android.widget.RemoteViews
import java.util.concurrent.Future
import java.util.concurrent.LinkedBlockingQueue
import java.util.concurrent.ThreadPoolExecutor
import java.util.concurrent.TimeUnit

/** Decodes artwork off the main thread and keeps one launcher-sized image in memory. */
internal class MusicWidgetArtwork {
    private data class Source(val token: String, val path: String)

    private val main = Handler(Looper.getMainLooper())
    private val decoder = ThreadPoolExecutor(1, 1, 0, TimeUnit.SECONDS, LinkedBlockingQueue())
    private var source: Source? = null
    private var bitmap: Bitmap? = null
    private var request: Future<*>? = null

    fun setSource(token: String?, path: String?) {
        val next = if (token != null && !path.isNullOrBlank()) Source(token, path) else null
        if (next == source) return
        source = next
        bitmap = null
        request?.cancel(false)
        decoder.purge()
        request = null
    }

    fun bind(views: RemoteViews, hasPlayback: Boolean, onLoaded: () -> Unit) {
        val image = bitmap
        val id = R.id.music_widget_artwork
        views.setViewVisibility(id, if (hasPlayback) View.VISIBLE else View.GONE)
        if (image == null) {
            views.setImageViewResource(id, R.drawable.music_widget_artwork_fallback)
        } else {
            views.setImageViewBitmap(id, image)
        }

        val current = source ?: return
        if (request != null) return
        request = decoder.submit {
            val decoded = decode(current.path)
            main.post {
                if (source === current && decoded != null) {
                    bitmap = decoded
                    onLoaded()
                }
            }
        }
    }

    private fun decode(path: String): Bitmap? {
        val options = BitmapFactory.Options().apply { inJustDecodeBounds = true }
        BitmapFactory.decodeFile(path, options)
        if (options.outWidth <= 0 || options.outHeight <= 0) return null
        val longest = maxOf(options.outWidth, options.outHeight)
        var sample = 1
        while ((longest - 1) / sample >= MAX_SIDE_PX) sample *= 2
        options.inSampleSize = sample
        options.inJustDecodeBounds = false
        return BitmapFactory.decodeFile(path, options)
    }

    private companion object {
        const val MAX_SIDE_PX = 256
    }
}
