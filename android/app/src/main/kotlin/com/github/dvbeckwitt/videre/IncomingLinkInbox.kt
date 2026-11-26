package com.github.dvbeckwitt.videre

import java.net.URI
import java.util.UUID

internal sealed interface IncomingPayload
internal data class IncomingLinkPayload(val text: String, val share: Boolean) : IncomingPayload
internal data class IncomingAudioPayload(val uri: String) : IncomingPayload
internal data class IncomingLinkDelivery(val payload: IncomingPayload, val initial: Boolean)

internal fun musicShortcutAction(action: String?): String? = when (action) {
    "com.github.dvbeckwitt.videre.action.MUSIC_HOME",
    "com.github.dvbeckwitt.videre.action.MUSIC_SEARCH",
    "com.github.dvbeckwitt.videre.action.MUSIC_LIBRARY" -> action
    MUSIC_SHUFFLE_LOCAL -> action
    else -> null
}

internal const val MUSIC_SHUFFLE_LOCAL = "com.github.dvbeckwitt.videre.action.MUSIC_SHUFFLE_LOCAL"
internal const val SHUFFLE_SHORTCUT_TOKEN = "com.github.dvbeckwitt.videre.SHUFFLE_SHORTCUT_TOKEN"

// The exported MainActivity can receive explicit intents from any app. Only
// the private launcher activity can authorize an autoplay request.
internal object ShuffleShortcutAdmission {
    private var pending: String? = null

    fun issue(): String = UUID.randomUUID().toString().also { pending = it }

    fun consume(token: String?): Boolean {
        if (token == null || token != pending) return false
        pending = null
        return true
    }
}

/** Extract content identifiers and allowlisted launcher actions without opening them. */
internal fun incomingLinkPayload(action: String?, data: String?, mimeType: String?,
    text: CharSequence?, shuffleToken: String? = null): IncomingLinkPayload? = when (action) {
    "android.intent.action.VIEW" -> data?.takeIf { value ->
        runCatching { URI(value).scheme?.lowercase() in setOf("http", "https") }.getOrDefault(false)
    }?.let { IncomingLinkPayload(it, false) }
    "android.intent.action.SEND" -> text?.toString()?.takeIf {
        mimeType?.startsWith("text/", ignoreCase = true) == true && it.isNotBlank()
    }?.let { IncomingLinkPayload(it, true) }
    MUSIC_SHUFFLE_LOCAL -> if (ShuffleShortcutAdmission.consume(shuffleToken))
        IncomingLinkPayload(action, false) else null
    else -> musicShortcutAction(action)?.let { IncomingLinkPayload(it, false) }
}

/** Engine-owned bounded intake; Dart chooses the newest recognized open. */
internal class IncomingLinkInbox(val attachmentMarker: String = UUID.randomUUID().toString()) {
    private val pending = ArrayDeque<IncomingLinkDelivery>()

    fun offer(payload: IncomingPayload, initial: Boolean, previousMarker: String?): Boolean {
        // Activity reattachment is not a fresh user open. A new intent is always
        // admitted, including a legitimate repeat of the same address.
        if (initial && previousMarker == attachmentMarker) return false
        if (pending.size == MAX_PENDING_DELIVERIES) pending.removeFirst()
        pending.addLast(IncomingLinkDelivery(payload, initial))
        return true
    }

    // Snapshot and consume together: a batch produces at most one navigation,
    // and an unrelated newer share cannot erase an earlier valid candidate.
    fun takePending(): List<IncomingLinkDelivery> = pending.reversed().also { pending.clear() }
    fun clear() { pending.clear() }

    companion object {
        const val MAX_PENDING_DELIVERIES = 16
    }
}
