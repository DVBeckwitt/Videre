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
            filter.elements("action").any { it.android("name") == "android.intent.action.VIEW" }
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
}
