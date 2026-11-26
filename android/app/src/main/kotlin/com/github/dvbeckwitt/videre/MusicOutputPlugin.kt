package com.github.dvbeckwitt.videre

import android.annotation.TargetApi
import android.content.Context
import android.media.AudioAttributes
import android.media.AudioDeviceCallback
import android.media.AudioDeviceInfo
import android.media.AudioManager
import android.media.MediaRoute2Info
import android.media.MediaRouter2
import android.media.RouteDiscoveryPreference
import android.os.Build
import android.os.Handler
import android.os.Looper
import android.util.Base64
import io.flutter.embedding.engine.plugins.FlutterPlugin
import io.flutter.plugin.common.EventChannel
import java.security.MessageDigest

internal class MusicOutputPlugin : FlutterPlugin, EventChannel.StreamHandler {
    private var context: Context? = null
    private var channel: EventChannel? = null
    private var monitor: MediaOutputMonitor? = null

    override fun onAttachedToEngine(binding: FlutterPlugin.FlutterPluginBinding) {
        context = binding.applicationContext
        channel = EventChannel(binding.binaryMessenger, "videre/music_output").also {
            it.setStreamHandler(this)
        }
    }

    override fun onListen(arguments: Any?, events: EventChannel.EventSink) {
        onCancel(null)
        val applicationContext = context
        if (applicationContext == null) return
        monitor = MediaOutputMonitor(applicationContext, events).also { it.start() }
    }

    override fun onCancel(arguments: Any?) {
        monitor?.stop()
        monitor = null
    }

    override fun onDetachedFromEngine(binding: FlutterPlugin.FlutterPluginBinding) {
        onCancel(null)
        channel?.setStreamHandler(null)
        channel = null
        context = null
    }
}

private class MediaOutputMonitor(
    context: Context,
    private val events: EventChannel.EventSink,
) {
    private val manager = context.getSystemService(AudioManager::class.java)
    private val handler = Handler(Looper.getMainLooper())
    private val selectedRoute = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU) {
        SelectedMediaRoute(context, ::routeChanged)
    } else null
    private var watching = false
    private var lastSelection: OutputSelection? = null
    private val connectedOutputPorts = mutableSetOf<Int>()

    private val settledRefresh = Runnable { refresh() }
    private val scheduledRefresh = object : Runnable {
        override fun run() {
            if (!watching) return
            refresh()
            handler.postDelayed(this, 4_000)
        }
    }
    private val deviceCallback = object : AudioDeviceCallback() {
        override fun onAudioDevicesAdded(addedDevices: Array<out AudioDeviceInfo>) {
            if (!watching) return
            for (device in addedDevices) {
                if (device.isSink && connectedOutputPorts.add(device.id) && device.isWiredHeadset()) {
                    events.success(mapOf("kind" to "wiredHeadsetInserted", "id" to device.id))
                }
            }
            routeChanged()
        }

        override fun onAudioDevicesRemoved(removedDevices: Array<out AudioDeviceInfo>) {
            if (!watching) return
            for (device in removedDevices) {
                if (!device.isSink || !connectedOutputPorts.remove(device.id)) continue
                if (device.isWiredHeadset()) {
                    events.success(mapOf("kind" to "wiredHeadsetRemoved", "id" to device.id))
                }
                if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU) {
                    val id = bluetoothOutputId(device) ?: continue
                    publishBluetoothDisconnection(id, device.id)
                }
            }
            routeChanged()
        }
    }

    fun start() {
        if (manager == null) {
            refreshSelection(OutputSelection(null, null, null))
            return
        }
        // Android delivers a snapshot of existing devices at registration.
        // Seed their ports so merely starting the observer never autoplays.
        manager.getDevices(AudioManager.GET_DEVICES_OUTPUTS).mapTo(connectedOutputPorts) { it.id }
        watching = true
        runCatching { manager.registerAudioDeviceCallback(deviceCallback, handler) }
        selectedRoute?.start()
        // The policy query has no matching public change listener. A slow refresh
        // also catches policy switches for which the discovery list stays the same.
        if (selectedRoute == null) refresh() else scheduledRefresh.run()
    }

    fun stop() {
        if (!watching) return
        watching = false
        handler.removeCallbacks(settledRefresh)
        handler.removeCallbacks(scheduledRefresh)
        runCatching { manager?.unregisterAudioDeviceCallback(deviceCallback) }
        selectedRoute?.stop()
    }

    private fun routeChanged() {
        if (watching && selectedRoute != null) {
            // Device and router notifications can precede the audio policy update.
            handler.removeCallbacks(settledRefresh)
            handler.postDelayed(settledRefresh, 200)
        }
    }

    private fun refresh() {
        if (!watching) return
        val device = selectedRoute?.device()
        reportBluetoothLossBeforeFallback(device?.id)
        val output = device?.let(::musicOutput)
        val bluetooth = device?.takeIf { it.id in connectedOutputPorts }
        val bluetoothId = bluetooth?.let(::bluetoothOutputId)
        refreshSelection(OutputSelection(output, bluetoothId, bluetooth?.id?.takeIf { bluetoothId != null }))
    }

    private fun reportBluetoothLossBeforeFallback(selectedPortId: Int?) {
        val previous = lastSelection ?: return
        val portId = previous.portId ?: return
        val id = previous.bluetoothId ?: return
        if (portId == selectedPortId) return
        // Audio policy may select the speaker before the queued device callback.
        // Check physical presence before publishing a fallback selection.
        val present = runCatching {
            manager?.getDevices(AudioManager.GET_DEVICES_OUTPUTS)?.any { it.id == portId }
        }.getOrNull()
        if (present == false && connectedOutputPorts.remove(portId)) {
            publishBluetoothDisconnection(id, portId)
        }
    }

    private fun publishBluetoothDisconnection(id: String, portId: Int) {
        if (lastSelection?.portId == portId) lastSelection = null
        events.success(mapOf(
            "kind" to "bluetoothDisconnected",
            "id" to id,
            "bluetoothPortId" to portId,
        ))
    }

    private fun refreshSelection(selection: OutputSelection) {
        if (selection != lastSelection) {
            lastSelection = selection
            events.success(mapOf(
                "kind" to "selected",
                "id" to selection.output?.id,
                "label" to selection.output?.label,
                "bluetoothOutputId" to selection.bluetoothId,
                "bluetoothPortId" to selection.portId,
            ))
        }
    }
}

@TargetApi(Build.VERSION_CODES.TIRAMISU)
private class SelectedMediaRoute(context: Context, routeChanged: () -> Unit) {
    private val manager = context.getSystemService(AudioManager::class.java)
    private val router = runCatching { MediaRouter2.getInstance(context) }.getOrNull()
    private val executor = context.mainExecutor
    private val attributes = AudioAttributes.Builder()
        .setUsage(AudioAttributes.USAGE_MEDIA)
        .setContentType(AudioAttributes.CONTENT_TYPE_MUSIC)
        .build()
    @Suppress("OVERRIDE_DEPRECATION")
    private val callback = object : MediaRouter2.RouteCallback() {
        override fun onRoutesAdded(routes: List<MediaRoute2Info>) = routeChanged()
        override fun onRoutesRemoved(routes: List<MediaRoute2Info>) = routeChanged()
        override fun onRoutesChanged(routes: List<MediaRoute2Info>) = routeChanged()
        override fun onRoutesUpdated(routes: List<MediaRoute2Info>) = routeChanged()
    }

    fun start() {
        runCatching {
            router?.registerRouteCallback(
                executor,
                callback,
                RouteDiscoveryPreference.Builder(listOf(MediaRoute2Info.FEATURE_LIVE_AUDIO), false).build(),
            )
        }
    }

    fun stop() {
        runCatching { router?.unregisterRouteCallback(callback) }
    }

    fun device(): AudioDeviceInfo? = runCatching {
        manager?.getAudioDevicesForAttributes(attributes)?.singleOrNull()?.takeIf { it.isSink }
    }.getOrNull()
}

private data class OutputSelection(val output: MusicOutput?, val bluetoothId: String?, val portId: Int?)
private data class MusicOutput(val id: String, val label: String)

private fun AudioDeviceInfo.isWiredHeadset(): Boolean = when (type) {
    AudioDeviceInfo.TYPE_WIRED_HEADPHONES, AudioDeviceInfo.TYPE_WIRED_HEADSET,
    AudioDeviceInfo.TYPE_USB_HEADSET -> true
    else -> false
}

private val bluetoothAddress = Regex("(?:[0-9a-f]{2}[:-]){5}[0-9a-f]{2}", RegexOption.IGNORE_CASE)
private val genericAddresses = setOf(
    "default", "unknown", "none", "null", "speaker", "headphones", "headset", "wired", "usb", "hdmi",
)

@TargetApi(Build.VERSION_CODES.TIRAMISU)
private fun bluetoothOutputId(device: AudioDeviceInfo): String? = when (device.type) {
    AudioDeviceInfo.TYPE_BLUETOOTH_A2DP, AudioDeviceInfo.TYPE_BLE_HEADSET,
    AudioDeviceInfo.TYPE_BLE_SPEAKER, AudioDeviceInfo.TYPE_HEARING_AID ->
        normalizedBluetoothAddress(device.address.trim())?.let { outputId("bluetooth-media:$it") }
    else -> null
}

private fun normalizedBluetoothAddress(address: String): String? {
    if (!bluetoothAddress.matches(address)) return null
    return address.replace('-', ':').lowercase().takeUnless {
        it == "00:00:00:00:00:00" || it == "02:00:00:00:00:00" || it == "ff:ff:ff:ff:ff:ff"
    }
}

private fun outputId(key: String): String {
    val hash = MessageDigest.getInstance("SHA-256").digest(key.toByteArray(Charsets.UTF_8))
    return Base64.encodeToString(hash, Base64.URL_SAFE or Base64.NO_WRAP or Base64.NO_PADDING)
}

@TargetApi(Build.VERSION_CODES.TIRAMISU)
private fun musicOutput(device: AudioDeviceInfo): MusicOutput? {
    val type = device.type
    val bluetooth = when (type) {
        AudioDeviceInfo.TYPE_BUILTIN_SPEAKER -> return MusicOutput("android-output:speaker", "Device speaker")
        AudioDeviceInfo.TYPE_BUILTIN_EARPIECE -> return MusicOutput("android-output:earpiece", "Earpiece")
        AudioDeviceInfo.TYPE_BLE_HEADSET, AudioDeviceInfo.TYPE_BLE_SPEAKER, AudioDeviceInfo.TYPE_BLUETOOTH_A2DP,
        AudioDeviceInfo.TYPE_BLUETOOTH_SCO, AudioDeviceInfo.TYPE_HEARING_AID -> true
        AudioDeviceInfo.TYPE_WIRED_HEADPHONES, AudioDeviceInfo.TYPE_WIRED_HEADSET, AudioDeviceInfo.TYPE_AUX_LINE,
        AudioDeviceInfo.TYPE_USB_DEVICE, AudioDeviceInfo.TYPE_USB_ACCESSORY, AudioDeviceInfo.TYPE_USB_HEADSET,
        AudioDeviceInfo.TYPE_HDMI, AudioDeviceInfo.TYPE_HDMI_ARC, AudioDeviceInfo.TYPE_HDMI_EARC -> false
        else -> return null
    }
    val address = device.address.trim()
    val key = if (bluetooth) {
        normalizedBluetoothAddress(address) ?: return null
    } else {
        // A port/card index can be reassigned to a different device after reconnect.
        val lowerAddress = address.lowercase()
        if (address.all { it.isDigit() } || lowerAddress in genericAddresses ||
            lowerAddress.startsWith("card=") || lowerAddress.startsWith("device=")) return null
        address
    }

    val id = outputId("$type:$key")
    val label = device.productName.toString().trim().takeUnless {
        it.isEmpty() || it.contains(address, ignoreCase = true)
    } ?: "Audio output"
    return MusicOutput("android-output:$id", label)
}
