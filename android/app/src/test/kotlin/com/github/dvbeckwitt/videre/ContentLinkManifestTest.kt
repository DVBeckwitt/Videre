package com.github.dvbeckwitt.videre

import org.junit.Assert.*
import org.junit.Test
import org.w3c.dom.Element
import java.io.File
import javax.xml.parsers.DocumentBuilderFactory

class ContentLinkManifestTest {
    private val android = "http://schemas.android.com/apk/res/android"
    private fun Element.android(name: String) = getAttributeNS(android, name)
    private fun Element.elements(tag: String): List<Element> =
        getElementsByTagName(tag).let { nodes ->
            (0 until nodes.length).map { nodes.item(it) as Element }
        }

    private fun mainActivity(): Element {
        val factory = DocumentBuilderFactory.newInstance().apply { isNamespaceAware = true }
        val document = factory.newDocumentBuilder().parse(File("src/main/AndroidManifest.xml"))
        return document.documentElement.elements("activity")
            .single { it.android("name") == ".MainActivity" }
    }

    @Test fun androidDefaultsCoverEveryPathOnExactYouTubeDomains() {
        val filters = mainActivity().elements("intent-filter").filter { filter ->
            filter.elements("action").any { it.android("name") == "android.intent.action.VIEW" } &&
                filter.elements("category").any { it.android("name") == "android.intent.category.BROWSABLE" }
        }
        assertEquals(1, filters.size)
        val hosts = filters.flatMap { filter ->
            assertEquals("", filter.android("autoVerify"))
            assertEquals(setOf("android.intent.category.DEFAULT", "android.intent.category.BROWSABLE"),
                filter.elements("category").map { it.android("name") }.toSet())
            val data = filter.elements("data")
            assertEquals(setOf("http", "https"),
                data.map { it.android("scheme") }.filter { it.isNotEmpty() }.toSet())
            // Host ownership in Android settings must apply to new/less common
            // paths too (live, embed, handles, searches and Music landing pages).
            // MIME/path/query restrictions would silently send those to a browser.
            for (attribute in listOf("path", "pathPrefix", "pathPattern",
                "pathAdvancedPattern", "pathSuffix", "mimeType", "port")) {
                assertTrue("Unexpected $attribute restriction", data.all {
                    it.android(attribute).isEmpty()
                })
            }
            data.map { it.android("host") }.filter { it.isNotEmpty() }
        }
        assertEquals(setOf("youtube.com", "www.youtube.com", "m.youtube.com",
            "music.youtube.com", "youtu.be"), hosts.toSet())
        assertEquals(hosts.size, hosts.toSet().size)
    }

    @Test fun openWithVidereAcceptsOnlyContentAudio() {
        val audio = mainActivity().elements("intent-filter").single { filter ->
            filter.elements("action").any { it.android("name") == "android.intent.action.VIEW" } &&
                filter.elements("category").none { it.android("name") == "android.intent.category.BROWSABLE" }
        }
        assertEquals(listOf("android.intent.action.VIEW"), audio.elements("action").map { it.android("name") })
        assertEquals(listOf("android.intent.category.DEFAULT"), audio.elements("category").map { it.android("name") })
        val data = audio.elements("data").single()
        assertEquals("content", data.android("scheme"))
        assertEquals("audio/*", data.android("mimeType"))
    }

    @Test fun coldAndWarmLinksUseExportedMainActivityWithoutFlutterAutoRouting() {
        val activity = mainActivity()
        assertEquals("true", activity.android("exported"))
        assertEquals("singleTop", activity.android("launchMode"))
        assertEquals("false", activity.elements("meta-data").single {
            it.android("name") == "flutter_deeplinking_enabled"
        }.android("value"))
    }

    @Test fun sharedTextIsAcceptedWithoutOpeningOtherMediaTypes() {
        val share = mainActivity().elements("intent-filter").single { filter ->
            filter.elements("action").any { it.android("name") == "android.intent.action.SEND" }
        }
        assertEquals(listOf("text/*"), share.elements("data").map { it.android("mimeType") })
        assertEquals(listOf("android.intent.category.DEFAULT"),
            share.elements("category").map { it.android("name") })
    }

    @Test fun musicShortcutsUseAPrivateTaskAndOnlyAllowlistedActions() {
        val factory = DocumentBuilderFactory.newInstance().apply { isNamespaceAware = true }
        val builder = factory.newDocumentBuilder()
        val manifest = builder.parse(File("src/main/AndroidManifest.xml")).documentElement
        val trampoline = manifest.elements("activity").single {
            it.android("name") == ".MusicShortcutActivity"
        }
        assertEquals("false", trampoline.android("exported"))
        assertTrue(trampoline.hasAttributeNS(android, "taskAffinity"))
        assertEquals("", trampoline.android("taskAffinity"))
        assertEquals("@xml/music_shortcuts", mainActivity().elements("meta-data").single {
            it.android("name") == "android.app.shortcuts"
        }.android("resource"))

        val shortcuts = builder.parse(File("src/main/res/xml/music_shortcuts.xml"))
            .documentElement.elements("shortcut")
        assertEquals(listOf("music_home", "music_search", "music_library", "music_shuffle_local"),
            shortcuts.map { it.android("shortcutId") })
        for (shortcut in shortcuts) {
            val intent = shortcut.elements("intent").single()
            val action = "com.github.dvbeckwitt.videre.action.${shortcut.android("shortcutId").uppercase()}"
            assertEquals(action, intent.android("action"))
            assertEquals("com.github.dvbeckwitt.videre", intent.android("targetPackage"))
            assertEquals("com.github.dvbeckwitt.videre.MusicShortcutActivity", intent.android("targetClass"))
            assertEquals(action, musicShortcutAction(action))
            if (action != MUSIC_SHUFFLE_LOCAL) {
                assertEquals(IncomingLinkPayload(action, false),
                    incomingLinkPayload(action, null, null, null))
            }
        }
        assertTrue(builder.parse(File("src/main/res/xml-television/music_shortcuts.xml"))
            .documentElement.elements("shortcut").isEmpty())
        assertNull(incomingLinkPayload(
            "com.github.dvbeckwitt.videre.action.MUSIC_UNKNOWN", null, null, null))
    }
}
