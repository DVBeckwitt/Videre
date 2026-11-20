package com.github.dvbeckwitt.videre

import android.content.ContentUris
import android.content.Context
import android.database.Cursor
import android.graphics.Bitmap
import android.graphics.BitmapFactory
import android.media.MediaMetadataRetriever
import android.net.Uri
import android.os.Build
import android.os.CancellationSignal
import android.os.Environment
import android.os.SystemClock
import android.provider.DocumentsContract
import android.provider.DocumentsContract.Document
import android.provider.MediaStore
import android.provider.MediaStore.Audio.Media as Audio
import android.system.Os
import android.util.Base64
import android.util.Log
import java.io.ByteArrayOutputStream
import java.io.File
import java.io.FileNotFoundException
import java.io.IOException
import java.security.MessageDigest
import java.util.ArrayDeque
import java.util.Locale
import java.util.UUID

internal class LocalMusicCatalog(private val context: Context, cache: File, indexFile: File) {
    private val artwork = LocalMusicCovers(cache)
    private val index = LocalMusicIndex(indexFile)

    fun tracks(
        source: Uri,
        signal: CancellationSignal,
        publish: (List<Map<String, Any?>>) -> Unit = {},
    ): List<Map<String, Any?>> {
        val started = SystemClock.elapsedRealtime()
        val sourceKey = source.toString()
        val snapshot = index.read(sourceKey)
        val scanned = linkedMapOf<String, LocalMusicRow>()
        // A path-based provider can reuse the old URI after a rename. Reserve
        // the ID for the renamed song until it actually leaves this library.
        val reserved = buildMap {
            (snapshot.tracks.values + snapshot.pending.map { it.previous }).forEach { row ->
                if (row.identityKey == null) put(row.identityUri ?: row.uri, row.uri)
            }
        }
        val batch = TrackBatch(publish)
        val coverRepairs = LocalMusicCoverRepairs()
        val scanTime = System.currentTimeMillis()
        val pendingTargets = snapshot.pending.groupBy { it.name }
        val pendingSources = snapshot.pending.mapTo(mutableSetOf()) { it.previous.uri }
        val held = mutableSetOf<String>()

        fun publishDiscovered(row: LocalMusicRow) {
            val value = channelValue(row)
            coverRepairs.consider(row, value["artPath"] != null)
            batch.add(value)
        }

        fun collect(draft: LocalMusicRow) {
            val previous = snapshot.tracks[draft.uri]
            val row = draft.copy(
                addedMs = if (draft.firstSeen) previous?.addedMs ?: scanTime else draft.addedMs,
                firstSeen = draft.firstSeen && (previous?.firstSeen != false),
                metadata = if (previous != null && draft.matchesRevision(previous)) {
                    previous.metadata ?: draft.metadata
                } else {
                    draft.metadata
                },
            )
            val identified = when {
                previous != null -> row.inheritsIdentity(previous)
                draft.uri in reserved && reserved[draft.uri] != draft.uri ->
                    row.copy(identityKey = newIdentityKey())
                else -> row
            }
            scanned[identified.uri] = identified
            // Wait for the complete listing before choosing a recovery match.
            // A provisional identity would briefly describe the wrong file.
            if (pendingTargets[identified.fileName]?.any { it.targets(identified) } == true ||
                identified.uri in pendingSources) {
                held.add(identified.uri)
            } else {
                publishDiscovered(identified)
            }
        }

        val system = source.toString() == SYSTEM_URI
        if (system) scanMediaStore(source, signal, ::collect)
        else scanFolder(source, signal, ::collect)
        signal.throwIfCanceled()
        val pending = mutableListOf<PendingLocalMusicRename>()
        val changes = snapshot.unacknowledged.toMutableList()
        val recovered = mutableSetOf<String>()
        for (rename in snapshot.pending) {
            val previous = rename.previous
            val old = scanned[previous.uri]
            val targets = held.asSequence()
                .filter { it !in recovered }
                .mapNotNull(scanned::get)
                .filter(rename::targets)
                .toList()
            val match = rename.recover(old, targets.asSequence())
            val originalStillPresent = rename.originalStillAtOldPath(old, targets.isNotEmpty())
            if (old != null && old.uri != match?.uri && !originalStillPresent &&
                (old.identityKey == null || old.identityKey == previous.identityKey)) {
                // The same path can now describe another file. Keep the original
                // session ID reserved until a unique recovery can be proven.
                scanned[old.uri] = old.copy(
                    addedMs = if (old.firstSeen) scanTime else old.addedMs,
                    identityUri = null,
                    identityKey = newIdentityKey(),
                    metadata = null,
                )
            }
            if (match != null) {
                recovered.add(match.uri)
                scanned[match.uri] = match.inheritsIdentity(previous).copy(
                    addedMs = previous.addedMs,
                    firstSeen = previous.firstSeen,
                )
                changes.addAll(uriChanges(rename, match.uri))
            } else if (!originalStillPresent) {
                pending.add(rename)
            }
        }
        // Save only after successful discovery. First-seen dates and identity
        // transitions survive an interruption during the slower tag pass.
        index.write(sourceKey, LocalMusicSnapshot(
            scanned.mapValues { (uri, row) ->
                // For uncached rows, keep only file attributes until the tag
                // pass succeeds. MediaStore's summary is useful on screen but
                // doesn't count as retained embedded metadata.
                val previous = snapshot.tracks[uri]
                if (previous?.metadata != null && previous.matchesRevision(row) &&
                    row.identityKey == previous.identityKey) row else row.copy(metadata = null)
            },
            pending,
            changes,
        ))
        held.forEach { uri -> scanned[uri]?.let(::publishDiscovered) }
        batch.flush()

        var reads = 0
        scanned.entries.forEach { entry ->
            signal.throwIfCanceled()
            val row = entry.value
            val previous = snapshot.tracks[row.uri]
            if (previous?.metadata == null || !row.matchesRevision(previous) ||
                row.identityKey != previous.identityKey) {
                ++reads
                val metadata = readMetadata(Uri.parse(row.uri), row.metadata)
                entry.setValue(row.copy(metadata = metadata))
                batch.add(channelValue(entry.value))
            }
        }
        var coverReads = 0
        for ((cover, uri) in coverRepairs.candidates) {
            signal.throwIfCanceled()
            // A normal tag read may have already regenerated this shared cover.
            if (artwork.path(cover) != null) continue
            ++coverReads
            repairCover(Uri.parse(uri), cover)
        }
        signal.throwIfCanceled()
        index.write(sourceKey, LocalMusicSnapshot(scanned, pending, changes))
        batch.flush()
        artwork.removeUnused()
        Log.d("VidereLocalMusic",
            "tracks=${scanned.size} tagReads=$reads coverReads=$coverReads elapsedMs=${SystemClock.elapsedRealtime() - started}")
        return scanned.values.sortedWith(compareBy(String.CASE_INSENSITIVE_ORDER) {
            it.metadata?.title ?: fallbackTitle(it.fileName)
        }).map(::channelValue)
    }

    fun indexedTrack(source: Uri, uri: Uri): Map<String, Any?>? =
        index.read(source.toString()).tracks[uri.toString()]?.let(::channelValue)

    fun prepareRename(source: Uri, uri: Uri, name: String) {
        val key = source.toString()
        val snapshot = index.read(key)
        val row = snapshot.tracks[uri.toString()] ?: throw IOException()
        val pending = snapshot.pending.filterNot { it.previous.uri == row.uri }
        val equivalent = if (key == SYSTEM_URI) externalStorageDocument(uri)?.toString() else null
        val rename = PendingLocalMusicRename(UUID.randomUUID().toString(), row, name, equivalent)
        index.write(key, snapshot.copy(pending = pending + rename))
    }

    fun cancelRename(source: Uri, uri: Uri) {
        val key = source.toString()
        val snapshot = index.read(key)
        val pending = snapshot.pending.filterNot { it.previous.uri == uri.toString() }
        if (pending.size != snapshot.pending.size) index.write(key, snapshot.copy(pending = pending))
    }

    fun renamedTrack(source: Uri, oldUri: Uri, newUri: Uri, name: String): Map<String, Any?> {
        val key = source.toString()
        val snapshot = index.read(key)
        val previous = snapshot.tracks[oldUri.toString()] ?: throw IOException()
        val updated = previous.copy(uri = newUri.toString(), fileName = name)
            .inheritsIdentity(previous)
        val tracks = snapshot.tracks.toMutableMap().apply {
            remove(previous.uri)
            put(updated.uri, updated)
        }
        val pending = snapshot.pending.filterNot { it.previous.uri == previous.uri }
        val rename = snapshot.pending.firstOrNull { it.previous.uri == previous.uri }
            ?: PendingLocalMusicRename(UUID.randomUUID().toString(), previous, name)
        val changes = snapshot.unacknowledged + uriChanges(rename, updated.uri)
        index.write(key, LocalMusicSnapshot(tracks, pending, changes))
        return channelValue(updated)
    }

    private fun uriChanges(rename: PendingLocalMusicRename, newUri: String): List<LocalMusicUriChange> =
        buildList {
            if (rename.previous.uri != newUri) add(LocalMusicUriChange(rename.id, rename.previous.uri, newUri))
            val old = rename.equivalentDocument?.let(Uri::parse) ?: return@buildList
            val new = externalStorageDocument(Uri.parse(newUri)) ?: return@buildList
            if (old == new) return@buildList
            val oldId = DocumentsContract.getDocumentId(old)
            val newId = DocumentsContract.getDocumentId(new)
            for (grant in context.contentResolver.persistedUriPermissions) {
                val tree = grant.uri
                if (!grant.isReadPermission || tree.authority != EXTERNAL_STORAGE_PROVIDER ||
                    !DocumentsContract.isTreeUri(tree)) continue
                val treeId = DocumentsContract.getTreeDocumentId(tree)
                if (!containsDocument(treeId, oldId) || !containsDocument(treeId, newId)) continue
                val from = DocumentsContract.buildDocumentUriUsingTree(tree, oldId).toString()
                val to = DocumentsContract.buildDocumentUriUsingTree(tree, newId).toString()
                val id = UUID.nameUUIDFromBytes("${rename.id}:$from:$to".toByteArray()).toString()
                add(LocalMusicUriChange(id, from, to))
            }
        }

    private fun externalStorageDocument(mediaUri: Uri): Uri? {
        return try {
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
                MediaStore.getDocumentUri(context, mediaUri)?.takeIf {
                    it.authority == EXTERNAL_STORAGE_PROVIDER && DocumentsContract.isDocumentUri(context, it)
                }
            } else {
                legacyExternalStorageDocument(mediaUri)
            }
        } catch (_: Exception) {
            null
        }
    }

    @Suppress("DEPRECATION")
    private fun legacyExternalStorageDocument(mediaUri: Uri): Uri? {
        val resolver = context.contentResolver
        val trees = resolver.persistedUriPermissions.filter {
            it.isReadPermission && it.uri.authority == EXTERNAL_STORAGE_PROVIDER &&
                DocumentsContract.isTreeUri(it.uri)
        }
        if (trees.isEmpty()) return null
        val path = resolver.query(mediaUri, arrayOf(MediaStore.MediaColumns.DATA), null, null, null)?.use {
            if (it.moveToFirst()) it.getString(0) else null
        } ?: return null
        val primary = Environment.getExternalStorageDirectory().canonicalPath + File.separator
        val canonical = File(path).canonicalPath
        if (!canonical.startsWith(primary)) return null
        val documentId = "primary:${canonical.removePrefix(primary)}"
        val mediaStat = resolver.openFileDescriptor(mediaUri, "r")?.use { Os.fstat(it.fileDescriptor) }
            ?: return null
        for (grant in trees) {
            val tree = grant.uri
            if (!containsDocument(DocumentsContract.getTreeDocumentId(tree), documentId)) continue
            val candidate = DocumentsContract.buildDocumentUriUsingTree(tree, documentId)
            val documentStat = runCatching {
                resolver.openFileDescriptor(candidate, "r")?.use { Os.fstat(it.fileDescriptor) }
            }.getOrNull() ?: continue
            if (mediaStat.st_dev == documentStat.st_dev && mediaStat.st_ino == documentStat.st_ino) {
                return DocumentsContract.buildDocumentUri(EXTERNAL_STORAGE_PROVIDER, documentId)
            }
        }
        return null
    }

    fun pendingRenames(source: Uri): List<Map<String, String>> =
        index.read(source.toString()).unacknowledged.map {
            mapOf("id" to it.id, "oldUri" to it.oldUri, "newUri" to it.newUri)
        }

    fun acknowledgeRename(source: Uri, old: Uri, new: Uri, id: String? = null) {
        val key = source.toString()
        val snapshot = index.read(key)
        val remaining = snapshot.unacknowledged.toMutableList()
        val match = remaining.indexOfFirst {
            (id == null || it.id == id) && it.oldUri == old.toString() && it.newUri == new.toString()
        }
        if (match < 0) return
        remaining.removeAt(match)
        index.write(key, snapshot.copy(unacknowledged = remaining))
    }

    fun clearIndex() = index.clear()

    private fun scanFolder(tree: Uri, signal: CancellationSignal, collect: (LocalMusicRow) -> Unit) {
        val root = DocumentsContract.getTreeDocumentId(tree)
        val directories = ArrayDeque<String>()
        val seen = hashSetOf(root)
        directories.add(root)
        while (directories.isNotEmpty()) {
            signal.throwIfCanceled()
            val id = directories.removeFirst()
            val children = DocumentsContract.buildChildDocumentsUriUsingTree(tree, id)
            val cursor = try {
                context.contentResolver.query(children, arrayOf(
                    Document.COLUMN_DOCUMENT_ID, Document.COLUMN_DISPLAY_NAME, Document.COLUMN_MIME_TYPE,
                    Document.COLUMN_LAST_MODIFIED, Document.COLUMN_SIZE, Document.COLUMN_FLAGS,
                ), null, null, null, signal) ?: throw IOException()
            } catch (missing: FileNotFoundException) {
                // A directory removed during traversal should not abort the
                // rest of the scan. A missing root invalidates the source.
                if (id == root) throw missing
                continue
            }
            cursor.use {
                if (it.extras.getBoolean(DocumentsContract.EXTRA_LOADING, false) ||
                    it.extras.containsKey(DocumentsContract.EXTRA_ERROR)) throw IOException()
                while (it.moveToNext()) {
                    signal.throwIfCanceled()
                    val child = it.getString(0) ?: continue
                    if (!seen.add(child)) continue
                    val name = it.getString(1)?.takeIf(String::isNotBlank) ?: continue
                    val mime = it.getString(2).orEmpty()
                    if (mime == Document.MIME_TYPE_DIR) {
                        directories.addLast(child)
                    } else if (isAudio(mime, name)) {
                        val flags = it.numeric(Document.COLUMN_FLAGS) ?: 0L
                        collect(LocalMusicRow(
                            uri = DocumentsContract.buildDocumentUriUsingTree(tree, child).toString(),
                            fileName = name,
                            addedMs = 0,
                            modifiedMs = it.numeric(Document.COLUMN_LAST_MODIFIED)?.takeIf { value -> value > 0 },
                            sizeBytes = it.numeric(Document.COLUMN_SIZE),
                            firstSeen = true,
                            canRename = flags and Document.FLAG_SUPPORTS_RENAME.toLong() != 0L,
                            parentDocumentId = id,
                            parentKey = id,
                        ))
                    }
                }
            }
        }
    }

    private fun scanMediaStore(source: Uri, signal: CancellationSignal, collect: (LocalMusicRow) -> Unit) {
        val columns = mutableListOf(
            Audio._ID, Audio.DISPLAY_NAME, Audio.MIME_TYPE, Audio.SIZE, Audio.DATE_ADDED,
            Audio.DATE_MODIFIED, Audio.TITLE, Audio.ARTIST, Audio.ALBUM, Audio.DURATION,
        )
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q) {
            columns.add(MediaStore.MediaColumns.VOLUME_NAME)
            columns.add(MediaStore.MediaColumns.RELATIVE_PATH)
        } else {
            @Suppress("DEPRECATION")
            columns.add(MediaStore.MediaColumns.DATA)
        }
        val cursor = context.contentResolver.query(source, columns.toTypedArray(), null, null, null, signal)
            ?: throw IOException()
        cursor.use {
            while (it.moveToNext()) {
                signal.throwIfCanceled()
                val id = it.numeric(Audio._ID) ?: continue
                val name = it.string(MediaStore.MediaColumns.DISPLAY_NAME) ?: continue
                if (!isAudio(it.string(MediaStore.MediaColumns.MIME_TYPE).orEmpty(), name)) continue
                val added = mediaStoreTime(it.numeric(MediaStore.MediaColumns.DATE_ADDED))
                val collection: Uri
                val parent: String?
                if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q) {
                    val volume = it.string(MediaStore.MediaColumns.VOLUME_NAME) ?: continue
                    collection = Audio.getContentUri(volume)
                    parent = "$volume:${it.string(MediaStore.MediaColumns.RELATIVE_PATH).orEmpty()}"
                } else {
                    collection = source
                    @Suppress("DEPRECATION")
                    parent = it.string(MediaStore.MediaColumns.DATA)?.let { path -> File(path).parent }
                }
                collect(LocalMusicRow(
                    uri = ContentUris.withAppendedId(collection, id).toString(),
                    fileName = name,
                    addedMs = added ?: 0L,
                    modifiedMs = mediaStoreTime(it.numeric(MediaStore.MediaColumns.DATE_MODIFIED)),
                    sizeBytes = it.numeric(MediaStore.MediaColumns.SIZE),
                    firstSeen = added == null,
                    canRename = true,
                    parentDocumentId = null,
                    parentKey = parent,
                    metadata = LocalMusicMetadata(
                        title = it.string(Audio.TITLE)
                            ?.takeUnless { text -> text == fallbackTitle(name) || text == name },
                        artist = it.string(Audio.ARTIST),
                        album = it.string(Audio.ALBUM),
                        durationMs = it.numeric(Audio.DURATION) ?: 0L,
                    ),
                ))
            }
        }
    }

    private fun readMetadata(uri: Uri, prior: LocalMusicMetadata?): LocalMusicMetadata {
        var metadata = prior ?: LocalMusicMetadata(null, null, null, 0L)
        try {
            readMedia(uri) { retriever ->
                fun tag(key: Int) = retriever.extractMetadata(key)?.trim()?.takeIf(String::isNotEmpty)?.take(1024)
                metadata = metadata.copy(
                    title = tag(MediaMetadataRetriever.METADATA_KEY_TITLE),
                    artist = tag(MediaMetadataRetriever.METADATA_KEY_ARTIST) ?: prior?.artist,
                    album = tag(MediaMetadataRetriever.METADATA_KEY_ALBUM) ?: prior?.album,
                    durationMs = tag(MediaMetadataRetriever.METADATA_KEY_DURATION)?.toLongOrNull()
                        ?.coerceAtLeast(0L) ?: prior?.durationMs ?: 0L,
                )
                retriever.embeddedPicture?.let { metadata = metadata.copy(cover = artwork.store(it)) }
            }
        } catch (denied: SecurityException) {
            throw denied
        } catch (_: RuntimeException) {
            // Many playable files have incomplete tags or unsupported embedded pictures.
        } catch (_: IOException) {
            // A cover-cache failure must not prevent audio playback.
        }
        return metadata
    }

    private fun repairCover(uri: Uri, cover: String) {
        try {
            readMedia(uri) { retriever ->
                retriever.embeddedPicture?.let { artwork.store(it, expectedName = cover) }
            }
        } catch (_: RuntimeException) {
            // A missing thumbnail must not make the indexed song unavailable.
        } catch (_: IOException) { }
    }

    private inline fun readMedia(uri: Uri, read: (MediaMetadataRetriever) -> Unit) {
        val retriever = MediaMetadataRetriever()
        try {
            retriever.setDataSource(context, uri)
            read(retriever)
        } finally {
            try { retriever.release() } catch (_: IOException) { }
        }
    }

    private fun channelValue(row: LocalMusicRow): Map<String, Any?> =
        row.channelValue(row.metadata?.cover?.let(artwork::path))

    private fun Cursor.numeric(name: String): Long? {
        val index = getColumnIndex(name)
        return if (index < 0 || isNull(index)) null else getLong(index).takeIf { it >= 0 }
    }

    private fun Cursor.string(name: String): String? {
        val index = getColumnIndex(name)
        return if (index < 0) null else getString(index)?.takeIf { it.isNotBlank() && it != "<unknown>" }
    }

    private class TrackBatch(private val publish: (List<Map<String, Any?>>) -> Unit) {
        private val rows = mutableListOf<Map<String, Any?>>()
        private var first = true

        fun add(row: Map<String, Any?>) {
            rows.add(row)
            if (first || rows.size == 16) flush()
        }

        fun flush() {
            if (rows.isEmpty()) return
            first = false
            publish(rows.toList())
            rows.clear()
        }
    }

    companion object {
        const val SYSTEM_URI = "content://media/external/audio/media"
        private const val EXTERNAL_STORAGE_PROVIDER = "com.android.externalstorage.documents"

        internal fun containsDocument(treeId: String, documentId: String): Boolean {
            val treeVolume = treeId.substringBefore(':', "")
            val documentVolume = documentId.substringBefore(':', "")
            if (treeVolume.isEmpty() || treeVolume != documentVolume) return false
            val root = treeId.substringAfter(':').trimEnd('/')
            val path = documentId.substringAfter(':')
            if (path.split('/').any { it.isEmpty() || it == "." || it == ".." }) return false
            return root.isEmpty() || path.startsWith("$root/")
        }

        internal fun mediaStoreTime(seconds: Long?): Long? =
            seconds?.takeIf { it in 1..(Long.MAX_VALUE / 1000) }?.times(1000)

        private fun newIdentityKey(): String =
            MessageDigest.getInstance("SHA-256").digest(UUID.randomUUID().toString().toByteArray())
                .joinToString("") { "%02x".format(Locale.ROOT, it) }

        private val audioExtensions = setOf("mp3", "m4a", "m4b", "aac", "flac", "ogg", "oga", "opus",
            "wav", "aif", "aiff", "amr", "wma", "mka", "mid", "midi", "caf", "alac")
        private val playlistExtensions = setOf("m3u", "m3u8", "mpd", "pls", "xspf", "asx", "ism", "sdp")
        internal fun isAudio(mime: String, name: String): Boolean {
            val type = mime.substringBefore(';').trim().lowercase(Locale.ROOT)
            val extension = name.substringAfterLast('.', "").lowercase(Locale.ROOT)
            if (extension in playlistExtensions || type.contains("mpegurl") || type == "audio/x-scpls") return false
            return type.startsWith("audio/") || ((type.isEmpty() || type == "application/octet-stream" ||
                type == "application/ogg") && extension in audioExtensions)
        }
        internal fun fallbackTitle(name: String): String =
            name.substringBeforeLast('.').takeIf { it.isNotBlank() } ?: name
    }
}

/** Repairs a few distinct, previously cached thumbnails after publishing playable rows. */
internal class LocalMusicCoverRepairs {
    private val missing = linkedMapOf<String, String>()
    val candidates: Map<String, String> get() = missing

    fun consider(row: LocalMusicRow, hasCoverFile: Boolean) {
        val cover = row.metadata?.cover ?: return
        if (!hasCoverFile && missing.size < 4) missing.putIfAbsent(cover, row.uri)
    }
}

/** Repeated album covers share one thumbnail. The current library's cache is bounded even during a scan. */
private class LocalMusicCovers(private val folder: File) {
    private val unused = folder.listFiles().orEmpty().filter { it.isFile }.sortedBy { it.lastModified() }.toMutableSet()
    private var cacheBytes = unused.sumOf { it.length() }

    fun path(name: String): String? {
        if (!name.matches(NAME_PATTERN)) return null
        val file = File(folder, name)
        if (!file.isFile) return null
        unused.remove(file)
        return file.absolutePath
    }

    fun store(bytes: ByteArray, expectedName: String? = null): String? {
        if (bytes.isEmpty() || bytes.size > 8 * 1024 * 1024) return null
        val digest = MessageDigest.getInstance("SHA-256").digest(bytes)
        val file = File(folder, Base64.encodeToString(digest, Base64.NO_WRAP or Base64.NO_PADDING or Base64.URL_SAFE) + ".jpg")
        if (expectedName != null && file.name != expectedName) return null
        if (file.isFile) {
            unused.remove(file)
            return file.name
        }
        val options = BitmapFactory.Options().apply { inJustDecodeBounds = true }
        BitmapFactory.decodeByteArray(bytes, 0, bytes.size, options)
        if (options.outWidth <= 0 || options.outHeight <= 0) return null
        options.inJustDecodeBounds = false
        options.inSampleSize = 1
        while (maxOf(options.outWidth, options.outHeight) / options.inSampleSize > 512) options.inSampleSize *= 2
        val bitmap = BitmapFactory.decodeByteArray(bytes, 0, bytes.size, options) ?: return null
        val thumbnail = ByteArrayOutputStream()
        try {
            if (!bitmap.compress(Bitmap.CompressFormat.JPEG, 85, thumbnail)) return null
        } finally {
            bitmap.recycle()
        }
        val old = unused.iterator()
        while (cacheBytes + thumbnail.size() > 24 * 1024 * 1024 && old.hasNext()) {
            val stale = old.next()
            val size = stale.length()
            if (stale.delete()) cacheBytes -= size
            old.remove()
        }
        if (cacheBytes + thumbnail.size() > 24 * 1024 * 1024 || (!folder.isDirectory && !folder.mkdirs())) return null
        val temporary = File.createTempFile("cover-", ".tmp", folder)
        try {
            temporary.outputStream().use { thumbnail.writeTo(it) }
            if (!temporary.renameTo(file)) return null
            cacheBytes += thumbnail.size()
            return file.name
        } finally {
            temporary.delete()
        }
    }

    fun removeUnused() = unused.forEach { it.delete() }

    private companion object {
        val NAME_PATTERN = Regex("[A-Za-z0-9_-]{43}\\.jpg")
    }
}
