/*
 * Copyright (C) 2025-2026 Flow | A-EDev
 *
 * This file is part of Flow (https://github.com/Flow-Tube/Flow).
 */

package com.github.dvbeckwitt.videre.recommendations.video

import androidx.test.ext.junit.runners.AndroidJUnit4
import org.junit.Assert.assertTrue
import org.junit.Assert.assertFalse
import org.junit.Test
import org.junit.runner.RunWith

/**
 * Titles in scripts written without spaces split into real words. Runs on a device: the word
 * dictionaries live in the platform ICU data, which the JVM test runtime does not have.
 */
@RunWith(AndroidJUnit4::class)
class NeuroTextSegmentationTest {
    private val tokenizer = NeuroTokenizer()

    private fun assertTopics(
        title: String,
        vararg expected: String,
    ) {
        val tokens = tokenizer.tokenize(title)
        expected.forEach { assertTrue("$it not in $tokens for \"$title\"", it in tokens) }
    }

    @Test
    fun chineseTitlesSplitIntoWordsAndSeparateFormats() {
        // Current pinned key-spec 3 separates 教学 into the tutorial format,
        // and the pinned Chinese stop list removes 入门. The older upstream
        // Android fixture predated these rules; keep both assertions explicit.
        val title = "吉他教学零基础入门"
        assertTopics(title, "吉他", "基础")
        assertFalse("Format words must not become topics", "教学" in tokenizer.tokenize(title))
        assertFalse("Pinned stop words must be removed", "入门" in tokenizer.tokenize(title))
        assertTrue("Tutorial format must remain available", "tutorial" in tokenizer.chunk(title).formats)
    }

    @Test
    fun japaneseTitlesKeepContentWordsAndDropParticles() {
        val tokens = tokenizer.tokenize("ギターの弾き方を初心者向けに解説")
        assertTrue(tokens.toString(), "ギター" in tokens)
        assertTrue(tokens.toString(), tokens.none { it == "の" || it == "を" })
    }

    @Test
    fun thaiTitlesSplitIntoWords() = assertTopics("สอนเล่นกีตาร์สำหรับมือใหม่", "กีตาร์", "สำหรับ")

    @Test
    fun chineseChannelNamesGiveTheirTopicalWords() {
        // NeuroKeySpec 3 folds Traditional keys to Simplified for non-Japanese
        // viewers, as covered by upstream NeuroHanRunsTest and key_spec_golden.
        listOf("央視新聞" to "新闻", "央视新闻" to "新闻", "英文教室 科技" to "科技").forEach { (name, topic) ->
            val topics = tokenizer.tokenizeChannelName(name)
            assertTrue("$topic not in $topics for \"$name\"", topic in topics)
        }
        assertTrue(tokenizer.tokenizeChannelName("小明").isEmpty())
    }

    @Test
    fun spacedScriptsAreUntouched() = assertTopics("Pixel 10 Pro camera test", "pixel", "camera")
}
