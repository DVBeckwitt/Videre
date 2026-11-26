package com.github.dvbeckwitt.videre

import android.content.Context
import android.content.Intent
import android.content.pm.PackageManager
import android.net.Uri
import android.os.Process
import android.provider.OpenableColumns
import java.net.URI

internal fun openedAudioContentUri(raw: String?): URI? {
    if (raw == null || raw.length !in 1..32768) return null
    return runCatching { URI(raw) }.getOrNull()?.takeIf {
        it.scheme == "content" && !it.rawAuthority.isNullOrEmpty() && !it.rawPath.isNullOrEmpty() &&
            it.rawQuery == null && it.rawFragment == null
    }
}

internal fun incomingAudioPayload(
    action: String?, data: String?, mimeType: String?, hasReadGrant: () -> Boolean,
): IncomingAudioPayload? {
    if (action != Intent.ACTION_VIEW || mimeType?.startsWith("audio/", ignoreCase = true) != true) return null
    val content = openedAudioContentUri(data) ?: return null
    if (!LocalMusicCatalog.isAudio(mimeType, content.path.substringAfterLast('/')) || !hasReadGrant()) return null
    return IncomingAudioPayload(content.toString())
}

internal fun hasOpenedAudioReadGrant(context: Context, uri: Uri): Boolean =
    context.checkUriPermission(uri, Process.myPid(), Process.myUid(), Intent.FLAG_GRANT_READ_URI_PERMISSION) ==
        PackageManager.PERMISSION_GRANTED

internal fun openedAudioTitle(context: Context, uri: Uri): String? {
    val resolver = context.contentResolver
    val pathName = uri.lastPathSegment?.let(::audioDisplayName).orEmpty()
    val displayName = runCatching {
        resolver.query(uri, arrayOf(OpenableColumns.DISPLAY_NAME), null, null, null)?.use {
            if (it.moveToFirst()) it.getString(0)?.let(::audioDisplayName) else null
        }
    }.getOrNull()
    val type = runCatching { resolver.getType(uri) }.getOrNull().orEmpty()
    val fileName = displayName?.takeUnless(String::isBlank) ?: pathName
    // A provider may report a playlist using audio/* or give it an opaque URI.
    if (!LocalMusicCatalog.isAudio("audio/*", pathName) || !LocalMusicCatalog.isAudio(type, fileName)) return null
    resolver.openAssetFileDescriptor(uri, "r")?.close() ?: return null
    return LocalMusicCatalog.fallbackTitle(fileName).ifBlank { "Audio" }
}

private fun audioDisplayName(value: String): String = value.substringAfterLast('/').substringAfterLast('\\')
    .take(1024).filterNot { it.isISOControl() || Character.getType(it) == Character.FORMAT.toInt() }.trim()
