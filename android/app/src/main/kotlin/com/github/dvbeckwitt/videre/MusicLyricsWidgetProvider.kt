package com.github.dvbeckwitt.videre

import android.app.PendingIntent
import android.appwidget.AppWidgetManager
import android.appwidget.AppWidgetProvider
import android.content.ComponentName
import android.content.Context
import android.content.Intent
import android.graphics.Typeface
import android.net.Uri
import android.text.SpannableString
import android.text.Spanned
import android.text.style.StyleSpan
import android.view.View
import android.widget.RemoteViews
import io.flutter.embedding.engine.plugins.FlutterPlugin
import io.flutter.plugin.common.MethodChannel

class MusicLyricsWidgetProvider : AppWidgetProvider() {
    override fun onUpdate(context: Context, manager: AppWidgetManager, ids: IntArray) {
        if (ids.isNotEmpty()) manager.updateAppWidget(ids, MusicLyricsWidget.views(context))
    }

    override fun onReceive(context: Context, intent: Intent) {
        if (intent.action == MusicLyricsWidget.SEEK) {
            MusicLyricsWidget.seek(context, intent.data)
        } else {
            super.onReceive(context, intent)
        }
    }
}

/** Uses the same retained engine as the Music playback widget. */
internal class MusicLyricsWidgetBridge {
    private lateinit var channel: MethodChannel

    fun attach(binding: FlutterPlugin.FlutterPluginBinding) {
        val context = binding.applicationContext
        channel = MethodChannel(binding.binaryMessenger, "videre/music_lyrics_widget")
        MusicLyricsWidget.channel = channel
        MusicLyricsWidget.setLyrics(context, null)
        channel.setMethodCallHandler { call, result ->
            if (call.method == "setLyrics") {
                if (MusicLyricsWidget.channel === channel) {
                    MusicLyricsWidget.setLyrics(context, call.arguments as? Map<*, *>)
                }
                result.success(null)
            } else {
                result.notImplemented()
            }
        }
    }

    fun detach(binding: FlutterPlugin.FlutterPluginBinding) {
        channel.setMethodCallHandler(null)
        if (MusicLyricsWidget.channel === channel) {
            MusicLyricsWidget.channel = null
            MusicLyricsWidget.setLyrics(binding.applicationContext, null)
        }
    }
}

private object MusicLyricsWidget {
    const val SEEK = "com.github.dvbeckwitt.videre.music_lyrics_widget.SEEK"
    private const val URI_SCHEME = "videre-music-lyrics-widget"
    private val cueRows = intArrayOf(
        R.id.music_lyrics_widget_first,
        R.id.music_lyrics_widget_second,
        R.id.music_lyrics_widget_third,
    )

    private data class Cue(val text: String, val positionMs: Long, val active: Boolean)
    private data class Snapshot(val token: String, val title: String, val cues: List<Cue>)

    var channel: MethodChannel? = null

    // The live engine owns the cue window. The launcher may cache old
    // RemoteViews, so reject their intents whenever the live token changes.
    private var snapshot: Snapshot? = null

    fun setLyrics(context: Context, arguments: Map<*, *>?) {
        snapshot = readSnapshot(arguments)
        update(context)
    }

    private fun readSnapshot(arguments: Map<*, *>?): Snapshot? {
        if (arguments == null) return null
        val token = (arguments["token"] as? String)?.takeIf { it.isNotBlank() } ?: return null
        val title = (arguments["title"] as? String).orEmpty().take(512)
        val cues = (arguments["cues"] as? List<*>).orEmpty().take(cueRows.size).mapNotNull { entry ->
            val cue = entry as? Map<*, *> ?: return@mapNotNull null
            val text = (cue["text"] as? String)?.take(512)?.takeIf { it.isNotBlank() }
                ?: return@mapNotNull null
            val positionMs = when (val position = cue["positionMs"]) {
                is Int -> position.toLong()
                is Long -> position
                else -> return@mapNotNull null
            }
            if (positionMs < 0) return@mapNotNull null
            Cue(text, positionMs, cue["active"] == true)
        }
        return Snapshot(token, title, cues)
    }

    fun seek(context: Context, data: Uri?) {
        if (data?.scheme != URI_SCHEME) return
        val (token, position) = data.pathSegments.takeIf { it.size == 2 } ?: return
        val positionMs = position.toLongOrNull()?.takeIf { it >= 0 } ?: return
        val current = snapshot
        val liveChannel = channel
        if (current == null || current.token != token || current.cues.isEmpty() || liveChannel == null) {
            update(context)
            return
        }

        // A cue can leave the visible window while the tap is in flight. Dart
        // verifies the position against the live occurrence and synced timings.
        liveChannel.invokeMethod("seek", mapOf("token" to token, "positionMs" to positionMs))
    }

    private fun update(context: Context) {
        val manager = AppWidgetManager.getInstance(context)
        val ids = manager.getAppWidgetIds(ComponentName(context, MusicLyricsWidgetProvider::class.java))
        if (ids.isNotEmpty()) manager.updateAppWidget(ids, views(context))
    }

    fun views(context: Context): RemoteViews {
        val current = snapshot
        val title = when {
            current == null -> context.getString(R.string.music_lyrics_widget_name)
            current.title.isBlank() -> context.getString(R.string.music_widget_unknown_title)
            else -> current.title
        }
        val message = when {
            current == null -> context.getString(R.string.music_lyrics_widget_idle)
            current.cues.isEmpty() -> context.getString(R.string.music_lyrics_widget_unavailable)
            else -> null
        }
        return RemoteViews(context.packageName, R.layout.music_lyrics_widget).apply {
            setTextViewText(R.id.music_lyrics_widget_title, title)
            setTextViewText(R.id.music_lyrics_widget_status, message)
            setViewVisibility(R.id.music_lyrics_widget_status, if (message == null) View.GONE else View.VISIBLE)
            cueRows.forEachIndexed { index, viewId ->
                val cue = current?.cues?.getOrNull(index)
                if (current == null || cue == null) {
                    setViewVisibility(viewId, View.GONE)
                    setTextViewText(viewId, null)
                    setOnClickPendingIntent(viewId, null)
                    setContentDescription(viewId, null)
                } else {
                    bindCue(context, viewId, current.token, cue)
                }
            }
        }
    }

    private fun RemoteViews.bindCue(context: Context, viewId: Int, token: String, cue: Cue) {
        val data = Uri.Builder().scheme(URI_SCHEME)
            .appendPath(token)
            .appendPath(cue.positionMs.toString())
            .build()
        val intent = Intent(SEEK, data, context, MusicLyricsWidgetProvider::class.java)
        val click = PendingIntent.getBroadcast(context, 0, intent, PendingIntent.FLAG_IMMUTABLE)
        val label = if (cue.active) SpannableString(cue.text).apply {
            setSpan(StyleSpan(Typeface.BOLD), 0, length, Spanned.SPAN_EXCLUSIVE_EXCLUSIVE)
        } else cue.text
        val textColor = if (cue.active) R.color.music_lyrics_widget_active else R.color.music_lyrics_widget_cue
        val description = if (cue.active) R.string.music_lyrics_widget_seek_current else R.string.music_lyrics_widget_seek
        val maxLines = if (context.resources.configuration.fontScale > 1.25f) 1 else 2
        setViewVisibility(viewId, View.VISIBLE)
        setTextViewText(viewId, label)
        setTextColor(viewId, context.getColor(textColor))
        setInt(viewId, "setMaxLines", maxLines)
        setContentDescription(viewId, context.getString(description, cue.text))
        setOnClickPendingIntent(viewId, click)
    }
}
