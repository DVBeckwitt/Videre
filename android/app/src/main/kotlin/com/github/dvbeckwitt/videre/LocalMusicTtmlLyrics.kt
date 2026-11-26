package com.github.dvbeckwitt.videre

import java.io.StringReader
import java.math.BigDecimal
import javax.xml.XMLConstants
import javax.xml.parsers.ParserConfigurationException
import javax.xml.parsers.SAXParserFactory
import org.xml.sax.Attributes
import org.xml.sax.InputSource
import org.xml.sax.SAXException
import org.xml.sax.SAXParseException
import org.xml.sax.helpers.DefaultHandler

internal object LocalMusicTtmlLyrics {
    private const val TTML = "http://www.w3.org/ns/ttml"
    private const val METADATA = "$TTML#metadata"
    private const val PARAMETER = "$TTML#parameter"
    private const val ITUNES = "http://itunes.apple.com/lyric-ttml-extensions"
    private const val APPLE_METADATA = "http://music.apple.com/lyric-ttml-internal"
    private const val MAX_CHARACTERS = 128 * 1024
    private const val MAX_DEPTH = 32
    private const val MAX_ELEMENTS = 10000
    private const val MAX_CUES = 3000
    private const val MAX_CUE_METADATA_CHARACTERS = 256
    private const val MAX_TIME_MS = 7 * 24 * 60 * 60 * 1000L

    private val clock = Regex("""(?:(\d{2,3}):)?(\d{1,2}):([0-5]\d)(?:\.(\d{1,9}))?""")
    private val offset = Regex("""(\d{1,9}(?:\.\d{1,9})?)(h|m|s|ms)?""")
    private val spaces = Regex("""[ \r\n\t]+""")

    fun parse(text: String): List<LocalTimedLyric> {
        // XML has one literal spelling for a document type declaration. Reject
        // it before handing untrusted local input to a parser on any SDK.
        if (text.length > MAX_CHARACTERS || "<!DOCTYPE" in text) return emptyList()
        return try {
            val document = XmlTree()
            val reader = SAXParserFactory.newInstance().apply { isNamespaceAware = true }
                .newSAXParser().xmlReader
            reader.contentHandler = document
            reader.errorHandler = document
            reader.setEntityResolver { _, _ -> throw SAXException("External entities are disabled") }
            reader.parse(InputSource(StringReader(text)))
            document.root?.let { LyricsDocument(it, document.appleTiming).cues() }.orEmpty()
        } catch (_: SAXException) {
            emptyList()
        } catch (_: ParserConfigurationException) {
            emptyList()
        }
    }

    private sealed interface Part
    private data class Characters(val text: String) : Part
    private class Element(val namespace: String, val name: String, attributes: Attributes) : Part {
        private val attrs = buildMap {
            for (i in 0 until attributes.length) {
                put(attributes.getURI(i) to attributes.getLocalName(i), attributes.getValue(i))
            }
        }
        val parts = mutableListOf<Part>()
        fun attr(name: String, namespace: String = ""): String? = attrs[namespace to name]
        fun children(namespace: String, name: String): List<Element> =
            parts.filterIsInstance<Element>().filter { it.namespace == namespace && it.name == name }
    }

    private class XmlTree : DefaultHandler() {
        var root: Element? = null
            private set
        var appleTiming = false
            private set
        private val parents = mutableListOf<Element>()
        private var count = 0

        override fun startPrefixMapping(prefix: String, uri: String) {
            if (uri == ITUNES || uri == APPLE_METADATA) appleTiming = true
        }

        override fun startElement(uri: String, localName: String, qName: String, atts: Attributes) {
            if (parents.size >= MAX_DEPTH || ++count > MAX_ELEMENTS) {
                throw SAXException("TTML document is too complex")
            }
            val node = Element(uri, localName, atts)
            val parent = parents.lastOrNull()
            if (parent == null) root = node else parent.parts.add(node)
            parents.add(node)
        }

        override fun endElement(uri: String, localName: String, qName: String) {
            parents.removeAt(parents.lastIndex)
        }

        override fun characters(ch: CharArray, start: Int, length: Int) {
            parents.lastOrNull()?.parts?.add(Characters(String(ch, start, length)))
        }

        override fun error(error: SAXParseException) = throw error
        override fun fatalError(error: SAXParseException) = throw error
    }

    private data class Timing(val start: Long = 0, val end: Long? = null, val timed: Boolean = false)

    private data class Style(
        val language: String? = null,
        val agent: String? = null,
        val role: String? = null,
        val preserveSpace: Boolean = false,
    ) {
        val translation: Boolean
            get() = role?.split(spaces).orEmpty().any { it == "translation" || it == "x-translation" }
        val romanization: Boolean
            get() = role?.split(spaces).orEmpty().contains("x-roman")

        fun descend(node: Element): Style {
            val suppliedLanguage = node.attr("lang", XMLConstants.XML_NS_URI)
            return Style(
                language = if (suppliedLanguage == null) language else boundedMetadata(suppliedLanguage),
                agent = boundedMetadata(node.attr("agent", METADATA) ?: node.attr("agent")) ?: agent,
                role = boundedMetadata(node.attr("role", METADATA) ?: node.attr("role")) ?: role,
                preserveSpace = when (node.attr("space", XMLConstants.XML_NS_URI)) {
                    "preserve" -> true
                    "default" -> false
                    else -> preserveSpace
                },
            )
        }
    }

    private fun boundedMetadata(value: String?): String? {
        val trimmed = value?.trim()?.ifEmpty { null } ?: return null
        if (trimmed.length > MAX_CUE_METADATA_CHARACTERS) {
            throw SAXException("TTML cue metadata is too long")
        }
        return trimmed
    }

    private class LyricsDocument(private val root: Element, private val appleTiming: Boolean) {
        private val namespace = root.namespace
        private val agents = mutableMapOf<String, String>()
        private val translations = mutableMapOf<String, MutableList<LocalLyricTranslation>>()
        private val lines = mutableListOf<ParsedLine>()

        fun cues(): List<LocalTimedLyric> {
            if (root.name != "tt" || namespace !in listOf(TTML, "")) return emptyList()
            if (root.attr("timeBase", PARAMETER)?.let { it != "media" } == true) return emptyList()

            val style = Style().descend(root)
            for (head in root.children(namespace, "head")) {
                readHead(head, style.descend(head))
            }
            val body = root.children(namespace, "body").singleOrNull() ?: return emptyList()
            readContainer(body, Timing(), style)
            return resolveTranslations()
        }

        private fun readHead(node: Element, style: Style) {
            for (child in node.parts.filterIsInstance<Element>()) {
                when {
                    child.namespace == METADATA && child.name == "agent" -> {
                        val id = boundedMetadata(child.attr("id", XMLConstants.XML_NS_URI))
                        val names = child.children(METADATA, "name")
                        val name = (names.firstOrNull { it.attr("type") == "full" }
                            ?: names.firstOrNull())?.let { boundedMetadata(text(it, style.descend(it))) }
                        if (!id.isNullOrEmpty() && !name.isNullOrEmpty()) agents.putIfAbsent(id, name)
                    }
                    child.namespace == APPLE_METADATA && child.name == "translations" -> {
                        for (translation in child.children(APPLE_METADATA, "translation")) {
                            val translatedStyle = style.descend(child).descend(translation)
                            for (entry in translation.children(APPLE_METADATA, "text")) {
                                val key = entry.attr("for")?.trim()?.takeIf(String::isNotEmpty) ?: continue
                                val entryStyle = translatedStyle.descend(entry)
                                val value = text(entry, entryStyle)
                                if (value.isNotBlank()) translations.getOrPut(key, ::mutableListOf)
                                    .add(LocalLyricTranslation(value, entryStyle.language))
                            }
                        }
                    }
                    else -> readHead(child, style.descend(child))
                }
            }
        }

        private fun readContainer(node: Element, parentTiming: Timing, parentStyle: Style) {
            if (node.attr("timeContainer")?.let { it != "par" } == true) {
                throw SAXException("Unsupported TTML time container")
            }
            val timing = timing(node, parentTiming)
                .copy(timed = parentTiming.timed || node.attr("begin") != null)
            val style = parentStyle.descend(node)
            for (child in node.parts.filterIsInstance<Element>()) {
                if (child.namespace != namespace) continue
                when (child.name) {
                    "div" -> readContainer(child, timing, style)
                    "p" -> readLine(child, timing, style)
                }
            }
        }

        private fun readLine(node: Element, parentTiming: Timing, parentStyle: Style) {
            val style = parentStyle.descend(node)
            if (style.romanization) return
            val timing = timing(node, parentTiming)
            val line = LyricLine(timing, style, node.attr("key", ITUNES))
            val parts = mutableListOf(line)
            append(node, timing, style, line, parts)
            for (part in parts) {
                val cue = part.finish(voice(part.style.agent)) ?: continue
                if (lines.size >= MAX_CUES) throw SAXException("Too many TTML cues")
                lines.add(ParsedLine(cue, part.key, part.style.translation))
            }
        }

        private fun append(node: Element, timing: Timing, style: Style, line: LyricLine, lines: MutableList<LyricLine>) {
            for (part in node.parts) {
                when (part) {
                    is Characters -> line.append(part.text, style)
                    is Element -> {
                        if (part.namespace != namespace) continue
                        when (part.name) {
                            "br" -> line.text.newline(style.preserveSpace)
                            "span" -> appendSpan(part, timing, style, line, lines)
                        }
                    }
                }
            }
        }

        private fun appendSpan(node: Element, parentTiming: Timing, parentStyle: Style, line: LyricLine, lines: MutableList<LyricLine>) {
            val style = parentStyle.descend(node)
            if (style.romanization) return
            if (style.translation && !line.style.translation) {
                val value = text(node, style)
                if (value.isNotBlank()) line.translations.add(LocalLyricTranslation(value, style.language))
                return
            }
            val timing = timing(node, parentTiming)
            val target = if (style.agent != line.style.agent || style.role != line.style.role) {
                LyricLine(timing, style).also { lines.add(it) }
            } else {
                line
            }
            val from = target.text.length
            val firstWord = target.words.size
            append(node, timing, style, target, lines)
            if (node.attr("begin") != null && target.words.size == firstWord) {
                target.text.range(from)?.let { (start, end) ->
                    target.words.add(LocalLyricWord(timing.start, start, end))
                }
            }
        }

        private fun voice(agent: String?): String? = boundedMetadata(
            agent?.split(spaces)?.joinToString(", ") { agents[it] ?: it },
        )

        private fun text(node: Element, style: Style): String {
            val rendered = LineText()
            fun visit(element: Element, current: Style) {
                for (part in element.parts) {
                    when (part) {
                        is Characters -> rendered.append(part.text, current.preserveSpace)
                        is Element -> if (part.namespace == namespace && part.name == "br") {
                            rendered.newline(current.preserveSpace)
                        } else {
                            visit(part, current.descend(part))
                        }
                    }
                }
            }
            visit(node, style)
            return rendered.finish(style.preserveSpace)
        }

        private fun resolveTranslations(): List<LocalTimedLyric> {
            val sources = lines.withIndex().filterNot { it.value.translated }
            val sourcesByTime = sources.groupBy { it.value.cue.startMs }
            val sourcesByTimeAndVoice = sources.groupBy {
                it.value.cue.startMs to it.value.cue.voice
            }
            val keyCounts = sources.mapNotNull { it.value.key }.groupingBy { it }.eachCount()
            val timedTranslations = mutableMapOf<Int, MutableList<LocalLyricTranslation>>()
            val attached = mutableSetOf<Int>()
            for ((index, line) in lines.withIndex()) {
                if (!line.translated) continue
                val cue = line.cue
                val target = if (cue.voice == null) sourcesByTime[cue.startMs]?.singleOrNull()
                else sourcesByTimeAndVoice[cue.startMs to cue.voice]?.singleOrNull()
                if (target != null) {
                    timedTranslations.getOrPut(target.index, ::mutableListOf)
                        .add(LocalLyricTranslation(cue.text, cue.language))
                    attached.add(index)
                }
            }
            return lines.mapIndexedNotNull { index, (cue, key, translated) ->
                if (index in attached) return@mapIndexedNotNull null
                val keyed = if (!translated && keyCounts[key] == 1) translations[key].orEmpty() else emptyList()
                cue.copy(translations =
                    (cue.translations + keyed + timedTranslations[index].orEmpty()).distinct())
            }.sortedBy(LocalTimedLyric::startMs)
        }

        private fun timing(node: Element, parent: Timing): Timing {
            val begin = node.attr("begin")
            val duration = node.attr("dur")?.let(::parseTime)
            val start = begin?.let { timelineTime(it, parent) } ?: parent.start
            val stop = node.attr("end")?.let { timelineTime(it, parent) }
            val bound = listOfNotNull(parent.end, stop, duration?.let { start + it }).minOrNull()
            if (start < parent.start || start > MAX_TIME_MS ||
                (bound != null && (bound <= start || bound > MAX_TIME_MS))
            ) throw SAXException("Invalid TTML interval")
            return Timing(start, bound, parent.timed || begin != null || stop != null || duration != null)
        }

        // Apple clocks use recording time. Explicit TTML offset units use parent time.
        private fun timelineTime(raw: String, parent: Timing): Long {
            val value = raw.trim()
            val time = parseTime(value)
            return if (appleTiming && value.last().isDigit()) time else parent.start + time
        }

        private fun parseTime(raw: String): Long {
            val value = raw.trim()
            clock.matchEntire(value)?.let { match ->
                val (_, hours, minutes, seconds, fraction) = match.groupValues
                val mins = minutes.toLong()
                if (mins >= 60) throw SAXException("Invalid TTML clock")
                return ((hours.toLongOrNull() ?: 0) * 3600 + mins * 60 + seconds.toLong()) * 1000 +
                    fraction.take(3).padEnd(3, '0').toLong()
            }
            offset.matchEntire(value)?.let { match ->
                val (_, amount, unit) = match.groupValues
                val multiplier = when (unit) {
                    "h" -> 3600000L
                    "m" -> 60000L
                    "s" -> 1000L
                    "ms" -> 1L
                    "" -> if (appleTiming) 1000L else throw SAXException("Invalid TTML offset")
                    else -> throw SAXException("Invalid TTML offset")
                }
                val millis = BigDecimal(amount).multiply(BigDecimal.valueOf(multiplier)).toLong()
                if (millis <= MAX_TIME_MS) return millis
            }
            throw SAXException("Invalid or unsupported TTML time")
        }
    }

    private data class ParsedLine(val cue: LocalTimedLyric, val key: String?, val translated: Boolean)

    private class LyricLine(val timing: Timing, val style: Style, val key: String? = null) {
        val text = LineText()
        val words = mutableListOf<LocalLyricWord>()
        val translations = mutableListOf<LocalLyricTranslation>()
        private val languages = mutableSetOf<String?>()

        fun append(value: String, style: Style) {
            text.append(value, style.preserveSpace)
            if (value.isNotBlank()) languages.add(style.language)
        }

        fun finish(voice: String?): LocalTimedLyric? {
            val value = text.finish(style.preserveSpace)
            if (value.isBlank()) return null
            val start = if (timing.timed) timing.start else words.minOfOrNull(LocalLyricWord::startMs) ?: return null
            val validWords = words.filter { it.endOffset <= value.length }
            val orderedWords = validWords.zipWithNext().all { (a, b) ->
                a.startMs <= b.startMs && a.endOffset <= b.startOffset
            }
            // A single cue can carry one language. Keep mixed text in source
            // order and use the paragraph language when it contains several.
            val language = if (languages.size == 1) languages.first() else style.language
            return LocalTimedLyric(
                start, timing.end, value, language, voice, style.role,
                translations.toList(), if (orderedWords) validWords else emptyList(),
            )
        }
    }

    private class LineText {
        private val buffer = StringBuilder()
        val length get() = buffer.length

        fun append(value: String, preserve: Boolean) {
            if (preserve) {
                buffer.append(value)
                return
            }
            for (char in value) {
                if (char in " \t\r\n") {
                    if (buffer.isNotEmpty() && buffer.last() !in " \t\r\n") buffer.append(' ')
                } else {
                    buffer.append(char)
                }
            }
        }

        fun newline(preserve: Boolean) {
            if (!preserve && buffer.lastOrNull() == ' ') buffer.setLength(buffer.length - 1)
            buffer.append('\n')
        }

        fun range(from: Int): Pair<Int, Int>? {
            var start = from
            var end = buffer.length
            while (start < end && buffer[start].isWhitespace()) start++
            while (end > start && buffer[end - 1].isWhitespace()) end--
            return if (start < end) start to end else null
        }

        fun finish(preserve: Boolean): String =
            if (preserve) buffer.toString() else buffer.toString().trimEnd(' ', '\t', '\r', '\n')
    }
}
