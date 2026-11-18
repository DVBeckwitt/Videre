package com.github.dvbeckwitt.videre

import java.net.URI
import java.util.UUID

internal data class IncomingLinkPayload(val text: String, val share: Boolean)
internal data class IncomingLinkDelivery(val payload: IncomingLinkPayload, val initial: Boolean)

/** Extract identifiers as text only; Dart performs the supported-host/content validation. */
internal fun incomingLinkPayload(action: String?, data: String?, mimeType: String?,
    text: CharSequence?): IncomingLinkPayload? = when (action) {
    "android.intent.action.VIEW" -> data?.takeIf { value ->
        runCatching { URI(value).scheme?.lowercase() in setOf("http", "https") }.getOrDefault(false)
    }?.let { IncomingLinkPayload(it, false) }
    "android.intent.action.SEND" -> text?.toString()?.takeIf {
        mimeType?.startsWith("text/", ignoreCase = true) == true && it.isNotBlank()
    }?.let { IncomingLinkPayload(it, true) }
    else -> null
}

/** Engine-owned bounded intake; Dart chooses the newest recognized content link. */
internal class IncomingLinkInbox(val attachmentMarker: String = UUID.randomUUID().toString()) {
    private val pending = ArrayDeque<IncomingLinkDelivery>()

    fun offer(payload: IncomingLinkPayload, initial: Boolean, previousMarker: String?): Boolean {
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
