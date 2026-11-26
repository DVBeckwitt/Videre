package com.github.dvbeckwitt.videre

import android.content.Context
import android.net.Uri
import android.os.Build
import android.os.Environment
import android.os.storage.StorageManager
import android.provider.DocumentsContract
import java.util.Locale

/** Location data for matching playlist text. Audio access still uses the index's content URIs. */
internal class M3uStorage(private val context: Context) {
    @Suppress("DEPRECATION")
    fun volumeRoots(): Map<String, String> = buildMap {
        put("primary", Environment.getExternalStorageDirectory().absolutePath)
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.R) {
            val manager = context.getSystemService(StorageManager::class.java)
            for (volume in manager?.storageVolumes.orEmpty()) {
                val name = volume.uuid?.let(::volumeName) ?: continue
                val root = volume.directory?.absolutePath ?: continue
                put(name, root)
            }
        }
    }

    fun documentLocation(uri: Uri, roots: Map<String, String>): Map<String, String>? {
        if (uri.scheme == "file" && uri.authority.isNullOrEmpty()) {
            return absoluteLocation(uri.path, roots)
        }
        if (uri.scheme != "content") return null
        val id = runCatching { DocumentsContract.getDocumentId(uri) }.getOrNull() ?: return null
        return when (uri.authority) {
            EXTERNAL_STORAGE -> location(id.substringBefore(':'), id.substringAfter(':', ""))
            // The platform Downloads provider uses an opaque ID for some documents.
            DOWNLOADS -> if (id.startsWith("raw:")) absoluteLocation(id.removePrefix("raw:"), roots) else null
            else -> null
        }
    }

    fun musicLocation(row: LocalMusicRow, system: Boolean, roots: Map<String, String>): Map<String, String>? {
        if (!system) return documentLocation(Uri.parse(row.uri), roots)
        val parent = row.parentKey ?: return null
        if ('/' in row.fileName || '\\' in row.fileName) return null
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.Q) {
            return absoluteLocation("$parent/${row.fileName}", roots)
        }
        if (':' !in parent) return null
        val path = parent.substringAfter(':').trimEnd('/')
        return location(parent.substringBefore(':'), if (path.isEmpty()) row.fileName else "$path/${row.fileName}")
    }

    private fun absoluteLocation(path: String?, roots: Map<String, String>): Map<String, String>? {
        if (path == null) return null
        for ((volume, root) in roots) {
            if (path.startsWith("$root/")) return location(volume, path.removePrefix("$root/"))
        }
        return null
    }

    private fun location(volume: String, path: String): Map<String, String>? {
        val name = volumeName(volume) ?: return null
        if (path.isEmpty() || path.length > 4096 || path.any { it == '\\' || it.isISOControl() } ||
            path.split('/').any { it.isEmpty() || it == "." || it == ".." }) return null
        return mapOf("volume" to name, "path" to path)
    }

    private fun volumeName(name: String): String? {
        val lower = name.lowercase(Locale.ROOT)
        if (lower == "external_primary" || lower == "primary") return "primary"
        return lower.takeIf { removableVolume.matches(it) }
    }

    companion object {
        const val EXTERNAL_STORAGE = "com.android.externalstorage.documents"
        private const val DOWNLOADS = "com.android.providers.downloads.documents"
        private val removableVolume =
            Regex("(?:[0-9a-f]{4}-[0-9a-f]{4}|[0-9a-f]{8}(?:-[0-9a-f]{4}){3}-[0-9a-f]{12})")
    }
}
