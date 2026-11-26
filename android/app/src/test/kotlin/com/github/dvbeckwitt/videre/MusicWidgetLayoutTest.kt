package com.github.dvbeckwitt.videre

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

class MusicWidgetLayoutTest {
    @Test fun missingOrSmallBoundsUseCompactTransport() {
        assertEquals(MusicWidgetLayout.COMPACT, MusicWidgetLayout.forSize(0, 0))
        assertEquals(MusicWidgetLayout.COMPACT, MusicWidgetLayout.forSize(168, 110))
        assertEquals(MusicWidgetLayout.COMPACT, MusicWidgetLayout.forSize(263, 169))
        assertFalse(MusicWidgetLayout.COMPACT.hasArtwork)
        assertFalse(MusicWidgetLayout.COMPACT.hasExtraActions)
    }

    @Test fun wideAndTallBoundsExposeTheLargerLayoutSlots() {
        val wide = MusicWidgetLayout.forSize(264, 110)
        val tall = MusicWidgetLayout.forSize(168, 170)
        assertEquals(MusicWidgetLayout.WIDE, wide)
        assertEquals(MusicWidgetLayout.TALL, tall)
        for (layout in listOf(wide, tall)) {
            assertTrue(layout.hasArtwork)
            assertTrue(layout.hasExtraActions)
        }
    }

    @Test fun whenBothLayoutsFitTheClosestBoundsWin() {
        assertEquals(MusicWidgetLayout.WIDE, MusicWidgetLayout.forSize(400, 180))
        assertEquals(MusicWidgetLayout.TALL, MusicWidgetLayout.forSize(270, 270))
        assertEquals(MusicWidgetLayout.COMPACT, MusicWidgetLayout.forSize(400, 109))
        assertEquals(MusicWidgetLayout.COMPACT, MusicWidgetLayout.forSize(167, 270))
    }
}
