package com.github.dvbeckwitt.videre

import org.junit.Assert.*
import org.junit.Test

class IncomingLinkInboxTest {
    private val short = IncomingLinkPayload("https://youtu.be/TW2IkSjGgjY", false)
    private val shorts = IncomingLinkPayload("https://www.youtube.com/shorts/TW2IkSjGgjY", false)

    @Test fun coldLinkWaitsForDartAndIsTakenOnlyOnce() {
        val inbox = IncomingLinkInbox("engine-one")
        assertTrue(inbox.offer(short, initial = true, previousMarker = null))
        assertEquals(listOf(IncomingLinkDelivery(short, true)), inbox.takePending())
        assertTrue(inbox.takePending().isEmpty())
    }

    @Test fun localShuffleRequiresAFreshPrivateLauncherToken() {
        assertNull(incomingLinkPayload(MUSIC_SHUFFLE_LOCAL, null, null, null))
        val token = ShuffleShortcutAdmission.issue()
        assertNull(incomingLinkPayload(MUSIC_SHUFFLE_LOCAL, null, null, null, "invalid"))
        assertEquals(IncomingLinkPayload(MUSIC_SHUFFLE_LOCAL, false),
            incomingLinkPayload(MUSIC_SHUFFLE_LOCAL, null, null, null, token))
        assertNull(incomingLinkPayload(MUSIC_SHUFFLE_LOCAL, null, null, null, token))
    }

    @Test fun warmLinkBeforeListenerRegistrationIsRetained() {
        val inbox = IncomingLinkInbox("engine-one")
        assertTrue(inbox.offer(short, initial = false, previousMarker = null))
        assertEquals(listOf(IncomingLinkDelivery(short, false)), inbox.takePending())
        assertTrue(inbox.takePending().isEmpty())
    }

    @Test fun latestOpenComesFirstWhileDartIsUnavailable() {
        val inbox = IncomingLinkInbox("engine-one")
        inbox.offer(short, initial = true, previousMarker = null)
        inbox.offer(shorts, initial = false, previousMarker = null)
        assertEquals(listOf(IncomingLinkDelivery(shorts, false),
            IncomingLinkDelivery(short, true)), inbox.takePending())
    }

    @Test fun unrelatedTextBeforeDartHandshakeCannotEraseAnEarlierCandidate() {
        val inbox = IncomingLinkInbox("engine-one")
        val unrelated = IncomingLinkPayload("Unrelated shared text", true)
        inbox.offer(short, initial = true, previousMarker = null)
        inbox.offer(unrelated, initial = false, previousMarker = null)

        // Only Dart knows which configured instance/content paths are valid.
        // It must receive both candidates, newest first, in one atomic batch.
        assertEquals(listOf(IncomingLinkDelivery(unrelated, false),
            IncomingLinkDelivery(short, true)), inbox.takePending())
    }

    @Test fun repeatedNewIntentsWithSameUrlAreSeparateDeliveries() {
        val inbox = IncomingLinkInbox("engine-one")
        repeat(2) {
            assertTrue(inbox.offer(short, initial = false, previousMarker = inbox.attachmentMarker))
            assertEquals(short, inbox.takePending().single().payload)
            assertTrue(inbox.takePending().isEmpty())
        }
    }

    @Test fun activityReattachmentCannotReplayConsumedLink() {
        val inbox = IncomingLinkInbox("engine-one")
        inbox.offer(short, initial = true, previousMarker = null)
        inbox.takePending()
        assertFalse(inbox.offer(short, initial = true, previousMarker = inbox.attachmentMarker))
        assertTrue(inbox.takePending().isEmpty())
    }

    @Test fun activityReattachmentPreservesAnUnconsumedLink() {
        val inbox = IncomingLinkInbox("engine-one")
        inbox.offer(short, initial = true, previousMarker = null)
        assertFalse(inbox.offer(short, initial = true, previousMarker = inbox.attachmentMarker))
        assertEquals(short, inbox.takePending().single().payload)
    }

    @Test fun engineShutdownDiscardsPendingDelivery() {
        val inbox = IncomingLinkInbox("engine-one")
        inbox.offer(short, initial = false, previousMarker = null)
        inbox.clear()
        assertTrue(inbox.takePending().isEmpty())
    }

    @Test fun startupBurstIsBoundedAndConsumedAsOneNewestFirstSnapshot() {
        val inbox = IncomingLinkInbox("engine-one")
        repeat(IncomingLinkInbox.MAX_PENDING_DELIVERIES + 5) { index ->
            inbox.offer(IncomingLinkPayload("Shared text $index", true),
                initial = false, previousMarker = null)
        }
        val batch = inbox.takePending()
        assertEquals(IncomingLinkInbox.MAX_PENDING_DELIVERIES, batch.size)
        assertEquals(IncomingLinkPayload("Shared text 20", true), batch.first().payload)
        assertEquals(IncomingLinkPayload("Shared text 5", true), batch.last().payload)
        assertTrue(inbox.takePending().isEmpty())
        inbox.offer(short, initial = false, previousMarker = null)
        assertEquals(listOf(IncomingLinkDelivery(short, false)), inbox.takePending())
        // A previous result is immutable with respect to later inbox intake.
        assertEquals(IncomingLinkInbox.MAX_PENDING_DELIVERIES, batch.size)
    }

    @Test fun audioAndWebOpensShareTheInboxWithoutReplayingAfterReattachment() {
        val inbox = IncomingLinkInbox("engine-one")
        val audio = IncomingAudioPayload("content://documents/document/primary%3AMusic%2FSong.flac")
        assertTrue(inbox.offer(audio, initial = true, previousMarker = null))
        assertTrue(inbox.offer(short, initial = false, previousMarker = null))
        assertFalse(inbox.offer(audio, initial = true, previousMarker = inbox.attachmentMarker))
        assertEquals(listOf(IncomingLinkDelivery(short, false), IncomingLinkDelivery(audio, true)), inbox.takePending())
        assertTrue(inbox.offer(audio, initial = false, previousMarker = inbox.attachmentMarker))
        assertEquals(listOf(IncomingLinkDelivery(audio, false)), inbox.takePending())
    }

    @Test fun audioOpenRequiresASingleTypedContentUriAndAnActualGrant() {
        val view = "android.intent.action.VIEW"
        val data = "content://documents/document/primary%3AMusic%2FSong.flac"
        assertEquals(IncomingAudioPayload(data), incomingAudioPayload(view, data, "audio/flac") { true })
        assertNull(incomingAudioPayload(view, data, "audio/flac") { false })
        for ((action, uri, type) in listOf(
            Triple("android.intent.action.SEND", data, "audio/flac"),
            Triple(view, "file:///sdcard/Music/Song.flac", "audio/flac"),
            Triple(view, "https://example.test/music.flac", "audio/flac"),
            Triple(view, "content:///audio.flac", "audio/flac"),
            Triple(view, "$data?item=other", "audio/flac"),
            Triple(view, data, "application/octet-stream"),
            Triple(view, data, "audio/x-mpegurl"),
            Triple(view, "content://documents/document/primary%3AMusic%2Fplaylist%2Em3u8", "audio/mpeg"),
        )) {
            assertNull(incomingAudioPayload(action, uri, type) { error("Unexpected grant check") })
        }
    }

    @Test fun webViewKeepsFullAddressEvenWithMimeType() {
        for (type in listOf(null, "text/plain", "text/html", "video/mp4")) {
            assertEquals(short, incomingLinkPayload("android.intent.action.VIEW", short.text, type, null))
        }
    }

    @Test fun bothHttpSchemesAreIdentifiersWithoutNetworkResolution() {
        assertEquals(IncomingLinkPayload("http://youtu.be/TW2IkSjGgjY", false),
            incomingLinkPayload("android.intent.action.VIEW", "http://youtu.be/TW2IkSjGgjY", null, null))
    }

    @Test fun styledCharSequenceShareBecomesPlainText() {
        val text: CharSequence = StringBuilder("Watch this: ${short.text}")
        assertEquals(IncomingLinkPayload(text.toString(), true),
            incomingLinkPayload("android.intent.action.SEND", null, "text/plain", text))
    }

    @Test fun authCallbacksAndNonWebViewsNeverEnterInbox() {
        for (data in listOf(null, "", "com.github.dvbeckwitt.videre.auth://callback/token",
            "content://documents/1", "file:///sdcard/movie.mp4", "javascript:alert(1)")) {
            assertNull(incomingLinkPayload("android.intent.action.VIEW", data, null, null))
        }
    }

    @Test fun unrelatedOrMissingSharesNeverEnterInbox() {
        for (type in listOf(null, "image/jpeg", "application/octet-stream")) {
            assertNull(incomingLinkPayload("android.intent.action.SEND", null, type, short.text))
        }
        assertNull(incomingLinkPayload("android.intent.action.SEND", null, "text/plain", null))
        assertNull(incomingLinkPayload("android.intent.action.SEND", null, "text/plain", " "))
        assertNull(incomingLinkPayload("android.intent.action.MAIN", short.text, "text/plain", short.text))
    }
}
