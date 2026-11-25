package com.github.dvbeckwitt.videre

import android.database.Cursor
import org.json.JSONArray

internal const val MAX_LOCAL_MUSIC_FOLDER_DEPTH = 64
private const val MAX_FOLDER_LABEL_LENGTH = 1024
private val folderKey = Regex("[0-9a-f]{64}")
private val volumeName = Regex("[A-Za-z0-9_-]{1,128}")
private const val LOCATION_DOMAIN = "videre-device-music-folder-v1"
private const val SEPARATOR = " / "

internal data class LocalMusicFolderLocation(val key: String, val label: String) {
    val channelValue get() = mapOf("key" to key, "label" to label)

    companion object {
        fun fromJson(value: JSONArray?): List<LocalMusicFolderLocation> {
            if (value == null || value.length() > MAX_LOCAL_MUSIC_FOLDER_DEPTH) return emptyList()
            val seen = mutableSetOf<String>()
            return List(value.length()) { position ->
                val row = value.optJSONObject(position) ?: return emptyList()
                val key = row.opt("key") as? String ?: return emptyList()
                val label = row.opt("label") as? String ?: return emptyList()
                if (!folderKey.matches(key) || !seen.add(key) || !usableBreadcrumb(label)) return emptyList()
                LocalMusicFolderLocation(key, label)
            }
        }
    }
}

internal fun mediaMusicFolderLocations(volume: String, relative: String?): List<LocalMusicFolderLocation> {
    if (!volumeName.matches(volume) || volume in setOf("external", "internal") ||
        relative.isNullOrEmpty() || relative.length > MAX_FOLDER_LABEL_LENGTH) return emptyList()
    val components = relative.removeSuffix("/").split('/')
    if (components.size > MAX_LOCAL_MUSIC_FOLDER_DEPTH || components.any { folderName(it) == null }) return emptyList()
    val volumeLabel = if (volume == "external_primary") "Internal storage" else "Storage $volume"
    var label = volumeLabel
    val prefix = StringBuilder()
    val result = ArrayList<LocalMusicFolderLocation>(components.size)
    for (component in components) {
        if (prefix.isNotEmpty()) prefix.append('/')
        prefix.append(component)
        label += SEPARATOR + component.trim()
        if (label.length > MAX_FOLDER_LABEL_LENGTH) return emptyList()
        val key = localMusicVisibilityFingerprint(LOCATION_DOMAIN, "media", volume, prefix.toString())
        result.add(LocalMusicFolderLocation(key, label))
    }
    return result
}

internal fun safMusicFolderLocation(
    tree: String, documentId: String, displayName: String?, parent: LocalMusicFolderLocation?,
): LocalMusicFolderLocation? {
    if (tree.isEmpty() || documentId.isBlank()) return null
    val name = folderName(displayName) ?: return null
    val label = if (parent == null) name else parent.label + SEPARATOR + name
    if (label.length > MAX_FOLDER_LABEL_LENGTH) return null
    return LocalMusicFolderLocation(
        localMusicVisibilityFingerprint(LOCATION_DOMAIN, "saf", tree, documentId),
        label,
    )
}

internal fun positiveRecordingFlag(columnType: Int, value: Long?): Boolean =
    columnType == Cursor.FIELD_TYPE_INTEGER && (value ?: 0L) > 0L

private fun folderName(value: String?): String? = value
    ?.takeIf { it.none { char -> char == '/' || char == '\\' || char.isISOControl() } }
    ?.trim()?.takeIf {
        it.isNotEmpty() && it.length <= MAX_FOLDER_LABEL_LENGTH &&
            it != "." && it != ".." && !it.equals("<unknown>", ignoreCase = true)
    }

private fun usableBreadcrumb(label: String): Boolean =
    label.isNotEmpty() && label.length <= MAX_FOLDER_LABEL_LENGTH &&
        label.split(SEPARATOR).all { folderName(it) == it }
