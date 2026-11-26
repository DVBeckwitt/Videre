package com.github.dvbeckwitt.videre

internal enum class LocalMusicSkipReason(val code: String) {
    PLAYLIST("playlist"),
    UNSUPPORTED_TYPE("unsupportedType"),
    MISSING_DETAILS("missingDetails"),
}

/** Short-lived diagnostics for one scan of one approved root. */
internal class LocalMusicScanReport {
    private val files = mutableListOf<Map<String, String?>>()
    private var count = 0L

    fun add(name: String?, reason: LocalMusicSkipReason) {
        ++count
        if (files.size < MAX_FILES) {
            files.add(mapOf("name" to displayName(name), "reason" to reason.code))
        }
    }

    fun channelResult(tracks: List<Map<String, Any?>>): Map<String, Any> =
        mapOf("tracks" to tracks, "skippedFiles" to files, "skippedCount" to count)

    private fun displayName(name: String?): String? {
        val label = name?.trim()?.takeIf {
            it.isNotEmpty() && it != "." && it != ".." &&
                it.none { char -> char == '/' || char == '\\' || char == ':' || char.isISOControl() }
        } ?: return null
        return label.take(MAX_NAME_LENGTH).dropLastWhile(Char::isHighSurrogate).takeIf(String::isNotEmpty)
    }

    companion object {
        private const val MAX_FILES = 100
        private const val MAX_NAME_LENGTH = 160
    }
}
