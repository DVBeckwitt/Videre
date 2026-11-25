package com.github.dvbeckwitt.videre

import android.content.ComponentName
import android.content.Context
import android.content.Intent
import android.content.ServiceConnection
import android.os.Bundle
import android.os.Handler
import android.os.IBinder
import android.os.Looper
import android.support.v4.media.MediaBrowserCompat.MediaItem
import androidx.media.MediaBrowserServiceCompat
import androidx.media.utils.MediaConstants.BROWSER_SERVICE_EXTRAS_KEY_SEARCH_SUPPORTED
import com.ryanheise.audioservice.AudioService
import com.ryanheise.audioservice.AudioServiceAccess
import com.ryanheise.audioservice.MusicQueueRow
import com.ryanheise.audioservice.AudioServicePlugin
import io.flutter.embedding.engine.plugins.FlutterPlugin
import io.flutter.plugin.common.MethodChannel

/** Publishes the existing player session to validated media hosts. */
class AndroidAutoMediaService : MediaBrowserServiceCompat() {
    private val main = Handler(Looper.getMainLooper())
    private var connecting = false
    private var bound = false
    private val connection = object : ServiceConnection {
        override fun onServiceConnected(name: ComponentName, service: IBinder) {
            if (sessionToken == null) {
                AudioServiceAccess.current()?.sessionToken?.let(::setSessionToken)
            }
        }

        override fun onServiceDisconnected(name: ComponentName) = Unit
    }
    private val connectPlayback = Runnable {
        prepareMediaFlutterEngine(AudioServicePlugin.getFlutterEngine(this))
        val intent = Intent(this, AudioService::class.java).setAction(SERVICE_INTERFACE)
        bound = bindService(intent, connection, Context.BIND_AUTO_CREATE)
        connecting = false
    }

    override fun onCreate() {
        super.onCreate()
        active = this
    }

    override fun onGetRoot(clientPackageName: String, clientUid: Int, rootHints: Bundle?): BrowserRoot? {
        if (!isTrustedMediaBrowser(packageManager, clientPackageName, clientUid)) return null
        if (!bound && !connecting) {
            // Warm the shared Flutter engine without delaying the caller's root check.
            connecting = true
            main.post(connectPlayback)
        }
        val rootId = if (rootHints?.getBoolean(BrowserRoot.EXTRA_RECENT) == true) "recent" else "root"
        return BrowserRoot(rootId, Bundle().apply {
            putBoolean(BROWSER_SERVICE_EXTRAS_KEY_SEARCH_SUPPORTED, true)
        })
    }

    override fun onLoadChildren(parentId: String, result: Result<List<MediaItem>>) {
        onLoadChildren(parentId, result, Bundle.EMPTY)
    }

    override fun onLoadChildren(parentId: String, result: Result<List<MediaItem>>, options: Bundle) {
        val player = AudioServiceAccess.current()
        if (player == null) result.sendResult(emptyList()) else player.onLoadChildren(parentId, result, options)
    }

    override fun onLoadItem(itemId: String, result: Result<MediaItem>) {
        val player = AudioServiceAccess.current()
        if (player == null) result.sendResult(null) else player.onLoadItem(itemId, result)
    }

    override fun onSearch(query: String, extras: Bundle?, result: Result<List<MediaItem>>) {
        val player = AudioServiceAccess.current()
        if (player == null) result.sendResult(emptyList()) else player.onSearch(query, extras, result)
    }

    override fun onDestroy() {
        if (active === this) active = null
        main.removeCallbacks(connectPlayback)
        if (bound) unbindService(connection)
        super.onDestroy()
    }

    internal companion object {
        // Accessed only on the Android main thread, including channel calls.
        var active: AndroidAutoMediaService? = null
            private set
    }
}

internal class AndroidAutoMediaPlugin : FlutterPlugin {
    private var channel: MethodChannel? = null

    override fun onAttachedToEngine(binding: FlutterPlugin.FlutterPluginBinding) {
        channel = MethodChannel(binding.binaryMessenger, "videre/car_media").also {
            it.setMethodCallHandler { call, result ->
                when (call.method) {
                    "notifyChildrenChanged" -> {
                        val id = call.arguments as? String
                        if (id.isNullOrEmpty()) {
                            result.error("INVALID_ARGUMENT", "A parent media ID is required.", null)
                        } else {
                            AndroidAutoMediaService.active?.notifyChildrenChanged(id)
                            result.success(null)
                        }
                    }
                    "setMusicQueue" -> {
                        val rows = musicQueue(call.arguments)
                        if (rows == null) {
                            result.error("INVALID_ARGUMENT", "Invalid music queue.", null)
                        } else {
                            result.success(AudioServiceAccess.setMusicQueue(rows))
                        }
                    }
                    else -> result.notImplemented()
                }
            }
        }
    }

    override fun onDetachedFromEngine(binding: FlutterPlugin.FlutterPluginBinding) {
        channel?.setMethodCallHandler(null)
        channel = null
    }

    private fun musicQueue(value: Any?): List<MusicQueueRow>? {
        if (value !is List<*> || value.size > 100) return null
        val ids = mutableSetOf<Long>()
        return value.map { item ->
            val row = item as? Map<*, *> ?: return null
            val id = (row["id"] as? Number)?.toLong() ?: return null
            val mediaId = row["mediaId"] as? String ?: return null
            val title = row["title"] as? String ?: return null
            if (id < 1_000_000_000 || !ids.add(id) || !mediaId.startsWith("car-queue:")) return null
            MusicQueueRow(id, mediaId, title, row["artist"] as? String, row["album"] as? String)
        }
    }
}
