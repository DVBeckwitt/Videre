package com.github.dvbeckwitt.videre

import org.json.JSONArray
import org.json.JSONException
import org.json.JSONObject

internal data class LocalMusicRoot(
    val uri: String,
    val name: String,
    val selectionId: String?,
    val ownsRead: Boolean = false,
    val needsReapproval: Boolean = false,
) {
    fun channelValue(): Map<String, Any?> = mapOf(
        "uri" to uri,
        "name" to name,
        "selectionId" to selectionId,
        "needsReapproval" to needsReapproval,
    )

    fun toJson() = JSONObject(channelValue()).put("ownsRead", ownsRead)
}

internal data class LocalMusicRoots(val entries: List<LocalMusicRoot>, val selectionId: String?) {
    fun find(uri: String?) = entries.firstOrNull { it.uri == uri }

    fun withRoot(root: LocalMusicRoot): LocalMusicRoots {
        val roots = if (find(root.uri) == null) entries + root else entries.map {
            if (it.uri == root.uri) root else it
        }
        return LocalMusicRoots(roots, if (entries.isEmpty()) root.selectionId else selectionId)
    }

    fun without(removed: List<LocalMusicRoot>): LocalMusicRoots {
        val remaining = entries - removed.toSet()
        return if (remaining.isEmpty()) empty else copy(entries = remaining)
    }

    fun channelValue(): Map<String, Any?> = mapOf(
        "roots" to entries.map(LocalMusicRoot::channelValue),
        "selectionId" to selectionId,
    )

    fun toJson(): String = JSONObject()
        .put("selectionId", selectionId)
        .put("roots", JSONArray(entries.map(LocalMusicRoot::toJson)))
        .toString()

    companion object {
        const val KEY = "rootConfiguration"
        private val empty = LocalMusicRoots(emptyList(), null)

        fun read(saved: Map<String, *>): LocalMusicRoots {
            val stored = saved[KEY] as? String
            if (stored == null) {
                // Retain the old cache and playback approval, including a legacy null ID.
                val uri = saved["uri"] as? String ?: return empty
                val selectionId = saved["selectionId"] as? String
                val root = LocalMusicRoot(uri, saved["name"] as? String ?: "Music folder", selectionId,
                    ownsRead = saved["ownsRead"] == true, needsReapproval = saved["needsReapproval"] == true)
                return LocalMusicRoots(listOf(root), selectionId)
            }
            return try {
                val configuration = JSONObject(stored)
                val roots = configuration.getJSONArray("roots")
                val entries = List(roots.length()) { index ->
                    val root = roots.getJSONObject(index)
                    LocalMusicRoot(root.getString("uri"), root.getString("name"),
                        root.selectionId(), root.getBoolean("ownsRead"), root.getBoolean("needsReapproval"))
                }
                if (entries.isEmpty()) empty else LocalMusicRoots(entries, configuration.selectionId())
            } catch (_: JSONException) {
                empty
            }
        }

        private fun JSONObject.selectionId(): String? = opt("selectionId") as? String
    }
}
