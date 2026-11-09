package com.github.dvbeckwitt.videre

import android.app.Activity
import android.content.ActivityNotFoundException
import android.content.Intent
import android.net.Uri
import com.github.dvbeckwitt.videre.proxy.NERDVPN_ONION_HOST
import com.github.dvbeckwitt.videre.proxy.isNerdVpnOrigin
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import java.net.URI
import okhttp3.HttpUrl.Companion.toHttpUrlOrNull

/** Handoff to the installed Tor Browser, without sharing credentials or cookies. */
class TorBrowserLauncher(private val activity: Activity) {
    fun handle(call: MethodCall, result: MethodChannel.Result) {
        if (call.method == "openApp") {
            // Tor Browser 16 no longer accepts external web links. Its public
            // launcher remains available, with the address pasted by the user.
            val intent = try {
                activity.packageManager.getLaunchIntentForPackage("org.torproject.torbrowser")
            } catch (_: SecurityException) { null }
            result.success(intent?.let(::open) ?: false)
            return
        }
        if (call.method != "openNerdVpnPreferences") {
            result.notImplemented()
            return
        }
        val raw = (call.arguments as? Map<*, *>)?.get("serverUrl") as? String
        val uri = raw?.let { runCatching { URI(it) }.getOrNull() }
        val origin = raw?.toHttpUrlOrNull()
        if (uri == null || origin == null || uri.rawUserInfo != null ||
            uri.rawPath !in setOf("", "/") || uri.rawQuery != null || uri.rawFragment != null ||
            origin.host != NERDVPN_ONION_HOST || !isNerdVpnOrigin(origin)) {
            result.success(false)
            return
        }
        val target = origin.newBuilder().encodedPath("/preferences").fragment("api-access").build()
        val intent = Intent(Intent.ACTION_VIEW, Uri.parse(target.toString())).apply {
            addCategory(Intent.CATEGORY_BROWSABLE)
        }
        result.success(open(intent))
    }

    private fun open(intent: Intent): Boolean {
        if (activity.isFinishing || activity.isDestroyed) return false
        intent.setPackage("org.torproject.torbrowser")
        // A package-specific intent must never fall back to an ordinary browser.
        return try {
            activity.startActivity(intent)
            true
        } catch (_: ActivityNotFoundException) {
            false
        } catch (_: SecurityException) {
            false
        }
    }
}
