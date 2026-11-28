package com.github.dvbeckwitt.videre

import android.app.Activity
import android.content.ActivityNotFoundException
import android.content.Intent
import android.content.pm.PackageManager
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel

private val youtubeVideoId = Regex("[A-Za-z0-9_-]{11}")

internal fun ytdlnisPublicVideoUrl(videoId: String?): String? =
    videoId?.takeIf(youtubeVideoId::matches)?.let { "https://www.youtube.com/watch?v=$it" }

internal class YtdlnisDownloadLauncher(private val activity: Activity) {
    fun handle(call: MethodCall, result: MethodChannel.Result) {
        if (call.method != "open") {
            result.notImplemented()
            return
        }
        val args = call.arguments as? Map<*, *>
        val url = ytdlnisPublicVideoUrl(args?.get("videoId") as? String)
        val audioOnly = args?.get("audioOnly") as? Boolean
        if (url == null || audioOnly == null) {
            result.success("failed")
            return
        }

        // Target the regular share activity. Its separate Quick Download
        // alias is intended for unattended downloads.
        val intent = Intent(Intent.ACTION_SEND).apply {
            type = "text/plain"
            addCategory(Intent.CATEGORY_DEFAULT)
            setClassName("com.deniscerri.ytdl", "com.deniscerri.ytdl.receiver.ShareActivity")
            putExtra(Intent.EXTRA_TEXT, url)
            putExtra("TYPE", if (audioOnly) "audio" else "video")
            putExtra("BACKGROUND", false)
            putExtra("quick_download", false)
        }
        val outcome = try {
            if (activity.packageManager.resolveActivity(intent, PackageManager.MATCH_DEFAULT_ONLY) == null) {
                "unavailable"
            } else {
                activity.startActivity(intent)
                "opened"
            }
        } catch (_: ActivityNotFoundException) {
            "unavailable"
        } catch (_: SecurityException) {
            "failed"
        }
        result.success(outcome)
    }
}
