package com.github.dvbeckwitt.videre

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

class LocalMusicRootsTest {
    @Test
    fun `legacy grant retains approval ownership and reapproval state`() {
        val configuration = LocalMusicRoots.read(mapOf(
            "uri" to "content://provider/tree/old",
            "name" to "Original music",
            "ownsRead" to true,
            "needsReapproval" to true,
        ))

        val root = configuration.entries.single()
        assertEquals("Original music", root.name)
        assertNull(root.selectionId)
        assertNull(configuration.selectionId)
        assertTrue(root.ownsRead)
        assertTrue(root.needsReapproval)
        assertFalse(root.isDocumentProvider)
        assertFalse(root.channelValue().containsKey("ownsRead"))
    }

    @Test
    fun `reselecting a provider URI keeps its picker kind`() {
        val local = LocalMusicRoot("content://provider/tree/music", "Music", "initial")
        val provider = local.copy(isDocumentProvider = true)
        val reconnected = local.copy(selectionId = "reconnected")
        val configuration = LocalMusicRoots.read(emptyMap<String, Any>())
            .withRoot(local)
            .withRoot(provider)
            .withRoot(reconnected)

        val root = configuration.entries.single()
        assertEquals("reconnected", root.selectionId)
        assertTrue(root.isDocumentProvider)
        assertEquals(true, root.channelValue()["isDocumentProvider"])
    }

    @Test
    fun `changing configured roots retains original approval until fully cleared`() {
        val older = LocalMusicRoot("content://provider/tree/old", "Original music", "legacy")
        val other = LocalMusicRoot("content://provider/tree/new", "More music", "second")
        val reconnected = older.copy(selectionId = "reconnected")
        val empty = LocalMusicRoots.read(emptyMap<String, Any>())
        val both = empty.withRoot(older).withRoot(other).withRoot(reconnected)
        assertEquals(listOf(reconnected, other), both.entries)
        assertEquals("legacy", both.selectionId)

        val remaining = both.without(listOf(reconnected))
        assertEquals(listOf(other), remaining.entries)
        assertEquals("legacy", remaining.selectionId)

        val cleared = remaining.without(remaining.entries)
        assertEquals(empty, cleared)
        assertEquals("second", cleared.withRoot(other).selectionId)
    }
}
