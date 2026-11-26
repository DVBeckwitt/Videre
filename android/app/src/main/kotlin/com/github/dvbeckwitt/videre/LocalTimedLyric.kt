package com.github.dvbeckwitt.videre

internal data class LocalTimedLyric(
    val startMs: Long,
    val endMs: Long?,
    val text: String,
    val language: String? = null,
    val voice: String? = null,
    val role: String? = null,
    val translations: List<LocalLyricTranslation> = emptyList(),
    val words: List<LocalLyricWord> = emptyList(),
) {
    fun channelValue(): Map<String, Any> = buildMap {
        put("startMs", startMs)
        endMs?.let { put("endMs", it) }
        put("text", text)
        language?.let { put("language", it) }
        voice?.let { put("voice", it) }
        role?.let { put("role", it) }
        if (translations.isNotEmpty()) put("translations", translations.map { translation ->
            buildMap {
                put("text", translation.text)
                translation.language?.let { put("language", it) }
            }
        })
        if (words.isNotEmpty()) put("words", words.map {
            mapOf("startMs" to it.startMs, "startOffset" to it.startOffset, "endOffset" to it.endOffset)
        })
    }
}

internal data class LocalLyricTranslation(val text: String, val language: String? = null)

internal data class LocalLyricWord(val startMs: Long, val startOffset: Int, val endOffset: Int)
