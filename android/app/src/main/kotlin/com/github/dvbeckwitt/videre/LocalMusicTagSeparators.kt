package com.github.dvbeckwitt.videre

internal const val LOCAL_MUSIC_TAG_SEPARATOR_OPTIONS = ",;/+&"

/** Real tag lists take precedence. Delimiter escaping applies only to a single string. */
internal fun localMusicTagList(values: List<String>, fallback: String?, separators: String): List<String> {
    if (values.size > 1) return values
    val text = values.firstOrNull() ?: localCollectionTag(fallback) ?: return emptyList()
    if (separators.isEmpty()) return listOf(text)

    val result = mutableListOf<String>()
    val part = StringBuilder()
    var index = 0
    while (index < text.length) {
        val character = text[index++]
        when {
            character == '\\' && index < text.length &&
                (text[index] in separators || text[index] == '\\') -> part.append(text[index++])
            character in separators -> {
                localCollectionTag(part.toString())?.let(result::add)
                part.clear()
            }
            else -> part.append(character)
        }
    }
    localCollectionTag(part.toString())?.let(result::add)
    return result
}
