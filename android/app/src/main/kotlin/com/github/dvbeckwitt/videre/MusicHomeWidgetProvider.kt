package com.github.dvbeckwitt.videre

import android.app.PendingIntent
import android.appwidget.AppWidgetManager
import android.appwidget.AppWidgetProvider
import android.content.ComponentName
import android.content.Context
import android.content.Intent
import android.net.Uri
import android.view.View
import android.widget.RemoteViews
import io.flutter.embedding.engine.plugins.FlutterPlugin
import io.flutter.plugin.common.MethodChannel

class MusicHomeWidgetProvider : AppWidgetProvider() {
    override fun onUpdate(context: Context, manager: AppWidgetManager, ids: IntArray) {
        manager.updateAppWidget(ids, MusicWidget.views(context))
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

    override fun onAttachedToEngine(binding: FlutterPlugin.FlutterPluginBinding) {
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

    // The launcher gets display text and opaque click tokens only. Snapshot
    // metadata stays in memory and is reestablished by the live player.
    private data class Playback(
        val token: String,
        val title: String,
        val artist: String,
        val status: String?,
        val playAction: String?,
        val canPrevious: Boolean,
        val canNext: Boolean,
        val canSave: Boolean,
    )

    var channel: MethodChannel? = null
    private var playback: Playback? = null

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
            )
        } else null
        update(context)
    }

    fun transport(context: Context, data: Uri?) {
        val current = playback
        val (token, action) = data?.pathSegments?.takeIf { it.size == 2 } ?: return
        if (current == null || current.token != token) {
            // A launcher may retain a view when the process was killed.
            update(context)
            return
        }
        val enabled = when (action) {
            "play", "pause" -> action == current.playAction
            "previous" -> current.canPrevious
            "next" -> current.canNext
            else -> false
        }
        if (enabled) {
            dispatch(current, action)
        }
    }

    fun save(context: Context, data: Uri?) {
        val current = playback
        val token = data?.pathSegments?.singleOrNull() ?: return
        if (current == null || current.token != token) {
            update(context)
            return
        }
        if (current.canSave) dispatch(current, "save")
    }

    private fun dispatch(current: Playback, action: String) {
        channel?.invokeMethod("transport", mapOf("token" to current.token, "action" to action))
    }

    private fun update(context: Context) {
        val manager = AppWidgetManager.getInstance(context)
        val ids = manager.getAppWidgetIds(ComponentName(context, MusicHomeWidgetProvider::class.java))
        if (ids.isNotEmpty()) manager.updateAppWidget(ids, views(context))
    }

    fun views(context: Context): RemoteViews {
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
        val open = Intent(Intent.ACTION_MAIN).setClass(context, MainActivity::class.java)
            .addFlags(Intent.FLAG_ACTIVITY_NEW_TASK or Intent.FLAG_ACTIVITY_SINGLE_TOP)
        val save = current?.takeIf { it.canSave }?.let {
            val intent = Intent(SAVE, tokenUri(it.token).build(), context, MainActivity::class.java)
                .addFlags(Intent.FLAG_ACTIVITY_NEW_TASK or Intent.FLAG_ACTIVITY_SINGLE_TOP)
            PendingIntent.getActivity(context, 0, intent, INTENT_FLAGS)
        }
        val pause = current?.playAction == "pause"
        return RemoteViews(context.packageName, R.layout.music_home_widget).apply {
            setTextViewText(R.id.music_widget_title, title)
            setTextViewText(R.id.music_widget_artist, artist)
            setViewVisibility(R.id.music_widget_artist, if (artist.isBlank()) View.GONE else View.VISIBLE)
            setTextViewText(R.id.music_widget_status, context.getString(status))
            val description = when {
                current == null -> context.getString(R.string.music_widget_open)
                artist.isBlank() -> title
                else -> context.getString(R.string.music_widget_track_artist, title, artist)
            }
            setContentDescription(R.id.music_widget_item, description)
            setOnClickPendingIntent(R.id.music_widget_item, PendingIntent.getActivity(context, 0, open, INTENT_FLAGS))
            setViewVisibility(R.id.music_widget_save, if (save == null) View.GONE else View.VISIBLE)
            setOnClickPendingIntent(R.id.music_widget_save, save)
            setViewVisibility(R.id.music_widget_controls, if (current == null) View.GONE else View.VISIBLE)
            setImageViewResource(
                R.id.music_widget_toggle,
                if (pause) R.drawable.music_widget_pause else R.drawable.music_widget_play,
            )
            setContentDescription(
                R.id.music_widget_toggle,
                context.getString(if (pause) R.string.music_widget_pause else R.string.music_widget_play),
            )
            setControl(context, R.id.music_widget_previous, current, "previous".takeIf { current?.canPrevious == true })
            setControl(context, R.id.music_widget_toggle, current, current?.playAction)
            setControl(context, R.id.music_widget_next, current, "next".takeIf { current?.canNext == true })
        }
    }

    private fun RemoteViews.setControl(context: Context, id: Int, playback: Playback?, action: String?) {
        val click = if (playback == null || action == null) null else {
            val data = tokenUri(playback.token).appendPath(action).build()
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
