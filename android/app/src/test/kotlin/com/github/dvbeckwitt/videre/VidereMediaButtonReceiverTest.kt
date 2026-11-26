package com.github.dvbeckwitt.videre

import android.view.KeyEvent
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test
import org.w3c.dom.Element
import java.io.File
import javax.xml.parsers.DocumentBuilderFactory

class VidereMediaButtonReceiverTest {
    private val android = "http://schemas.android.com/apk/res/android"

    @Test fun onlyInitialPlayAndHeadsetDownEventsCanResumePlayback() {
        for (code in listOf(
            KeyEvent.KEYCODE_MEDIA_PLAY,
            KeyEvent.KEYCODE_MEDIA_PLAY_PAUSE,
            KeyEvent.KEYCODE_HEADSETHOOK,
        )) {
            assertTrue(isColdPlayPress(code, KeyEvent.ACTION_DOWN, 0))
            assertFalse(isColdPlayPress(code, KeyEvent.ACTION_UP, 0))
            assertFalse(isColdPlayPress(code, KeyEvent.ACTION_DOWN, 1))
        }
        for (code in listOf(
            KeyEvent.KEYCODE_MEDIA_PAUSE,
            KeyEvent.KEYCODE_MEDIA_STOP,
            KeyEvent.KEYCODE_MEDIA_NEXT,
            KeyEvent.KEYCODE_MEDIA_PREVIOUS,
        )) {
            assertFalse(isColdPlayPress(code, KeyEvent.ACTION_DOWN, 0))
        }
    }

    @Test fun onePrivateReceiverAcceptsSystemMediaKeys() {
        val manifest = DocumentBuilderFactory.newInstance()
            .apply { isNamespaceAware = true }
            .newDocumentBuilder()
            .parse(File("src/main/AndroidManifest.xml"))
        val nodes = manifest.getElementsByTagName("receiver")
        val receivers = (0 until nodes.length).map { nodes.item(it) as Element }
        val mediaButton = receivers.single { receiver ->
            val actions = receiver.getElementsByTagName("action")
            (0 until actions.length).any {
                (actions.item(it) as Element).getAttributeNS(android, "name") ==
                    "android.intent.action.MEDIA_BUTTON"
            }
        }
        assertEquals(".VidereMediaButtonReceiver", mediaButton.getAttributeNS(android, "name"))
        assertEquals("false", mediaButton.getAttributeNS(android, "exported"))

        val notification = receivers.single {
            it.getAttributeNS(android, "name") == "com.ryanheise.audioservice.MediaButtonReceiver"
        }
        assertEquals("false", notification.getAttributeNS(android, "exported"))
    }
}
