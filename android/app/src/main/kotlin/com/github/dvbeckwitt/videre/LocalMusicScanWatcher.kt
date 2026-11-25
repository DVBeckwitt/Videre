package com.github.dvbeckwitt.videre

import android.content.ContentResolver
import android.database.ContentObserver
import android.net.Uri
import android.os.Handler
import android.provider.DocumentsContract

/** Best-effort notifications for selected sources. Use from the handler's thread. */
internal class LocalMusicScanWatcher(
    private val resolver: ContentResolver,
    private val handler: Handler,
    private val changed: (Uri) -> Unit,
) {
    private data class Registration(val targets: Set<Uri>, val observer: ContentObserver)

    private val registrations = mutableMapOf<Uri, Registration>()

    fun watch(sources: Map<Uri, Set<Uri>>) {
        for (source in registrations.keys.toList()) {
            if (source !in sources) stopWatching(source)
        }
        for ((source, notifications) in sources) {
            val targets = targets(source, notifications)
            if (registrations[source]?.targets == targets) continue
            stopWatching(source)
            val observer = object : ContentObserver(handler) {
                override fun onChange(selfChange: Boolean) {
                    if (registrations[source]?.observer === this) changed(source)
                }
            }
            var registered = false
            for (target in targets) {
                try {
                    resolver.registerContentObserver(target, true, observer)
                    registered = true
                } catch (_: RuntimeException) {
                    // Providers can reject individual notification URIs or lose access.
                }
            }
            if (registered) registrations[source] = Registration(targets, observer)
        }
    }

    fun close() {
        for (source in registrations.keys.toList()) stopWatching(source)
    }

    private fun stopWatching(source: Uri) {
        val registration = registrations.remove(source) ?: return
        try {
            resolver.unregisterContentObserver(registration.observer)
        } catch (_: RuntimeException) {
            // Queued callbacks also check that this registration is current.
        }
    }

    private fun targets(source: Uri, notifications: Set<Uri>): Set<Uri> = buildSet {
        add(source)
        if (!DocumentsContract.isTreeUri(source)) return@buildSet
        val authority = source.authority ?: return@buildSet
        val root = DocumentsContract.getTreeDocumentId(source)
        add(DocumentsContract.buildChildDocumentsUriUsingTree(source, root))
        add(DocumentsContract.buildChildDocumentsUri(authority, root))
        // Providers may omit notifications or use unrelated paths for nested folders.
        // Retain a bounded set of the same provider's scoped notification URIs.
        notifications.asSequence().filter {
            it.scheme == ContentResolver.SCHEME_CONTENT && it.authority == authority &&
                it.pathSegments.isNotEmpty() && it.pathSegments.first() != "root" &&
                (it.pathSegments.first() != "tree" || it.pathSegments.getOrNull(1) == root)
        }.take(MAX_NOTIFICATION_URIS).forEach { add(it) }
    }

    companion object {
        const val MAX_NOTIFICATION_URIS = 256
    }
}
