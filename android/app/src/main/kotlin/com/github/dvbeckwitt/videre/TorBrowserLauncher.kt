package com.github.dvbeckwitt.videre

import android.app.Activity
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel

/** Compatibility endpoint for old callers. External browsers cannot enforce
 * Videre's destination policy, so the app now offers copyable addresses. */
class TorBrowserLauncher(@Suppress("UNUSED_PARAMETER") activity: Activity) {
    fun handle(call: MethodCall, result: MethodChannel.Result) {
        when (call.method) {
            "openApp", "openOnionUrl", "openNerdVpnPreferences" -> result.success(false)
            else -> result.notImplemented()
        }
    }
}
