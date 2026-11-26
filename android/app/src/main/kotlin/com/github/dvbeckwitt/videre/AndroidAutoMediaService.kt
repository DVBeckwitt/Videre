package com.github.dvbeckwitt.videre

import android.app.ActivityManager
import android.content.ComponentName
import android.content.ContentResolver
import android.content.Context
import android.content.Intent
import android.content.ServiceConnection
import android.os.Bundle
import android.os.Handler
import android.os.IBinder
import android.os.Looper
import android.os.Process
import android.os.SystemClock
import android.support.v4.media.MediaBrowserCompat.MediaItem
import android.support.v4.media.MediaDescriptionCompat
import android.support.v4.media.MediaMetadataCompat.METADATA_KEY_DURATION
import androidx.media.MediaBrowserServiceCompat
import androidx.media.utils.MediaConstants.BROWSER_ROOT_HINTS_KEY_CUSTOM_BROWSER_ACTION_LIMIT
import androidx.media.utils.MediaConstants.BROWSER_SERVICE_EXTRAS_KEY_CUSTOM_BROWSER_ACTION_ROOT_LIST
import androidx.media.utils.MediaConstants.BROWSER_SERVICE_EXTRAS_KEY_SEARCH_SUPPORTED
import androidx.media.utils.MediaConstants.DESCRIPTION_EXTRAS_KEY_CUSTOM_BROWSER_ACTION_ID_LIST
import androidx.media.utils.MediaConstants.EXTRAS_KEY_CUSTOM_BROWSER_ACTION_ICON_URI
import androidx.media.utils.MediaConstants.EXTRAS_KEY_CUSTOM_BROWSER_ACTION_ID
import androidx.media.utils.MediaConstants.EXTRAS_KEY_CUSTOM_BROWSER_ACTION_LABEL
import androidx.media.utils.MediaConstants.EXTRAS_KEY_CUSTOM_BROWSER_ACTION_MEDIA_ITEM_ID
import com.ryanheise.audioservice.AudioService
import com.ryanheise.audioservice.AudioServiceAccess
import com.ryanheise.audioservice.MusicQueueRow
import com.ryanheise.audioservice.AudioServicePlugin
import io.flutter.embedding.engine.plugins.FlutterPlugin
import io.flutter.embedding.engine.plugins.activity.ActivityAware
import io.flutter.embedding.engine.plugins.activity.ActivityPluginBinding
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
        val systemResumption = isSystemMediaResumptionBrowser(packageManager, clientPackageName, clientUid)
        if (!systemResumption && !isTrustedMediaBrowser(packageManager, clientPackageName, clientUid)) return null
        if (!bound && !connecting) {
            // Warm the shared Flutter engine without delaying the caller's root check.
            connecting = true
            main.post(connectPlayback)
        }
        val recent = rootHints?.getBoolean(BrowserRoot.EXTRA_RECENT) == true
        if (recent && systemResumption) {
            return BrowserRoot(SYSTEM_RECENT_ROOT, Bundle().apply {
                putBoolean(BrowserRoot.EXTRA_RECENT, true)
            })
        }
        return BrowserRoot(if (recent) "recent" else "root", Bundle().apply {
            putBoolean(BROWSER_SERVICE_EXTRAS_KEY_SEARCH_SUPPORTED, true)
            if (rootHints.queueActionLimit() > 0) {
                putParcelableArrayList(
                    BROWSER_SERVICE_EXTRAS_KEY_CUSTOM_BROWSER_ACTION_ROOT_LIST,
                    ArrayList(QueueBrowseAction.entries.map(::describeAction)),
                )
            }
        })
    }

    override fun onLoadChildren(parentId: String, result: Result<List<MediaItem>>) {
        onLoadChildren(parentId, result, Bundle.EMPTY)
    }

    override fun onLoadChildren(parentId: String, result: Result<List<MediaItem>>, options: Bundle) {
        if (parentId == SYSTEM_RECENT_ROOT) {
            val browser = currentBrowserInfo
            if (!isSystemMediaResumptionBrowser(packageManager, browser.packageName, browser.uid)) {
                result.sendResult(emptyList())
                return
            }
        }
        val actionLimit = if (parentId == SYSTEM_RECENT_ROOT) 0 else browserRootHints.queueActionLimit()
        val channel = queueBrowserChannel(actionLimit)
        if (channel != null) {
            callQueueBrowser(channel, "getQueueBrowseChildren", parentId, result, emptyList()) {
                browseRows(it, actionLimit)
            }
            return
        }
        val player = AudioServiceAccess.current()
        if (player == null) result.sendResult(emptyList()) else player.onLoadChildren(parentId, result, options)
    }

    override fun onLoadItem(itemId: String, result: Result<MediaItem>) {
        val actionLimit = browserRootHints.queueActionLimit()
        val channel = queueBrowserChannel(actionLimit)
        if (channel != null) {
            callQueueBrowser(channel, "getQueueBrowseItem", itemId, result, null) {
                browseRow(it, actionLimit)
            }
            return
        }
        val player = AudioServiceAccess.current()
        if (player == null) result.sendResult(null) else player.onLoadItem(itemId, result)
    }

    override fun onSearch(query: String, extras: Bundle?, result: Result<List<MediaItem>>) {
        val actionLimit = browserRootHints.queueActionLimit()
        val channel = queueBrowserChannel(actionLimit)
        if (channel != null && query.isNotBlank() &&
            extras?.keySet()?.any { it.startsWith("android.intent.extra.") } != true
        ) {
            callQueueBrowser(channel, "searchQueueBrowse", query, result, emptyList()) {
                browseRows(it, actionLimit)
            }
            return
        }
        val player = AudioServiceAccess.current()
        if (player == null) result.sendResult(emptyList()) else player.onSearch(query, extras, result)
    }

    override fun onCustomAction(action: String, extras: Bundle?, result: Result<Bundle>) {
        val channel = queueBrowserChannel(browserRootHints.queueActionLimit())
        val mediaId = extras?.getString(EXTRAS_KEY_CUSTOM_BROWSER_ACTION_MEDIA_ITEM_ID)
        val command = QueueBrowseAction.entries.firstOrNull { it.id == action }
        if (channel == null || command == null || !command.accepts(mediaId)) {
            result.sendError(Bundle.EMPTY)
            return
        }
        result.detach()
        channel.invokeMethod("mutateMusicQueue", mapOf("action" to action, "mediaId" to mediaId),
            object : MethodChannel.Result {
                override fun success(value: Any?) {
                    if (value == true) result.sendResult(Bundle.EMPTY) else result.sendError(Bundle.EMPTY)
                }
                override fun error(code: String, message: String?, details: Any?) = notImplemented()
                override fun notImplemented() = result.sendError(Bundle.EMPTY)
            },
        )
    }

    // The pinned audio_service browser bridge drops list-valued MediaItem extras.
    private fun queueBrowserChannel(actionLimit: Int): MethodChannel? =
        if (actionLimit > 0 && bound && sessionToken != null) AndroidAutoMediaPlugin.browserChannel else null

    private fun describeAction(action: QueueBrowseAction): Bundle = Bundle().apply {
        putString(EXTRAS_KEY_CUSTOM_BROWSER_ACTION_ID, action.id)
        putString(EXTRAS_KEY_CUSTOM_BROWSER_ACTION_LABEL, getString(action.label))
        putString(
            EXTRAS_KEY_CUSTOM_BROWSER_ACTION_ICON_URI,
            "${ContentResolver.SCHEME_ANDROID_RESOURCE}://$packageName/${action.icon}",
        )
    }

    private fun <T> callQueueBrowser(
        channel: MethodChannel,
        method: String,
        argument: String,
        result: Result<T>,
        empty: T?,
        decode: (Any?) -> T?,
    ) {
        result.detach()
        channel.invokeMethod(method, argument, object : MethodChannel.Result {
            override fun success(value: Any?) = result.sendResult(decode(value) ?: empty)
            override fun error(code: String, message: String?, details: Any?) = notImplemented()
            override fun notImplemented() = result.sendResult(empty)
        })
    }

    override fun onDestroy() {
        if (active === this) active = null
        main.removeCallbacks(connectPlayback)
        if (bound) unbindService(connection)
        super.onDestroy()
    }

    internal companion object {
        const val SYSTEM_RECENT_ROOT = "system-resume-recent"
        // Accessed only on the Android main thread, including channel calls.
        var active: AndroidAutoMediaService? = null
            private set
    }
}

private fun Bundle?.queueActionLimit(): Int =
    this?.getInt(BROWSER_ROOT_HINTS_KEY_CUSTOM_BROWSER_ACTION_LIMIT, 0)?.coerceAtLeast(0) ?: 0

private enum class QueueBrowseAction(val id: String, val label: Int, val icon: Int) {
    ADD("addToQueue", R.string.car_add_to_queue, R.drawable.car_queue_add),
    REMOVE("removeFromQueue", R.string.car_remove_from_queue, R.drawable.car_queue_remove),
    EARLIER("moveQueueEarlier", R.string.car_move_queue_earlier, R.drawable.car_queue_earlier),
    LATER("moveQueueLater", R.string.car_move_queue_later, R.drawable.car_queue_later);

    fun accepts(mediaId: String?): Boolean {
        val prefix = if (this == ADD) "car:" else "car-queue-browse:"
        return mediaId != null && mediaId.length in (prefix.length + 1)..256 && mediaId.startsWith(prefix)
    }
}

private fun browseRows(value: Any?, actionLimit: Int): List<MediaItem> =
    (value as? List<*>)?.take(101)?.mapNotNull { browseRow(it, actionLimit) }.orEmpty()

private fun browseRow(value: Any?, actionLimit: Int): MediaItem? {
    val row = value as? Map<*, *> ?: return null
    val id = row["id"] as? String ?: return null
    val title = row["title"] as? String ?: return null
    val playable = row["playable"] as? Boolean ?: return null
    val actions = (row["actions"] as? List<*>).orEmpty().filterIsInstance<String>()
        .filter { action -> QueueBrowseAction.entries.any { it.id == action && it.accepts(id) } }
        .distinct().take(actionLimit)
    val description = MediaDescriptionCompat.Builder()
        .setMediaId(id)
        .setTitle(title)
        .setSubtitle(row["artist"] as? String)
        .setDescription(row["album"] as? String)
        .setExtras(Bundle().apply {
            if (actions.isNotEmpty()) {
                putStringArrayList(DESCRIPTION_EXTRAS_KEY_CUSTOM_BROWSER_ACTION_ID_LIST, ArrayList(actions))
            }
            (row["durationMs"] as? Number)?.let { putLong(METADATA_KEY_DURATION, it.toLong()) }
        })
        .build()
    val flag = if (playable) MediaItem.FLAG_PLAYABLE else MediaItem.FLAG_BROWSABLE
    return MediaItem(description, flag)
}

internal class AndroidAutoMediaPlugin : FlutterPlugin, ActivityAware {
    private val main = Handler(Looper.getMainLooper())
    private var channel: MethodChannel? = null
    private var activityAttached = false

    override fun onAttachedToEngine(binding: FlutterPlugin.FlutterPluginBinding) {
        channel = MethodChannel(binding.binaryMessenger, "videre/car_media").also {
            browserChannel = it
            it.setMethodCallHandler { call, result ->
                when (call.method) {
                    "hasMediaActivity" -> result.success(activityAttached)
                    "awaitResumeForeground" -> awaitResumeForeground(binding.applicationContext, result)
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
        main.removeCallbacksAndMessages(null)
        channel?.setMethodCallHandler(null)
        if (browserChannel === channel) browserChannel = null
        channel = null
    }

    override fun onAttachedToActivity(binding: ActivityPluginBinding) {
        activityAttached = true
    }

    override fun onReattachedToActivityForConfigChanges(binding: ActivityPluginBinding) =
        onAttachedToActivity(binding)

    override fun onDetachedFromActivity() {
        activityAttached = false
    }

    override fun onDetachedFromActivityForConfigChanges() = onDetachedFromActivity()

    // On Android 15+, a headless decoder needs foreground-service status before
    // requesting audio focus. AudioService enters foreground after Dart posts
    // a playing state on a separate channel, so wait for Android's acknowledgement.
    @Suppress("DEPRECATION")
    private fun awaitResumeForeground(context: Context, result: MethodChannel.Result) {
        val services = context.getSystemService(ActivityManager::class.java)
            ?: return result.success(false)
        val deadline = SystemClock.uptimeMillis() + 1_500
        fun check() {
            val foreground = services.getRunningServices(Int.MAX_VALUE).any {
                it.service.className == AudioService::class.java.name &&
                    it.pid == Process.myPid() && it.foreground
            }
            when {
                foreground -> result.success(true)
                SystemClock.uptimeMillis() >= deadline -> result.success(false)
                else -> main.postDelayed({ check() }, 50)
            }
        }
        check()
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

    companion object {
        // The car service and the engine plugin both use the Android main thread.
        var browserChannel: MethodChannel? = null
            private set
    }
}
