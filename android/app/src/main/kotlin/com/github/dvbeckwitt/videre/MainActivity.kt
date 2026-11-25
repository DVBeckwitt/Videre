package com.github.dvbeckwitt.videre

import android.app.Activity
import android.app.PictureInPictureParams
import android.content.ActivityNotFoundException
import android.content.Context
import android.content.Intent
import android.content.pm.PackageManager
import android.content.res.Configuration
import android.net.ConnectivityManager
import android.net.Network
import android.net.NetworkCapabilities
import android.os.Build
import android.os.Bundle
import android.os.Handler
import android.os.Looper
import android.provider.OpenableColumns
import android.util.Rational
import cl.puntito.simple_pip_mode.PipCallbackHelper
import com.ryanheise.audioservice.AudioServiceActivity
import com.kasem.receive_sharing_intent.ReceiveSharingIntentPlugin
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.embedding.engine.plugins.FlutterPlugin
import io.flutter.plugin.common.EventChannel
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import java.io.ByteArrayOutputStream
import java.io.IOException
import java.nio.ByteBuffer
import java.nio.charset.CharacterCodingException
import java.util.concurrent.Executors

class MainActivity : AudioServiceActivity() {
    private val callbackHelper = PipCallbackHelper()
    private val mainHandler = Handler(Looper.getMainLooper())
    private val fileWorker = Executors.newSingleThreadExecutor()
    private var fileChannel: MethodChannel? = null
    private var pipChannel: MethodChannel? = null
    private var backendChannel: MethodChannel? = null
    private var backendBrowser: BackendDiscoveryBrowser? = null
    private var gatewayChannel: MethodChannel? = null
    private var gatewayBrowser: GatewayAuthBrowser? = null
    private var torBrowserChannel: MethodChannel? = null
    private var autoPip = false
    private var pipAspectRatio = Rational(16, 9)
    private var pendingFile: FileRequest? = null

    private class FileRequest(
        val result: MethodChannel.Result,
        val bytes: ByteArray?,
        val takeout: Boolean,
        val image: Boolean,
    )
    private class FileTooLarge : IOException()

    override fun onCreate(savedInstanceState: Bundle?) {
        val widgetSave = intent?.takeIf { MusicHomeWidgetPlugin.isSaveIntent(it) }
        // Remove owned callbacks before plugins inspect the intent for links.
        // A widget action needs the live playback token from the cached engine.
        if (widgetSave != null || NerdVpnBrowserAttempt.ownsCallback(intent?.dataString)) {
            setIntent(Intent(Intent.ACTION_MAIN).setComponent(componentName))
        }
        super.onCreate(savedInstanceState)
        if (widgetSave != null) MusicHomeWidgetPlugin.handleSaveIntent(this, widgetSave)
    }

    override fun onNewIntent(intent: Intent) {
        if (MusicHomeWidgetPlugin.isSaveIntent(intent)) {
            super.onNewIntent(Intent(Intent.ACTION_MAIN).setComponent(componentName))
            MusicHomeWidgetPlugin.handleSaveIntent(this, intent)
            return
        }
        val callback = intent.dataString
        if (NerdVpnBrowserAttempt.ownsCallback(callback)) {
            gatewayBrowser?.acceptExternalCallback(checkNotNull(callback))
            return
        }
        super.onNewIntent(intent)
    }

    override fun provideFlutterEngine(context: Context): FlutterEngine {
        val engine = checkNotNull(super.provideFlutterEngine(context))
        prepareMediaFlutterEngine(engine)
        return engine
    }

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        callbackHelper.configureFlutterEngine(flutterEngine)
        val messenger = flutterEngine.dartExecutor.binaryMessenger
        fileChannel = MethodChannel(messenger, "videre/files").also {
            it.setMethodCallHandler(::pickFile)
        }
        pipChannel = MethodChannel(messenger, "videre/pip").also {
            it.setMethodCallHandler { call, result ->
                if (call.method != "configure") {
                    result.notImplemented()
                } else {
                    autoPip = call.argument<Boolean>("enabled") == true
                    val ratio = call.argument<Double>("aspectRatio") ?: (16.0 / 9)
                    val safeRatio = if (ratio.isFinite()) ratio.coerceIn(0.42, 2.39) else 16.0 / 9
                    pipAspectRatio = Rational((safeRatio * 10000).toInt(), 10000)
                    if (supportsPip() && Build.VERSION.SDK_INT >= Build.VERSION_CODES.S) {
                        runCatching { setPictureInPictureParams(pipParams()) }
                    }
                    result.success(null)
                }
            }
        }
        backendBrowser = BackendDiscoveryBrowser(this)
        backendChannel = MethodChannel(messenger, "videre/backend_discovery").also {
            it.setMethodCallHandler { call, result -> backendBrowser?.open(call, result)
                ?: result.error("BROWSER_UNAVAILABLE", null, null) }
        }
        gatewayBrowser = GatewayAuthBrowser(this)
        gatewayChannel = MethodChannel(messenger, "videre/gateway_auth").also {
            it.setMethodCallHandler { call, result -> gatewayBrowser?.handle(call, result)
                ?: result.error("GATEWAY_BROWSER_UNAVAILABLE", null, null) }
        }
        val torBrowser = TorBrowserLauncher(this)
        torBrowserChannel = MethodChannel(messenger, "videre/tor_browser").also {
            it.setMethodCallHandler(torBrowser::handle)
        }
    }

    private fun pickFile(call: MethodCall, result: MethodChannel.Result) {
        if (call.method != "save" && call.method != "open" &&
            call.method != "openTakeout" && call.method != "openPlaylistCover") {
            result.notImplemented()
            return
        }
        if (pendingFile != null) {
            result.error("FILE_BUSY", "Finish the current file operation first.", null)
            return
        }
        val saving = call.method == "save"
        val args = call.arguments as? Map<*, *>
        val text = args?.get("text") as? String
        val name = args?.get("name") as? String
        if (saving && (text == null || name.isNullOrBlank())) {
            result.error("INVALID_ARGUMENT", "A file name and UTF-8 text are required.", null)
            return
        }
        if (saving && text!!.length > MAX_FILE_BYTES) {
            result.error("FILE_TOO_LARGE", "Files must be no larger than 10 MiB.", null)
            return
        }
        val bytes = if (saving) text!!.toByteArray(Charsets.UTF_8) else null
        if (bytes != null && bytes.size > MAX_FILE_BYTES) {
            result.error("FILE_TOO_LARGE", "Files must be no larger than 10 MiB.", null)
            return
        }
        val request = FileRequest(result, bytes,
            takeout = call.method == "openTakeout", image = call.method == "openPlaylistCover")
        pendingFile = request
        val intent = Intent(if (saving) Intent.ACTION_CREATE_DOCUMENT else Intent.ACTION_OPEN_DOCUMENT).apply {
            addCategory(Intent.CATEGORY_OPENABLE)
            type = when {
                saving -> "application/json"
                request.image -> "image/*"
                else -> "*/*"
            }
            if (saving) putExtra(Intent.EXTRA_TITLE, name)
            else if (request.image) putExtra(Intent.EXTRA_LOCAL_ONLY, true)
            else if (request.takeout) {
                putExtra(Intent.EXTRA_LOCAL_ONLY, true)
                putExtra(Intent.EXTRA_MIME_TYPES, arrayOf("text/csv", "text/comma-separated-values",
                    "text/plain", "application/csv", "application/zip", "application/x-zip-compressed",
                    "application/octet-stream"))
            }
            else putExtra(Intent.EXTRA_MIME_TYPES, arrayOf("application/json", "text/plain"))
        }
        try {
            startActivityForResult(intent, FILE_REQUEST_CODE)
        } catch (_: ActivityNotFoundException) {
            finishFile(request, error = "NO_FILE_PICKER", message = "No document picker is installed on this device.")
        } catch (_: SecurityException) {
            finishFile(request, error = "FILE_ACCESS", message = "This device does not allow opening the document picker.")
        }
    }

    override fun onActivityResult(requestCode: Int, resultCode: Int, data: Intent?) {
        super.onActivityResult(requestCode, resultCode, data)
        if (requestCode != FILE_REQUEST_CODE) return
        val request = pendingFile ?: return
        if (resultCode != Activity.RESULT_OK) {
            finishFile(request)
            return
        }
        val uri = data?.data
        if (uri == null) {
            finishFile(request, error = "FILE_ACCESS", message = "The document picker did not return a file.")
            return
        }
        if (request.takeout && !TakeoutFiles.isLocalDocument(uri.scheme, uri.authority)) {
            finishFile(request, error = "LOCAL_FILE_REQUIRED",
                message = "Save the Takeout CSV or ZIP to Downloads on this device, then choose that local file.")
            return
        }
        // Cloud document providers may block; keep their streams off the UI thread.
        fileWorker.execute {
            try {
                val value = if (request.bytes != null) {
                    (contentResolver.openOutputStream(uri, "wt") ?: throw IOException()).use {
                        it.write(request.bytes)
                    }
                    true
                } else if (request.takeout) {
                    val name = if (uri.scheme == "file") java.io.File(uri.path ?: "").name else {
                        contentResolver.query(uri, arrayOf(OpenableColumns.DISPLAY_NAME), null, null, null)?.use {
                            if (it.moveToFirst()) it.getString(0) else null
                        }
                    } ?: "takeout.csv"
                    (contentResolver.openInputStream(uri) ?: throw IOException()).use { input ->
                        TakeoutFiles.read(input, name, cacheDir)
                    }
                } else {
                    (contentResolver.openInputStream(uri) ?: throw IOException()).use { input ->
                        val output = ByteArrayOutputStream()
                        val buffer = ByteArray(8192)
                        while (true) {
                            val count = input.read(buffer)
                            if (count == -1) break
                            if (output.size() + count > MAX_FILE_BYTES) throw FileTooLarge()
                            output.write(buffer, 0, count)
                        }
                        val contents = output.toByteArray()
                        if (request.image) contents
                        else Charsets.UTF_8.newDecoder().decode(ByteBuffer.wrap(contents)).toString()
                    }
                }
                mainHandler.post { finishFile(request, value) }
            } catch (error: TakeoutFiles.ReadError) {
                mainHandler.post { finishFile(request, error = error.code, message = error.message) }
            } catch (_: FileTooLarge) {
                mainHandler.post { finishFile(request, error = "FILE_TOO_LARGE", message = "Files must be no larger than 10 MiB.") }
            } catch (_: CharacterCodingException) {
                mainHandler.post { finishFile(request, error = "INVALID_UTF8", message = "Choose a UTF-8 JSON file.") }
            } catch (_: Exception) {
                mainHandler.post { finishFile(request, error = "FILE_IO", message = "Could not read or save the file. Check its location and available storage.") }
            }
        }
    }

    private fun finishFile(request: FileRequest, value: Any? = null, error: String? = null, message: String? = null) {
        if (pendingFile !== request) return
        pendingFile = null
        if (error == null) request.result.success(value)
        else request.result.error(error, message, null)
    }

    private fun releaseChannels() {
        torBrowserChannel?.setMethodCallHandler(null)
        torBrowserChannel = null
        gatewayChannel?.setMethodCallHandler(null)
        gatewayChannel = null
        gatewayBrowser?.close()
        gatewayBrowser = null
        backendChannel?.setMethodCallHandler(null)
        backendChannel = null
        backendBrowser?.close()
        backendBrowser = null
        pendingFile?.let { finishFile(it, error = "ACTIVITY_CLOSED", message = "The file operation was interrupted. Please try again.") }
        fileChannel?.setMethodCallHandler(null)
        fileChannel = null
        pipChannel?.setMethodCallHandler(null)
        pipChannel = null
    }

    override fun cleanUpFlutterEngine(flutterEngine: FlutterEngine) {
        releaseChannels()
        super.cleanUpFlutterEngine(flutterEngine)
    }

    override fun onDestroy() {
        releaseChannels()
        fileWorker.shutdownNow()
        super.onDestroy()
    }

    override fun onPictureInPictureModeChanged(active: Boolean, newConfig: Configuration?) {
        super.onPictureInPictureModeChanged(active, newConfig)
        callbackHelper.onPictureInPictureModeChanged(active)
    }

    private fun supportsPip() = Build.VERSION.SDK_INT >= Build.VERSION_CODES.O &&
        packageManager.hasSystemFeature(PackageManager.FEATURE_PICTURE_IN_PICTURE)

    @android.annotation.TargetApi(Build.VERSION_CODES.O)
    private fun pipParams(): PictureInPictureParams {
        val builder = PictureInPictureParams.Builder().setAspectRatio(pipAspectRatio)
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.S) builder.setAutoEnterEnabled(autoPip)
        return builder.build()
    }

    override fun onUserLeaveHint() {
        super.onUserLeaveHint()
        // Older Android versions need to enter before onPause reaches Flutter.
        if (autoPip && supportsPip() && Build.VERSION.SDK_INT < Build.VERSION_CODES.S && !isInPictureInPictureMode) {
            runCatching { enterPictureInPictureMode(pipParams()) }
        }
    }

    companion object {
        private const val FILE_REQUEST_CODE = 4401
        private const val MAX_FILE_BYTES = 10 * 1024 * 1024
    }
}

// Android Auto can start the retained engine before an Activity exists.
internal fun prepareMediaFlutterEngine(engine: FlutterEngine) {
    // Remove the legacy parser before Activity attachment so only Videre's
    // retained inbox interprets incoming links.
    engine.plugins.remove(ReceiveSharingIntentPlugin::class.java)
    if (!engine.plugins.has(VidereNetworkPlugin::class.java)) {
        engine.plugins.add(VidereNetworkPlugin())
    }
    if (!engine.plugins.has(DownloadStoragePlugin::class.java)) {
        engine.plugins.add(DownloadStoragePlugin())
    }
    if (!engine.plugins.has(LocalMusicPlugin::class.java)) {
        engine.plugins.add(LocalMusicPlugin())
    }
    if (!engine.plugins.has(IncomingLinksPlugin::class.java)) {
        engine.plugins.add(IncomingLinksPlugin())
    }
    if (!engine.plugins.has(MusicVoiceSearchPlugin::class.java)) {
        engine.plugins.add(MusicVoiceSearchPlugin())
    }
    if (!engine.plugins.has(MusicHomeWidgetPlugin::class.java)) {
        engine.plugins.add(MusicHomeWidgetPlugin())
    }
    if (!engine.plugins.has(MusicLyricsScreenPlugin::class.java)) {
        engine.plugins.add(MusicLyricsScreenPlugin())
    }
    if (!engine.plugins.has(MusicScreenPrivacyPlugin::class.java)) {
        engine.plugins.add(MusicScreenPrivacyPlugin())
    }
    if (!engine.plugins.has(AndroidAutoMediaPlugin::class.java)) {
        engine.plugins.add(AndroidAutoMediaPlugin())
    }
}

// The Dart subscription belongs to the engine, not to any individual Activity.
// Use application context so background playback can keep monitoring safely.
private class VidereNetworkPlugin : FlutterPlugin {
    private val mainHandler = Handler(Looper.getMainLooper())
    private lateinit var connectivity: ConnectivityManager
    private var networkChannel: MethodChannel? = null
    private var networkEvents: EventChannel? = null
    private var networkCallback: ConnectivityManager.NetworkCallback? = null

    override fun onAttachedToEngine(binding: FlutterPlugin.FlutterPluginBinding) {
        connectivity = binding.applicationContext.getSystemService(ConnectivityManager::class.java)
        networkChannel = MethodChannel(binding.binaryMessenger, "videre/network").also {
            it.setMethodCallHandler { call, result ->
                if (call.method == "isWifiConnected") result.success(isWifiConnected())
                else result.notImplemented()
            }
        }
        networkEvents = EventChannel(binding.binaryMessenger, "videre/network_changes").also {
            it.setStreamHandler(object : EventChannel.StreamHandler {
                override fun onListen(arguments: Any?, events: EventChannel.EventSink) {
                    watchNetwork(events)
                }

                override fun onCancel(arguments: Any?) = stopWatchingNetwork()
            })
        }
    }

    private fun isWifiConnected(): Boolean = runCatching {
        connectivity.getNetworkCapabilities(connectivity.activeNetwork)
            ?.hasTransport(NetworkCapabilities.TRANSPORT_WIFI) == true
    }.getOrDefault(false)

    private fun watchNetwork(events: EventChannel.EventSink) {
        stopWatchingNetwork()
        val callback = object : ConnectivityManager.NetworkCallback() {
            private var currentNetwork: Network? = null

            override fun onAvailable(network: Network) {
                currentNetwork = network
                // Android 7 does not always send capabilities after onAvailable.
                if (Build.VERSION.SDK_INT < Build.VERSION_CODES.O) {
                    mainHandler.post { if (networkCallback === this) events.success(isWifiConnected()) }
                }
            }

            override fun onCapabilitiesChanged(network: Network, capabilities: NetworkCapabilities) {
                if (network == currentNetwork) publish(capabilities.hasTransport(NetworkCapabilities.TRANSPORT_WIFI))
            }

            override fun onLost(network: Network) {
                if (network == currentNetwork) {
                    currentNetwork = null
                    publish(false)
                }
            }

            private fun publish(wifi: Boolean) {
                mainHandler.post { if (networkCallback === this) events.success(wifi) }
            }
        }
        networkCallback = callback
        try {
            connectivity.registerDefaultNetworkCallback(callback)
            events.success(isWifiConnected())
        } catch (_: RuntimeException) {
            networkCallback = null
            events.error("NETWORK_UNAVAILABLE", "Could not monitor this device's connection.", null)
        }
    }

    private fun stopWatchingNetwork() {
        networkCallback?.let { runCatching { connectivity.unregisterNetworkCallback(it) } }
        networkCallback = null
    }

    override fun onDetachedFromEngine(binding: FlutterPlugin.FlutterPluginBinding) {
        stopWatchingNetwork()
        networkChannel?.setMethodCallHandler(null)
        networkEvents?.setStreamHandler(null)
        networkChannel = null
        networkEvents = null
    }
}
