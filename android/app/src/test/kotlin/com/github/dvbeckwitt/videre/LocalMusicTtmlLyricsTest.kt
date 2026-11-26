package com.github.dvbeckwitt.videre

import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Test

class LocalMusicTtmlLyricsTest {
    @Test fun retainsSingerNamesAndOnlyExplicitInlineTranslations() {
        val lyrics = LocalMusicTtmlLyrics.parse("""
            <tt xmlns="http://www.w3.org/ns/ttml" xmlns:m="http://www.w3.org/ns/ttml#metadata" xml:lang="ja">
              <head><metadata>
                <m:agent xml:id="one" type="person"><m:name type="full">Aki</m:name></m:agent>
                <m:agent xml:id="two" type="person"><m:name type="full">Bea</m:name></m:agent>
              </metadata></head>
              <body><div>
                <p begin="00:00:01.000" end="00:00:02.000" m:agent="one">おはよう<span m:role="x-translation" xml:lang="en">Good morning</span><span m:role="x-roman">ohayou</span></p>
                <p begin="00:00:01.000" end="00:00:02.000" m:agent="two" xml:lang="en">Good <span xml:lang="fr">soir</span> again</p>
                <p begin="2s" dur="1s" m:agent="one two" m:role="song">一緒に</p>
                <p begin="3s" m:agent="two"><span xml:lang="fr">Salut</span></p>
              </div></body>
            </tt>
        """.trimIndent())

        assertEquals(listOf(
            LocalTimedLyric(1000, 2000, "おはよう", "ja", "Aki",
                translations = listOf(LocalLyricTranslation("Good morning", "en"))),
            LocalTimedLyric(1000, 2000, "Good soir again", "en", "Bea"),
            LocalTimedLyric(2000, 3000, "一緒に", "ja", "Aki, Bea", "song"),
            LocalTimedLyric(3000, null, "Salut", "fr", "Bea"),
        ), lyrics)
    }

    @Test fun resolvesRelativeTimingAndUtf16WordRangesWhilePreservingBreaks() {
        val lyrics = LocalMusicTtmlLyrics.parse("""
            <t:tt xmlns:t="http://www.w3.org/ns/ttml">
              <t:body begin="1s"><t:div begin="2s">
                <t:p begin="1.25s" dur="2s">Still <t:span begin="200ms" end="1s">🎵</t:span><t:br/>now &amp; again</t:p>
              </t:div></t:body>
            </t:tt>
        """.trimIndent())

        assertEquals(listOf(
            LocalTimedLyric(4250, 6250, "Still 🎵\nnow & again",
                words = listOf(LocalLyricWord(4450, 6, 8))),
        ), lyrics)
    }

    @Test fun readsAppleAbsoluteClocksBackgroundVoicesAndKeyedTranslations() {
        val lyrics = LocalMusicTtmlLyrics.parse("""
            <tt xmlns="http://www.w3.org/ns/ttml" xmlns:m="http://www.w3.org/ns/ttml#metadata"
                xmlns:a="http://itunes.apple.com/lyric-ttml-extensions" xml:lang="ja">
              <head><metadata>
                <iTunesMetadata xmlns="http://music.apple.com/lyric-ttml-internal">
                  <translations><translation xml:lang="es"><text for="L1">Olas</text></translation></translations>
                  <transliterations><transliteration xml:lang="ja-Latn"><text for="L1">nami</text></transliteration></transliterations>
                </iTunesMetadata>
              </metadata></head>
              <body dur="00:05.250">
                <div begin="00:01.500" end="00:05.250">
                  <p begin="00:01.500" end="00:05.250" a:key="L1" m:agent="v1"><span begin="1.500" end="2.250">波</span><span begin="00:03.250" end="00:04.250" m:agent="v2" m:role="x-bg">海</span></p>
                </div>
              </body>
            </tt>
        """.trimIndent())

        assertEquals(listOf(
            LocalTimedLyric(1500, 5250, "波", "ja", "v1",
                translations = listOf(LocalLyricTranslation("Olas", "es")),
                words = listOf(LocalLyricWord(1500, 0, 1))),
            LocalTimedLyric(3250, 4250, "海", "ja", "v2", "x-bg",
                words = listOf(LocalLyricWord(3250, 0, 1))),
        ), lyrics)
    }

    @Test fun associatesExplicitTimedTranslationsWithAnUnambiguousCue() {
        val lyrics = LocalMusicTtmlLyrics.parse("""
            <tt xmlns:m="http://www.w3.org/ns/ttml#metadata" xml:lang="it"><body><div>
              <p begin="1s" end="2s" m:agent="one">Ciao</p>
              <p begin="1s" end="2s" m:agent="two">Buongiorno</p>
              <p begin="1s" end="2s" m:role="translation" m:agent="two" xml:lang="en">Good morning</p>
              <p begin="1s" end="2s" m:role="translation" xml:lang="en">Ambiguous</p>
            </div></body></tt>
        """.trimIndent())

        assertEquals(listOf(
            LocalTimedLyric(1000, 2000, "Ciao", "it", "one"),
            LocalTimedLyric(1000, 2000, "Buongiorno", "it", "two",
                translations = listOf(LocalLyricTranslation("Good morning", "en"))),
            LocalTimedLyric(1000, 2000, "Ambiguous", "en", role = "translation"),
        ), lyrics)
    }

    @Test fun usesImplicitStartForTimedCuesAndKeepsMillisecondPrecision() {
        val lyrics = LocalMusicTtmlLyrics.parse("""
            <tt><body dur="5s"><div>
              <p end="1.001s">First</p>
              <p>Untimed</p>
              <p begin="1.001s" dur="999ms">Second</p>
            </div></body></tt>
        """.trimIndent())

        assertEquals(listOf(
            LocalTimedLyric(0, 1001, "First"),
            LocalTimedLyric(1001, 2000, "Second"),
        ), lyrics)
    }

    @Test fun rejectsMalformedUnsupportedAndExcessiveInput() {
        val invalid = listOf(
            "<tt><body><p begin=\"1s\">broken</body></tt>",
            "<tt><body><p begin=\"1s\" end=\"1s\">empty interval</p></body></tt>",
            "<tt><body><p begin=\"00:82:30.000\">invalid time</p></body></tt>",
            "<tt><body><p begin=\"10f\">unsupported frame time</p></body></tt>",
            "<tt><body><p>untimed</p></body></tt>",
            "<!DOCTYPE tt [<!ENTITY expand 'unexpected'>]><tt><body><p begin=\"1s\">&expand;</p></body></tt>",
            "<other><body><p begin=\"1s\">wrong root</p></body></other>",
            "<tt><body>" + "<div>".repeat(40) + "<p begin=\"1s\">nested</p>" + "</div>".repeat(40) + "</body></tt>",
            "<tt><body><p begin=\"1s\">" + "x".repeat(128 * 1024) + "</p></body></tt>",
            "<tt xml:lang=\"" + "x".repeat(257) + "\"><body><p begin=\"1s\">Oversized language</p></body></tt>",
        )

        for (text in invalid) {
            assertTrue("Unexpected TTML cues for input starting with " + text.take(100),
                LocalMusicTtmlLyrics.parse(text).isEmpty())
        }
    }
}
