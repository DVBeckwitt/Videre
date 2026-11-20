package com.github.dvbeckwitt.videre

import android.Manifest
import android.app.RecoverableSecurityException
import android.content.ContentUris
import android.content.ContentValues
import android.content.Context
import android.content.Intent
import android.content.IntentSender
import android.content.pm.PackageManager
import android.net.Uri
import android.os.Build
import android.os.Process
import android.provider.DocumentsContract
import android.provider.DocumentsContract.Document
import android.provider.MediaStore
import android.provider.MediaStore.MediaColumns
import android.system.Os
import java.io.File

/** Performs a rename only for a file from the active, previously authorized source. */
internal class LocalMusicRename(
    private val context: Context,
    private val beforeMutation: (source: Uri, uri: Uri, name: String) -> Unit,
) {
    sealed interface Step {
        data class Done(val uri: Uri, val fileName: String) : Step
        data class Consent(
            val request: Request,
            val source: Uri,
            val uri: Uri,
            val name: String,
            internal val original: FileState,
        ) : Step
    }

    sealed interface Request {
        data class SelectDocument(val intent: Intent) : Request
        data class Write(val sender: IntentSender) : Request
        data class LegacyWrite(val permission: String) : Request
    }

    class Failure(val code: String) : Exception()

    internal data class FileState(
        val fileName: String,
        val size: Long?,
        val modified: Long?,
        val parent: String?,
        val volume: String? = null,
        val legacyPath: String? = null,
    )

    private val resolver get() = context.contentResolver

    fun begin(
        source: Uri,
        uri: Uri,
        name: String,
        parentDocumentId: String? = null,
        expectedFileName: String? = null,
    ): Step {
        val system = source == MediaStore.Audio.Media.EXTERNAL_CONTENT_URI
        val original = if (system) readMediaFile(uri) else readDocument(source, uri, parentDocumentId)
        if (expectedFileName != null && expectedFileName != original.fileName) throw Failure(CHANGED)
        if (!validName(original.fileName, name)) throw Failure(INVALID_NAME)
        if (name == original.fileName) return Step.Done(uri, name)

        if (!system) {
            requireDocumentTarget(source, uri, original.parent, name)
            if (canWriteDocument(uri)) return renameDocument(source, uri, name)
            val intent = Intent(Intent.ACTION_OPEN_DOCUMENT_TREE).apply {
                addFlags(Intent.FLAG_GRANT_READ_URI_PERMISSION or Intent.FLAG_GRANT_WRITE_URI_PERMISSION or
                    Intent.FLAG_GRANT_PREFIX_URI_PERMISSION)
                putExtra(Intent.EXTRA_LOCAL_ONLY, true)
                if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
                    putExtra(DocumentsContract.EXTRA_INITIAL_URI, source)
                }
            }
            return Step.Consent(Request.SelectDocument(intent), source, uri, name, original)
        }

        if (original.legacyPath != null) {
            if (!hasLegacyWritePermission()) {
                return Step.Consent(Request.LegacyWrite(Manifest.permission.WRITE_EXTERNAL_STORAGE),
                    source, uri, name, original)
            }
            return renameLegacyMedia(source, uri, name, original)
        }

        val writeUri = mediaWriteUri(uri, original)
        requireMediaTarget(uri, original, name)
        return try {
            renameMedia(source, uri, writeUri, name)
        } catch (denied: SecurityException) {
            val sender = when {
                Build.VERSION.SDK_INT >= Build.VERSION_CODES.R ->
                    MediaStore.createWriteRequest(resolver, listOf(writeUri)).intentSender
                Build.VERSION.SDK_INT == Build.VERSION_CODES.Q && denied is RecoverableSecurityException ->
                    denied.userAction.actionIntent.intentSender
                else -> throw Failure(UNSUPPORTED)
            }
            Step.Consent(Request.Write(sender), source, uri, name, original)
        }
    }

    fun finish(consent: Step.Consent, data: Intent?): Step.Done = with(consent) {
        when (request) {
            is Request.SelectDocument -> {
                // A write grant is only useful for the tree that contained the original song.
                if (data == null || data.data != source || data.flags and Intent.FLAG_GRANT_WRITE_URI_PERMISSION == 0 ||
                    !canWriteDocument(uri)) {
                    throw Failure(ACCESS)
                }
                if (readDocument(source, uri, original.parent) != original) throw Failure(CHANGED)
                requireDocumentTarget(source, uri, original.parent, name)
                renameDocument(source, uri, name)
            }
            is Request.Write -> {
                if (readMediaFile(uri) != original) throw Failure(CHANGED)
                requireMediaTarget(uri, original, name)
                renameMedia(source, uri, mediaWriteUri(uri, original), name)
            }
            is Request.LegacyWrite -> {
                if (!hasLegacyWritePermission()) throw Failure(ACCESS)
                if (readMediaFile(uri) != original) throw Failure(CHANGED)
                renameLegacyMedia(source, uri, name, original)
            }
        }
    }

    private fun readDocument(source: Uri, uri: Uri, parent: String?): FileState {
        if (!belongsToTree(source, uri)) throw Failure(CHANGED)
        val columns = arrayOf(Document.COLUMN_DISPLAY_NAME, Document.COLUMN_SIZE, Document.COLUMN_LAST_MODIFIED,
            Document.COLUMN_FLAGS, Document.COLUMN_MIME_TYPE)
        return resolver.query(uri, columns, null, null, null)?.use {
            if (it.extras.getBoolean(DocumentsContract.EXTRA_LOADING) ||
                it.extras.containsKey(DocumentsContract.EXTRA_ERROR) || !it.moveToFirst()) throw Failure(CHANGED)
            if (it.getInt(3) and Document.FLAG_SUPPORTS_RENAME == 0) throw Failure(UNSUPPORTED)
            val name = it.getString(0) ?: throw Failure(CHANGED)
            if (!LocalMusicCatalog.isAudio(it.getString(4).orEmpty(), name)) throw Failure(CHANGED)
            FileState(name, if (it.isNull(1)) null else it.getLong(1), if (it.isNull(2)) null else it.getLong(2), parent)
        } ?: throw Failure(CHANGED)
    }

    private fun requireDocumentTarget(source: Uri, uri: Uri, parent: String?, name: String) {
        if (parent == null) throw Failure(UNSUPPORTED)
        val children = DocumentsContract.buildChildDocumentsUriUsingTree(source, parent)
        val currentId = DocumentsContract.getDocumentId(uri)
        var containsCurrent = false
        resolver.query(children, arrayOf(Document.COLUMN_DOCUMENT_ID, Document.COLUMN_DISPLAY_NAME),
            null, null, null)?.use {
            if (it.extras.getBoolean(DocumentsContract.EXTRA_LOADING) ||
                it.extras.containsKey(DocumentsContract.EXTRA_ERROR)) throw Failure(UNSUPPORTED)
            while (it.moveToNext()) {
                if (it.getString(0) == currentId) {
                    containsCurrent = true
                } else if (name.equals(it.getString(1), ignoreCase = true)) {
                    throw Failure(COLLISION)
                }
            }
        }
        if (!containsCurrent) throw Failure(CHANGED)
    }

    private fun renameDocument(source: Uri, uri: Uri, name: String): Step.Done {
        beforeMutation(source, uri, name)
        val returned = DocumentsContract.renameDocument(resolver, uri, name) ?: throw Failure(FAILED)
        if (returned.authority != source.authority) throw Failure(FAILED)
        // Rebuild the URI under the original tree even if the provider returned a plain document URI.
        val renamed = DocumentsContract.buildDocumentUriUsingTree(source, DocumentsContract.getDocumentId(returned))
        val actualName = resolver.query(renamed, arrayOf(Document.COLUMN_DISPLAY_NAME), null, null, null)?.use {
            if (it.moveToFirst()) it.getString(0) else null
        }
        return Step.Done(renamed, actualName ?: name)
    }

    private fun canWriteDocument(uri: Uri): Boolean =
        context.checkUriPermission(uri, Process.myPid(), Process.myUid(), Intent.FLAG_GRANT_WRITE_URI_PERMISSION) ==
            PackageManager.PERMISSION_GRANTED

    private fun belongsToTree(source: Uri, uri: Uri): Boolean {
        val tree = source.pathSegments
        val document = uri.pathSegments
        return source.scheme == "content" && tree.size == 2 && tree[0] == "tree" &&
            uri.scheme == "content" && source.authority == uri.authority && uri.encodedQuery == null &&
            uri.encodedFragment == null && document.size == 4 && document[0] == "tree" &&
            document[1] == tree[1] && document[2] == "document" && document[3].isNotEmpty()
    }

    @Suppress("DEPRECATION")
    private fun readMediaFile(uri: Uri): FileState {
        val path = uri.pathSegments
        if (uri.scheme != "content" || uri.authority != MediaStore.AUTHORITY || uri.encodedQuery != null ||
            uri.encodedFragment != null || path.size != 4 || path[0] == "internal" ||
            path[1] != "audio" || path[2] != "media" || (path[3].toLongOrNull() ?: 0) <= 0) {
            throw Failure(CHANGED)
        }
        val modern = Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q
        val columns = arrayOf(MediaColumns.DISPLAY_NAME, MediaColumns.SIZE, MediaColumns.DATE_MODIFIED) +
            if (modern) arrayOf(MediaColumns.RELATIVE_PATH, MediaColumns.VOLUME_NAME) else arrayOf(MediaColumns.DATA)
        return resolver.query(uri, columns, null, null, null)?.use {
            if (!it.moveToFirst()) throw Failure(CHANGED)
            val name = it.getString(0) ?: throw Failure(CHANGED)
            val size = if (it.isNull(1)) null else it.getLong(1)
            val modified = if (it.isNull(2)) null else it.getLong(2)
            if (modern) {
                val volume = it.getString(4)?.takeIf { candidate -> candidate in MediaStore.getExternalVolumeNames(context) }
                    ?: throw Failure(CHANGED)
                if (path[0] != MediaStore.VOLUME_EXTERNAL && path[0] != volume) throw Failure(CHANGED)
                FileState(name, size, modified, it.getString(3), volume = volume)
            } else {
                FileState(name, size, modified, null,
                    legacyPath = it.getString(3)?.takeIf { value -> value.isNotBlank() } ?: throw Failure(UNSUPPORTED))
            }
        } ?: throw Failure(CHANGED)
    }

    private fun mediaWriteUri(uri: Uri, original: FileState): Uri {
        val volume = original.volume ?: throw Failure(UNSUPPORTED)
        return ContentUris.withAppendedId(MediaStore.Audio.Media.getContentUri(volume), ContentUris.parseId(uri))
    }

    private fun requireMediaTarget(uri: Uri, original: FileState, name: String) {
        val volume = original.volume ?: throw Failure(UNSUPPORTED)
        val id = ContentUris.parseId(uri)
        val selection = if (original.parent == null) "${MediaColumns.RELATIVE_PATH} IS NULL"
            else "${MediaColumns.RELATIVE_PATH} = ?"
        val arguments = original.parent?.let { arrayOf(it) }
        resolver.query(MediaStore.Files.getContentUri(volume), arrayOf(MediaColumns._ID, MediaColumns.DISPLAY_NAME),
            selection, arguments, null)?.use {
            while (it.moveToNext()) {
                if (it.getLong(0) != id && name.equals(it.getString(1), ignoreCase = true)) throw Failure(COLLISION)
            }
        } ?: throw Failure(UNSUPPORTED)
    }

    private fun renameMedia(source: Uri, uri: Uri, writeUri: Uri, name: String): Step.Done {
        beforeMutation(source, uri, name)
        val values = ContentValues().apply { put(MediaColumns.DISPLAY_NAME, name) }
        if (resolver.update(writeUri, values, null, null) != 1) throw Failure(FAILED)
        return Step.Done(uri, readMediaFile(uri).fileName)
    }

    @Suppress("DEPRECATION")
    private fun hasLegacyWritePermission(): Boolean =
        context.checkSelfPermission(Manifest.permission.WRITE_EXTERNAL_STORAGE) == PackageManager.PERMISSION_GRANTED

    @Suppress("DEPRECATION")
    private fun renameLegacyMedia(source: Uri, uri: Uri, name: String, original: FileState): Step.Done {
        check(Build.VERSION.SDK_INT < Build.VERSION_CODES.Q)
        val old = File(original.legacyPath ?: throw Failure(UNSUPPORTED)).canonicalFile
        val parent = old.parentFile ?: throw Failure(UNSUPPORTED)
        if (old.name != original.fileName) throw Failure(CHANGED)
        // Confirm this path is the same file the authorized MediaStore row can open.
        resolver.openFileDescriptor(uri, "r")?.use {
            val granted = Os.fstat(it.fileDescriptor)
            val actual = Os.lstat(old.path)
            if (actual.st_dev != granted.st_dev || actual.st_ino != granted.st_ino) throw Failure(CHANGED)
        } ?: throw Failure(CHANGED)
        val new = File(parent, name)
        beforeMutation(source, uri, name)
        // Reserve the name atomically so rename cannot replace an existing file.
        if (!new.createNewFile()) throw Failure(COLLISION)
        try {
            Os.rename(old.path, new.path)
        } catch (failure: Exception) {
            new.delete()
            throw failure
        }
        try {
            val values = ContentValues().apply {
                // Pre-scoped-storage MediaStore indexes the actual filesystem path.
                put(MediaColumns.DATA, new.path)
                put(MediaColumns.DISPLAY_NAME, name)
            }
            if (resolver.update(uri, values, null, null) != 1) throw Failure(FAILED)
        } catch (failure: Exception) {
            // Undo a definite files-only rename when the database still points to its old path.
            val indexed = runCatching { readMediaFile(uri).legacyPath }.getOrNull()
            if (indexed == original.legacyPath && old.createNewFile()) {
                try {
                    Os.rename(new.path, old.path)
                } catch (_: Exception) {
                    old.delete()
                }
            }
            throw failure
        }
        return Step.Done(uri, name)
    }

    companion object {
        private const val INVALID_NAME = "RENAME_INVALID_NAME"
        private const val CHANGED = "RENAME_CHANGED"
        private const val COLLISION = "RENAME_COLLISION"
        private const val UNSUPPORTED = "RENAME_UNSUPPORTED"
        private const val ACCESS = "RENAME_ACCESS"
        private const val FAILED = "RENAME_FAILED"

        internal fun validName(old: String, new: String): Boolean {
            val extension = old.lastIndexOf('.').takeIf { it > 0 && it < old.lastIndex }
                ?.let(old::substring).orEmpty()
            return new.isNotBlank() && new == new.trim() && !new.startsWith('.') && !new.endsWith('.') &&
                new.toByteArray(Charsets.UTF_8).size <= 255 &&
                new.none { it.isISOControl() || it in "/\\<>:\"|?*" } &&
                LocalMusicCatalog.isAudio("audio/*", new) &&
                (extension.isEmpty() || (new.endsWith(extension) && new.length > extension.length))
        }
    }
}
