package com.github.dvbeckwitt.videre

import android.app.Activity
import android.content.ClipData
import android.content.ContentResolver
import android.content.Intent
import android.net.Uri

internal fun shareAudioFile(host: Activity, uri: Uri, mime: String) =
    openAudioShare(host, listOf(uri to mime))

internal fun shareAudioFiles(host: Activity, attachments: List<Pair<Uri, String>>) {
    require(attachments.size > 1)
    openAudioShare(host, attachments)
}

private fun openAudioShare(host: Activity, attachments: List<Pair<Uri, String>>) {
    val uris = ArrayList(attachments.map { (uri, mime) ->
        require(uri.scheme == ContentResolver.SCHEME_CONTENT && !uri.authority.isNullOrEmpty())
        require(mime.startsWith("audio/"))
        uri
    })
    require(uris.toSet().size == uris.size)
    val mime = attachments.first().second.takeIf { first -> attachments.all { it.second == first } }
        ?: "audio/*"
    val multiple = uris.size > 1
    val send = Intent(if (multiple) Intent.ACTION_SEND_MULTIPLE else Intent.ACTION_SEND).apply {
        type = mime
        if (multiple) putParcelableArrayListExtra(Intent.EXTRA_STREAM, uris)
        else putExtra(Intent.EXTRA_STREAM, uris.first())
        clipData = ClipData(null, arrayOf(mime), ClipData.Item(uris.first())).apply {
            for (index in 1 until uris.size) addItem(ClipData.Item(uris[index]))
        }
        addFlags(Intent.FLAG_GRANT_READ_URI_PERMISSION)
    }
    host.startActivity(Intent.createChooser(send, null))
}
