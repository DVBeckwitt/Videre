package com.github.dvbeckwitt.videre

import android.app.Activity
import android.content.ClipData
import android.content.ContentResolver
import android.content.Intent
import android.net.Uri

/** Launches the chooser with a temporary read grant for one audio attachment. */
internal fun shareAudioFile(host: Activity, uri: Uri, mime: String) {
    require(uri.scheme == ContentResolver.SCHEME_CONTENT && !uri.authority.isNullOrEmpty())
    require(mime.startsWith("audio/"))
    val send = Intent(Intent.ACTION_SEND).apply {
        type = mime
        putExtra(Intent.EXTRA_STREAM, uri)
        clipData = ClipData(null, arrayOf(mime), ClipData.Item(uri))
        addFlags(Intent.FLAG_GRANT_READ_URI_PERMISSION)
    }
    host.startActivity(Intent.createChooser(send, null))
}
