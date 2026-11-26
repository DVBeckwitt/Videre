package com.github.dvbeckwitt.videre

internal object LocalMusicSrtLyrics {
    private const val MAX_CUES = 4096
    private const val CLOCK = """([0-9]{2,6}):([0-5][0-9]):([0-5][0-9])[,.]([0-9]{3})"""
    private val timing = Regex(
        """$CLOCK[ \t]+-->[ \t]+$CLOCK(?:[ \t]+X1:[0-9]+[ \t]+X2:[0-9]+[ \t]+Y1:[0-9]+[ \t]+Y2:[0-9]+)?""",
    )
    private val index = Regex("[0-9]+")
    private val lineBreak = Regex("""<br\s*/?>""", RegexOption.IGNORE_CASE)
    private val formatting = Regex("""</?(?:b|i|u|s|font(?:[ \t]+[^<>]*)?)>""", RegexOption.IGNORE_CASE)

    fun parse(text: String): List<LocalTimedLyric> {
        val cues = mutableListOf<LocalTimedLyric>()
        val lines = text.lineSequence().iterator()
        while (lines.hasNext()) {
            var line = lines.next().trim()
            if (line.isEmpty()) continue
            if (index.matches(line) && lines.hasNext()) line = lines.next().trim()
            val times = timing.matchEntire(line) ?: return emptyList()
            val start = millis(times.groupValues, 1)
            val end = millis(times.groupValues, 5)
            if (end <= start || cues.size >= MAX_CUES) return emptyList()
            val body = buildString {
                while (lines.hasNext()) {
                    val lyric = lines.next()
                    if (lyric.isBlank()) break
                    if (isNotEmpty()) append('\n')
                    append(lyric)
                }
            }.replace(lineBreak, "\n").replace(formatting, "").trim()
            if (body.isEmpty()) return emptyList()
            cues.add(LocalTimedLyric(start, end, body))
        }
        return cues.sortedBy { it.startMs }
    }

    private fun millis(groups: List<String>, index: Int): Long =
        ((groups[index].toLong() * 60 + groups[index + 1].toLong()) * 60 +
            groups[index + 2].toLong()) * 1000 + groups[index + 3].toLong()
}
