package com.github.dvbeckwitt.videre

import android.app.Activity
import android.content.ActivityNotFoundException
import android.content.Intent
import android.content.pm.PackageManager
import android.net.Uri
import android.os.Build
import android.provider.Settings
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel

internal enum class MusicAndroidSettingsPage(
    val method: String,
    val action: String,
    val minSdk: Int,
    val usesPackageUri: Boolean = true,
) {
    NOTIFICATIONS("openNotifications", Settings.ACTION_APP_NOTIFICATION_SETTINGS, Build.VERSION_CODES.O, false),

    // AOSP exposes this per-app screen from Android 12. OEM builds may omit it.
    BATTERY("openBattery", "android.settings.VIEW_ADVANCED_POWER_USAGE_DETAIL", Build.VERSION_CODES.S),
    APP_DETAILS("openAppDetails", Settings.ACTION_APPLICATION_DETAILS_SETTINGS, Build.VERSION_CODES.GINGERBREAD),
}

internal fun tryOpenMusicAndroidSettings(
    page: MusicAndroidSettingsPage,
    sdkInt: Int,
    launch: (MusicAndroidSettingsPage) -> Boolean,
): Boolean {
    if (sdkInt < page.minSdk) return false
    return try {
        launch(page)
    } catch (_: ActivityNotFoundException) {
        false
    } catch (_: SecurityException) {
        false
    }
}

internal class MusicAndroidSettingsLauncher(private val activity: Activity) {
    fun handle(call: MethodCall, result: MethodChannel.Result) {
        val page = MusicAndroidSettingsPage.entries.firstOrNull { it.method == call.method }
        if (page == null) {
            result.notImplemented()
            return
        }
        result.success(tryOpenMusicAndroidSettings(page, Build.VERSION.SDK_INT, ::launch))
    }

    private fun launch(page: MusicAndroidSettingsPage): Boolean {
        val intent = Intent(page.action).apply {
            if (page.usesPackageUri) {
                data = Uri.fromParts("package", activity.packageName, null)
            } else {
                putExtra(Settings.EXTRA_APP_PACKAGE, activity.packageName)
            }
            addFlags(Intent.FLAG_ACTIVITY_NO_USER_ACTION)
        }
        val settingsActivity = activity.packageManager.resolveActivity(
            intent, PackageManager.MATCH_DEFAULT_ONLY or PackageManager.MATCH_SYSTEM_ONLY,
        )?.activityInfo ?: return false
        intent.setClassName(settingsActivity.packageName, settingsActivity.name)
        activity.startActivity(intent)
        return true
    }
}
