package com.github.dvbeckwitt.videre

import android.app.PendingIntent
import android.appwidget.AppWidgetManager
import android.appwidget.AppWidgetProvider
import android.content.ComponentName
import android.content.Context
import android.content.Intent
import android.net.Uri
import android.os.Build
import android.os.Bundle
import android.util.SizeF
import android.view.View
import android.widget.RemoteViews
import io.flutter.embedding.engine.plugins.FlutterPlugin
import io.flutter.plugin.common.MethodChannel

class MusicHomeWidgetProvider : AppWidgetProvider() {
    override fun onUpdate(context: Context, manager: AppWidgetManager, ids: IntArray) {
        MusicWidget.updateWidgets(context, manager, ids)
    }

    override fun onAppWidgetOptionsChanged(
        context: Context,
        manager: AppWidgetManager,
        id: Int,
        newOptions: Bundle?,
    ) {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.S) {
            manager.updateAppWidget(id, MusicWidget.legacyViews(context, newOptions))
        }
    }

    override fun onReceive(context: Context, intent: Intent) {
        if (intent.action == MusicWidget.TRANSPORT) {
            MusicWidget.transport(context, intent.data)
        } else {
            super.onReceive(context, intent)
        }
    }
}

/** Keep the widget connected to AudioService's engine across Activity recreation. */
internal class MusicHomeWidgetPlugin : FlutterPlugin {
    companion object {
        fun isSaveIntent(intent: Intent): Boolean = intent.action == MusicWidget.SAVE

        fun handleSaveIntent(context: Context, intent: Intent) =
            MusicWidget.save(context, intent.data)
    }

    private lateinit var channel: MethodChannel
    private val lyricsWidget = MusicLyricsWidgetBridge()

    override fun onAttachedToEngine(binding: FlutterPlugin.FlutterPluginBinding) {
        lyricsWidget.attach(binding)
        val context = binding.applicationContext
        channel = MethodChannel(binding.binaryMessenger, "videre/music_home_widget")
        MusicWidget.channel = channel
        MusicWidget.setPlayback(context, null)
        channel.setMethodCallHandler { call, result ->
            if (call.method == "setPlayback") {
                MusicWidget.setPlayback(context, call.arguments as? Map<*, *>)
                result.success(null)
            } else {
                result.notImplemented()
            }
        }
    }

    override fun onDetachedFromEngine(binding: FlutterPlugin.FlutterPluginBinding) {
        lyricsWidget.detach(binding)
        channel.setMethodCallHandler(null)
        if (MusicWidget.channel === channel) {
            MusicWidget.channel = null
            MusicWidget.setPlayback(binding.applicationContext, null)
        }
    }
}

private object MusicWidget {
    const val TRANSPORT = "com.github.dvbeckwitt.videre.music_widget.TRANSPORT"
    const val SAVE = "com.github.dvbeckwitt.videre.music_widget.SAVE"
    private const val INTENT_FLAGS = PendingIntent.FLAG_IMMUTABLE

    // Snapshot metadata stays in memory and is reestablished by the live player.
    private data class Playback(
        val token: String,
        val title: String,
        val artist: String,
        val status: String?,
        val playAction: String?,
        val canPrevious: Boolean,
        val canNext: Boolean,
        val canSave: Boolean,
        val liked: Boolean?,
        val likeToken: String?,
        val shuffleSelected: Boolean,
        val shuffleToken: String?,
    )

    var channel: MethodChannel? = null
    private var playback: Playback? = null
    private val artwork = MusicWidgetArtwork()

    fun setPlayback(context: Context, arguments: Map<*, *>?) {
        val token = arguments?.get("token") as? String
        playback = if (arguments != null && token != null) {
            Playback(
                token = token,
                title = (arguments["title"] as? String).orEmpty().take(512),
                artist = (arguments["artist"] as? String).orEmpty().take(512),
                status = arguments["status"] as? String,
                playAction = arguments["playAction"] as? String,
                canPrevious = arguments["canPrevious"] == true,
                canNext = arguments["canNext"] == true,
                canSave = arguments["canSave"] == true,
                liked = arguments["liked"] as? Boolean,
                likeToken = arguments["likeToken"] as? String,
                shuffleSelected = arguments["shuffleSelected"] == true,
                shuffleToken = arguments["shuffleToken"] as? String,
            )
        } else null
        artwork.setSource(playback?.token, arguments?.get("artworkPath") as? String)
        update(context)
    }

    fun transport(context: Context, data: Uri?) {
        val current = playback
        val (token, action) = data?.pathSegments?.takeIf { it.size == 2 } ?: return
        val activeToken = when (action) {
            "like", "unlike" -> current?.likeToken
            "shuffle" -> current?.shuffleToken
            else -> current?.token
        }
        if (current == null || token != activeToken) {
            // A launcher may retain a view when the process was killed.
            update(context)
            return
        }
        val enabled = when (action) {
            "play", "pause" -> action == current.playAction
            "previous" -> current.canPrevious
            "next" -> current.canNext
            "like" -> current.liked == false
            "unlike" -> current.liked == true
            "shuffle" -> true
            else -> false
        }
        if (enabled) {
            dispatch(token, action)
        }
    }

    fun save(context: Context, data: Uri?) {
        val current = playback
        val token = data?.pathSegments?.singleOrNull() ?: return
        if (current == null || current.token != token) {
            update(context)
            return
        }
        if (current.canSave) dispatch(token, "save")
    }

    private fun dispatch(token: String, action: String) {
        channel?.invokeMethod("transport", mapOf("token" to token, "action" to action))
    }

    private fun update(context: Context) {
        val manager = AppWidgetManager.getInstance(context)
        val ids = manager.getAppWidgetIds(ComponentName(context, MusicHomeWidgetProvider::class.java))
        updateWidgets(context, manager, ids)
    }

    fun updateWidgets(context: Context, manager: AppWidgetManager, ids: IntArray) {
        if (ids.isEmpty()) return
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.S) {
            val layouts = MusicWidgetLayout.entries.associate { layout ->
                SizeF(layout.minWidth.toFloat(), layout.minHeight.toFloat()) to views(context, layout)
            }
            manager.updateAppWidget(ids, RemoteViews(layouts))
        } else {
            for (id in ids) {
                manager.updateAppWidget(id, legacyViews(context, manager.getAppWidgetOptions(id)))
            }
        }
    }

    fun legacyViews(context: Context, options: Bundle?): RemoteViews {
        // Legacy launchers report the portrait and landscape bounds as a range.
        val portrait = MusicWidgetLayout.forSize(
            options?.getInt(AppWidgetManager.OPTION_APPWIDGET_MIN_WIDTH) ?: 0,
            options?.getInt(AppWidgetManager.OPTION_APPWIDGET_MAX_HEIGHT) ?: 0,
        )
        val landscape = MusicWidgetLayout.forSize(
            options?.getInt(AppWidgetManager.OPTION_APPWIDGET_MAX_WIDTH) ?: 0,
            options?.getInt(AppWidgetManager.OPTION_APPWIDGET_MIN_HEIGHT) ?: 0,
        )
        val portraitViews = views(context, portrait)
        return if (landscape == portrait) portraitViews else {
            RemoteViews(views(context, landscape), portraitViews)
        }
    }

    private fun views(context: Context, layout: MusicWidgetLayout): RemoteViews {
        val current = playback
        val title = when {
            current == null -> context.getString(R.string.music_widget_name)
            current.title.isBlank() -> context.getString(R.string.music_widget_unknown_title)
            else -> current.title
        }
        val artist = current?.artist ?: context.getString(R.string.music_widget_open)
        val status = when (current?.status) {
            "loading" -> R.string.music_widget_loading
            "buffering" -> R.string.music_widget_buffering
            "playing" -> R.string.music_widget_playing
            "paused" -> R.string.music_widget_paused
            "ended" -> R.string.music_widget_ended
            "unavailable" -> R.string.music_widget_unavailable
            else -> R.string.music_widget_idle
        }
        val statusText = context.getString(status)
        val needsVisibleStatus = when (current?.status) {
            "loading", "buffering", "ended", "unavailable" -> true
            else -> false
        }
        // Leave room for the fixed transport targets when text is enlarged.
        // The accessible description keeps the full track and playback state.
        val fontScale = context.resources.configuration.fontScale
        val showStatusLine = layout.hasStatusLine && current != null && fontScale <= 1.15f
        val subtitleFontLimit = if (layout.hasStatusLine) 1.55f else 1.25f
        val subtitle = when {
            current == null || showStatusLine -> artist
            needsVisibleStatus || artist.isBlank() -> statusText
            else -> artist
        }
        val showSubtitle = subtitle.isNotBlank() && fontScale <= subtitleFontLimit
        val open = Intent(Intent.ACTION_MAIN).setClass(context, MainActivity::class.java)
            .addFlags(Intent.FLAG_ACTIVITY_NEW_TASK or Intent.FLAG_ACTIVITY_SINGLE_TOP)
        val save = current?.takeIf { it.canSave }?.let {
            val intent = Intent(SAVE, tokenUri(it.token).build(), context, MainActivity::class.java)
                .addFlags(Intent.FLAG_ACTIVITY_NEW_TASK or Intent.FLAG_ACTIVITY_SINGLE_TOP)
            PendingIntent.getActivity(context, 0, intent, INTENT_FLAGS)
        }
        val pause = current?.playAction == "pause"
        return RemoteViews(context.packageName, layout.resourceId).apply {
            artwork.bind(this, current != null) { update(context) }
            setTextViewText(R.id.music_widget_title, title)
            setTextViewText(R.id.music_widget_artist, subtitle)
            setViewVisibility(R.id.music_widget_artist, if (showSubtitle) View.VISIBLE else View.GONE)
            setTextViewText(R.id.music_widget_status, statusText)
            setViewVisibility(R.id.music_widget_status, if (showStatusLine) View.VISIBLE else View.GONE)
            val description = if (current == null) {
                context.getString(R.string.music_widget_open)
            } else {
                val track = if (artist.isBlank()) title else {
                    context.getString(R.string.music_widget_track_artist, title, artist)
                }
                context.getString(R.string.music_widget_track_status, track, statusText)
            }
            setContentDescription(R.id.music_widget_item, description)
            setOnClickPendingIntent(R.id.music_widget_item, PendingIntent.getActivity(context, 0, open, INTENT_FLAGS))
            setViewVisibility(R.id.music_widget_save, if (save == null) View.GONE else View.VISIBLE)
            setOnClickPendingIntent(R.id.music_widget_save, save)
            bindLike(context, current)
            setViewVisibility(R.id.music_widget_controls, if (current == null) View.GONE else View.VISIBLE)
            setImageViewResource(
                R.id.music_widget_toggle,
                if (pause) R.drawable.music_widget_pause else R.drawable.music_widget_play,
            )
            setContentDescription(
                R.id.music_widget_toggle,
                context.getString(if (pause) R.string.music_widget_pause else R.string.music_widget_play),
            )
            setControl(context, R.id.music_widget_previous, current?.token, "previous".takeIf { current?.canPrevious == true })
            setControl(context, R.id.music_widget_toggle, current?.token, current?.playAction)
            setControl(context, R.id.music_widget_next, current?.token, "next".takeIf { current?.canNext == true })
            if (layout.hasExtraActions) {
                val shuffleSelected = current?.shuffleSelected == true
                setImageViewResource(
                    R.id.music_widget_shuffle,
                    if (shuffleSelected) R.drawable.music_widget_shuffle_on else R.drawable.music_widget_shuffle,
                )
                setContentDescription(
                    R.id.music_widget_shuffle,
                    context.getString(if (shuffleSelected) R.string.music_widget_shuffle_on else R.string.music_widget_shuffle_off),
                )
                setViewVisibility(R.id.music_widget_shuffle, if (current == null) View.GONE else View.VISIBLE)
                setControl(context, R.id.music_widget_shuffle, current?.shuffleToken, "shuffle")
            }
        }
    }

    private fun RemoteViews.bindLike(context: Context, playback: Playback?) {
        val liked = playback?.takeIf { it.likeToken != null }?.liked
        val action = when (liked) {
            true -> "unlike"
            false -> "like"
            null -> null
        }
        setViewVisibility(R.id.music_widget_like, if (action == null) View.GONE else View.VISIBLE)
        setImageViewResource(
            R.id.music_widget_like,
            if (liked == true) R.drawable.music_widget_liked else R.drawable.music_widget_like,
        )
        setContentDescription(
            R.id.music_widget_like,
            context.getString(if (liked == true) R.string.music_widget_unlike else R.string.music_widget_like),
        )
        setControl(context, R.id.music_widget_like, playback?.likeToken, action)
    }

    private fun RemoteViews.setControl(context: Context, id: Int, token: String?, action: String?) {
        val click = if (token == null || action == null) null else {
            val data = tokenUri(token).appendPath(action).build()
            val intent = Intent(TRANSPORT, data, context, MusicHomeWidgetProvider::class.java)
            PendingIntent.getBroadcast(context, 0, intent, INTENT_FLAGS)
        }
        setOnClickPendingIntent(id, click)
        setBoolean(id, "setEnabled", click != null)
        setInt(id, "setImageAlpha", if (click == null) 100 else 255)
    }

    private fun tokenUri(token: String) = Uri.Builder()
        .scheme("videre-music-widget").appendPath(token)
}
