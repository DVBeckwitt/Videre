package com.github.dvbeckwitt.videre.proxy

import java.io.IOException
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNotEquals
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertNull
import org.junit.Assert.assertThrows
import org.junit.Test

class PlaybackCacheIdentityTest {
    private val origin = "https://instance.example"
    private val media = "$origin/videoplayback?itag=140&sig=old-secret"

    private fun resource(url: String = media, key: String = "140:12345:1700000000:en",
                         persistent: Boolean = true, manifest: Boolean = false) =
        mapOf("url" to url, "key" to key, "persistent" to persistent, "manifest" to manifest)

    private fun values(profile: String = "profile-a", account: String = "account-a",
                       instance: String = origin, content: String = "song", session: String = "session-a",
                       resources: List<Map<String, Any>> = listOf(resource())): Map<String, Any> =
        mapOf("version" to 1, "profileId" to profile, "accountId" to account,
            "origin" to instance, "contentId" to content, "sessionId" to session,
            "resources" to resources)

    private fun identity(values: Map<String, Any> = values(), source: String = media) =
        PlaybackCacheIdentity.parse(values, source)

    @Test
    fun `signed URL refresh keeps persistent bytes while changing transient routes`() {
        val fresh = "$origin/videoplayback?itag=140&sig=new-secret"
        val first = identity()
        val next = identity(values(session = "session-b", resources = listOf(resource(fresh))), fresh)
        assertEquals(first.key(media), next.key(fresh))
        assertNotEquals(next.key(fresh), next.key(media))
        for (key in listOf(first.key(media), next.key(fresh))) {
            assertNotNull(key)
            assertFalse(key!!.contains("secret"))
            assertFalse(key.contains("instance.example"))
            assertFalse(key.contains("profile-a"))
        }
    }

    @Test
    fun `profile account content and instance scopes cannot share entries`() {
        val original = identity().key(media)
        for (different in listOf(
            values(profile = "profile-b"), values(account = "account-b"), values(content = "other-song")
        )) assertNotEquals(original, identity(different).key(media))

        val other = "https://other.example"
        val otherMedia = "$other/videoplayback?itag=140"
        val differentInstance = identity(values(instance = other,
            resources = listOf(resource(otherMedia))), otherMedia)
        assertNotEquals(original, differentInstance.key(otherMedia))
    }

    @Test
    fun `length-prefixed scope prevents identifier delimiter collisions`() {
        val first = identity(values(profile = "a:b", account = "c"))
        val second = identity(values(profile = "a", account = "b:c"))
        assertNotEquals(first.key(media), second.key(media))
    }

    @Test
    fun `representation audio track and byte revision keys stay distinct`() {
        val original = identity().key(media)
        for (key in listOf("141:12345:1700000000:en", "140:12346:1700000000:en",
            "140:12345:1700000001:en", "140:12345:1700000000:es")) {
            assertNotEquals(original, identity(values(resources = listOf(resource(key = key)))).key(media))
        }
    }

    @Test
    fun `incomplete representations and unknown adaptive children stay session scoped`() {
        val first = identity(values(resources = listOf(resource(persistent = false))))
        val next = identity(values(session = "session-b", resources = listOf(resource(persistent = false))))
        assertNotEquals(first.key(media), next.key(media))
        val children = listOf("$origin/segments/audio/0", "$origin/segments/audio/1",
            "$origin/segments/video/0", "$origin/segments/audio/0?range=100-199")
        assertEquals(children.size, children.map { first.key(it) }.toSet().size)
        assertNotEquals(first.key(children.first()), next.key(children.first()))
        assertEquals(first.key(children.first()), first.key(children.first()))
    }

    @Test
    fun `manifest resources bypass cache even with a persistent key`() {
        val custom = "$origin/signed-document?sig=temporary"
        val marked = identity(values(resources = listOf(resource(custom, manifest = true))), custom)
        assertNull(marked.key(custom))
        val ordinary = identity()
        for (url in listOf("$origin/manifest.mpd", "$origin/playlist.m3u8?sig=x",
            "$origin/api/manifest/dash/id/song", "$origin/manifest/child")) {
            assertNull(ordinary.key(url))
        }
        assertNotNull(ordinary.key("$origin/segment.webm"))
    }

    @Test
    fun `cache hits still require exact selected origin and no credentials`() {
        val cache = identity()
        for (url in listOf("https://elsewhere.example/video", "http://instance.example/video",
            "https://instance.example:8443/video", "https://user:secret@instance.example/video",
            "https://rr1.googlevideo.com/videoplayback", "https://i.ytimg.com/cover.jpg",
            "https://www.youtube.com/watch?v=song", "file:///tmp/song", "not a URI")) {
            val error = assertThrows(IOException::class.java) { cache.key(url) }
            val expectedMediaMismatch = url in setOf("https://elsewhere.example/video",
                "http://instance.example/video", "https://instance.example:8443/video")
            assertEquals(expectedMediaMismatch, MediaOriginFailure.isBlocked(error))
        }
    }

    @Test
    fun `invalid source or any foreign resource rejects the whole descriptor`() {
        val sourceError = assertThrows(SelectedOriginBlocked::class.java) {
            identity(source = "https://elsewhere.example/video")
        }
        val resourceError = assertThrows(SelectedOriginBlocked::class.java) {
            identity(values(resources = listOf(resource(), resource("https://elsewhere.example/video"))))
        }
        assertEquals(false, MediaOriginFailure.isBlocked(sourceError))
        assertEquals(false, MediaOriginFailure.isBlocked(resourceError))
        assertThrows(IllegalArgumentException::class.java) {
            identity(values(instance = "https://www.youtube.com", resources = emptyList()),
                "https://www.youtube.com/watch?v=song")
        }
    }

    @Test
    fun `schema required fields and bounded resource table are enforced`() {
        for (changed in listOf(values() + ("version" to 2), values(profile = ""),
            values(account = ""), values(content = ""), values(session = ""),
            values(instance = "$origin/path"), values(instance = "$origin?query=x"),
            values(instance = "https://user:secret@instance.example"),
            values(resources = List(513) { resource() }))) {
            assertThrows(IllegalArgumentException::class.java) { identity(changed) }
        }
    }
}
