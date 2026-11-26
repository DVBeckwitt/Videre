package com.github.dvbeckwitt.videre

import android.Manifest
import android.app.RecoverableSecurityException
import android.content.Context
import android.content.Intent
import android.content.pm.PackageManager
import android.graphics.BitmapFactory
import android.net.Uri
import android.os.Build
import android.os.ParcelFileDescriptor
import android.os.Process
import android.provider.DocumentsContract
import android.provider.DocumentsContract.Document
import android.provider.MediaStore
import android.provider.MediaStore.MediaColumns
import android.system.ErrnoException
import android.system.Os
import android.system.OsConstants
import android.util.AtomicFile
import java.io.DataInputStream
import java.io.DataOutputStream
import java.io.File
import java.io.FileDescriptor
import java.io.FileNotFoundException
import java.io.IOException
import java.security.MessageDigest

/** Edits a fixed-length ID3 prefix through the original, writable content URI. */
internal class LocalMusicTagEdit(private val context: Context) {
    data class Inspection(
        val revision: String,
        val tags: LocalMusicId3.Inspection,
        val artwork: LocalMusicId3.ArtworkState,
    )

    sealed interface Step {
        data class Done(val values: Map<String, String?>, val fileProof: String, val changed: Boolean) : Step
        class Consent internal constructor(
            val request: LocalMusicRename.Request,
            internal val source: Uri,
            internal val uri: Uri,
            internal val expectedName: String,
            internal val prepared: Prepared,
        ) : Step
    }

    class Failure(val code: String) : IOException()

    internal data class Prepared(
        val revision: String,
        val replacement: ByteArray,
        val values: Map<String, String?>,
        val originalProof: String,
        val changed: Boolean,
    )

    private data class FileIdentity(val device: Long, val inode: Long, val length: Long)

    private data class FileStamp(
        val identity: FileIdentity,
        val modified: Long,
        val modifiedNanos: Long,
        val changed: Long,
        val changedNanos: Long,
    ) {
        val fileProof: String get() = localMusicVisibilityFingerprint(
            "rename-descriptor", identity.device.toString(), identity.inode.toString(),
            changed.toString(), changedNanos.toString(), identity.length.toString(),
        )
    }

    private data class Snapshot(val stamp: FileStamp, val prefix: ByteArray, val audioProof: ByteArray) {
        val revision: String get() = MessageDigest.getInstance("SHA-256").run {
            update(stamp.toString().toByteArray(Charsets.UTF_8))
            update(prefix)
            update(audioProof)
            hex(digest())
        }
    }

    private data class Recovery(
        val identity: FileIdentity,
        val audioProof: ByteArray,
        val original: ByteArray,
        val replacement: ByteArray,
    )

    private data class MpegFrame(val version: Int, val sampleRate: Int, val length: Int)

    private val resolver get() = context.contentResolver

    fun inspect(source: Uri, uri: Uri, expectedName: String): Inspection = checked {
        val system = verifyTarget(source, uri, expectedName)
        if (!system) requireDocumentWritable(uri)
        withRead(uri) { descriptor ->
            val snapshot = snapshot(uri, descriptor)
            Inspection(
                snapshot.revision,
                LocalMusicId3.inspectEditable(snapshot.prefix),
                LocalMusicId3.artworkState(snapshot.prefix),
            )
        }
    }

    fun begin(
        source: Uri,
        uri: Uri,
        expectedName: String,
        revision: String,
        changes: Map<String, String?>,
        artwork: LocalMusicId3.ArtworkEdit? = null,
        lyrics: LocalMusicUslt.Edit? = null,
    ): Step = checked {
        val system = verifyTarget(source, uri, expectedName)
        if (!system) requireDocumentWritable(uri)
        val prepared = withRead(uri) { descriptor ->
            val snapshot = snapshot(uri, descriptor)
            if (snapshot.revision != revision) throw Failure(CHANGED)
            artwork?.image?.let(::requireArtworkImage)
            val replacement = LocalMusicId3.edit(snapshot.prefix, changes, artwork = artwork, lyrics = lyrics)
            if (replacement.size != snapshot.prefix.size) throw Failure(UNSUPPORTED)
            val values = LocalMusicId3.inspect(replacement)
            Prepared(revision, replacement, values, snapshot.stamp.fileProof,
                !replacement.contentEquals(snapshot.prefix))
        }
        if (!prepared.changed) return@checked Step.Done(prepared.values, prepared.originalProof, changed = false)

        fun consent(request: LocalMusicRename.Request) =
            Step.Consent(request, source, uri, expectedName, prepared)

        if (!system && !hasSavedWriteGrant(source, uri)) {
            val intent = Intent(Intent.ACTION_OPEN_DOCUMENT_TREE).apply {
                addFlags(Intent.FLAG_GRANT_READ_URI_PERMISSION or Intent.FLAG_GRANT_WRITE_URI_PERMISSION or
                    Intent.FLAG_GRANT_PREFIX_URI_PERMISSION)
                putExtra(Intent.EXTRA_LOCAL_ONLY, true)
                if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
                    putExtra(DocumentsContract.EXTRA_INITIAL_URI, source)
                }
            }
            return@checked consent(LocalMusicRename.Request.SelectDocument(intent))
        }
        if (system && Build.VERSION.SDK_INT < Build.VERSION_CODES.Q && !hasLegacyWritePermission()) {
            return@checked consent(LocalMusicRename.Request.LegacyWrite(Manifest.permission.WRITE_EXTERNAL_STORAGE))
        }
        val descriptor = try {
            openWrite(uri)
        } catch (denied: SecurityException) {
            if (!system) throw Failure(ACCESS)
            val sender = when {
                Build.VERSION.SDK_INT >= Build.VERSION_CODES.R ->
                    MediaStore.createWriteRequest(resolver, listOf(uri)).intentSender
                Build.VERSION.SDK_INT == Build.VERSION_CODES.Q && denied is RecoverableSecurityException ->
                    denied.userAction.actionIntent.intentSender
                else -> throw Failure(ACCESS)
            }
            return@checked consent(LocalMusicRename.Request.Write(sender))
        }
        write(uri, descriptor, prepared)
    }

    private fun requireArtworkImage(bytes: ByteArray) {
        val mime = LocalMusicId3.imageMime(bytes) ?: throw Failure("TAGS_ARTWORK_INVALID")
        val options = BitmapFactory.Options().apply { inJustDecodeBounds = true }
        BitmapFactory.decodeByteArray(bytes, 0, bytes.size, options)
        if (options.outMimeType != mime || options.outWidth !in 1..MAX_ARTWORK_DIMENSION ||
            options.outHeight !in 1..MAX_ARTWORK_DIMENSION) throw Failure("TAGS_ARTWORK_INVALID")
        options.inJustDecodeBounds = false
        // Check that the image actually decodes, using a bounded thumbnail.
        options.inSampleSize = Integer.highestOneBit(maxOf(1, maxOf(options.outWidth, options.outHeight) / 128))
        val bitmap = BitmapFactory.decodeByteArray(bytes, 0, bytes.size, options)
            ?: throw Failure("TAGS_ARTWORK_INVALID")
        bitmap.recycle()
    }

    fun finish(consent: Step.Consent, data: Intent?): Step.Done = checked {
        val uri = consent.uri
        verifyTarget(consent.source, uri, consent.expectedName)
        when (consent.request) {
            is LocalMusicRename.Request.SelectDocument -> {
                if (data == null || data.data != consent.source ||
                    data.flags and Intent.FLAG_GRANT_WRITE_URI_PERMISSION == 0 ||
                    !canWriteDocument(uri)) throw Failure(ACCESS)
                requireDocumentWritable(uri)
            }
            is LocalMusicRename.Request.LegacyWrite -> if (!hasLegacyWritePermission()) throw Failure(ACCESS)
            is LocalMusicRename.Request.Write -> Unit
        }
        write(uri, openWrite(uri), consent.prepared)
    }

    private fun verifyTarget(source: Uri, uri: Uri, expectedName: String): Boolean {
        if (!expectedName.endsWith(".mp3", ignoreCase = true)) throw Failure(UNSUPPORTED)
        val path = uri.pathSegments
        if (uri.scheme != "content" || uri.encodedQuery != null || uri.encodedFragment != null) throw Failure(CHANGED)
        val system = source == MediaStore.Audio.Media.EXTERNAL_CONTENT_URI
        if (system) {
            if (uri.authority != MediaStore.AUTHORITY || path.size != 4 || path[1] != "audio" ||
                path[2] != "media" || (path[3].toLongOrNull() ?: 0) <= 0) throw Failure(CHANGED)
            val modern = Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q
            if (modern && path[0] !in MediaStore.getExternalVolumeNames(context) ||
                !modern && path[0] != "external") throw Failure(CHANGED)
            val columns = if (modern) arrayOf(MediaColumns.DISPLAY_NAME, MediaColumns.VOLUME_NAME)
                else arrayOf(MediaColumns.DISPLAY_NAME)
            resolver.query(uri, columns, null, null, null)?.use {
                if (!it.moveToFirst() || it.getString(0) != expectedName ||
                    modern && it.getString(1) != path[0]) throw Failure(CHANGED)
            } ?: throw Failure(CHANGED)
        } else {
            val tree = source.pathSegments
            if (source.scheme != "content" || source.authority != EXTERNAL_STORAGE_PROVIDER ||
                uri.authority != EXTERNAL_STORAGE_PROVIDER) throw Failure(UNSUPPORTED)
            if (source.encodedQuery != null || source.encodedFragment != null || tree.size != 2 ||
                tree[0] != "tree" || path.size != 4 || path[0] != "tree" || path[1] != tree[1] ||
                path[2] != "document" || path[3].isEmpty()) throw Failure(CHANGED)
            resolver.query(uri, arrayOf(Document.COLUMN_DISPLAY_NAME), null, null, null)?.use {
                if (it.extras.getBoolean(DocumentsContract.EXTRA_LOADING) ||
                    it.extras.containsKey(DocumentsContract.EXTRA_ERROR) ||
                    !it.moveToFirst() || it.getString(0) != expectedName) throw Failure(CHANGED)
            } ?: throw Failure(CHANGED)
        }
        return system
    }

    private fun requireDocumentWritable(uri: Uri) {
        resolver.query(uri, arrayOf(Document.COLUMN_FLAGS), null, null, null)?.use {
            if (it.extras.getBoolean(DocumentsContract.EXTRA_LOADING) ||
                it.extras.containsKey(DocumentsContract.EXTRA_ERROR) || !it.moveToFirst()) throw Failure(CHANGED)
            if (it.getInt(0) and Document.FLAG_SUPPORTS_WRITE == 0) throw Failure(UNSUPPORTED)
        } ?: throw Failure(CHANGED)
    }

    private fun canWriteDocument(uri: Uri): Boolean =
        context.checkUriPermission(uri, Process.myPid(), Process.myUid(), Intent.FLAG_GRANT_WRITE_URI_PERMISSION) ==
            PackageManager.PERMISSION_GRANTED

    private fun hasSavedWriteGrant(source: Uri, uri: Uri): Boolean =
        resolver.persistedUriPermissions.any { it.uri == source && it.isWritePermission } && canWriteDocument(uri)

    @Suppress("DEPRECATION")
    private fun hasLegacyWritePermission(): Boolean =
        context.checkSelfPermission(Manifest.permission.WRITE_EXTERNAL_STORAGE) == PackageManager.PERMISSION_GRANTED

    private fun <T> withRead(uri: Uri, read: (FileDescriptor) -> T): T =
        resolver.openFileDescriptor(uri, "r")?.use { read(it.fileDescriptor) } ?: throw Failure(CHANGED)

    private fun openWrite(uri: Uri): ParcelFileDescriptor =
        resolver.openFileDescriptor(uri, "rw") ?: throw Failure(ACCESS)

    private fun snapshot(uri: Uri, descriptor: FileDescriptor): Snapshot {
        val before = stamp(descriptor)
        inspectRecovery(uri, descriptor, before.identity)
        if (before.identity.length < ID3_HEADER_SIZE) throw Failure(UNSUPPORTED)
        val header = readExactly(descriptor, 0, ID3_HEADER_SIZE)
        val prefixSize = LocalMusicId3.tagSize(header)
        if (prefixSize !in ID3_HEADER_SIZE..MAX_PREFIX_SIZE || prefixSize >= before.identity.length) {
            throw Failure(UNSUPPORTED)
        }
        val prefix = readExactly(descriptor, 0, prefixSize)
        val audio = audioProof(descriptor, prefixSize, before.identity.length)
        if (stamp(descriptor) != before) throw Failure(CHANGED)
        return Snapshot(before, prefix, audio)
    }

    private fun stamp(descriptor: FileDescriptor): FileStamp {
        val stat = Os.fstat(descriptor)
        if (!OsConstants.S_ISREG(stat.st_mode) || stat.st_ino == 0L || stat.st_nlink != 1L ||
            stat.st_size <= 0L || stat.st_ctime <= 0L) throw Failure(UNSUPPORTED)
        val nanosAvailable = Build.VERSION.SDK_INT >= Build.VERSION_CODES.O_MR1
        return FileStamp(
            FileIdentity(stat.st_dev, stat.st_ino, stat.st_size),
            stat.st_mtime, if (nanosAvailable) stat.st_mtim.tv_nsec else 0L,
            stat.st_ctime, if (nanosAvailable) stat.st_ctim.tv_nsec else 0L,
        )
    }

    private fun audioProof(descriptor: FileDescriptor, prefixSize: Int, length: Long): ByteArray {
        var offset = prefixSize.toLong()
        var first: MpegFrame? = null
        repeat(3) {
            if (offset > length - MPEG_HEADER_SIZE) throw Failure(UNSUPPORTED)
            val frame = mpegFrame(readExactly(descriptor, offset, MPEG_HEADER_SIZE))
                ?: throw Failure(UNSUPPORTED)
            val initial = first
            if (initial == null) first = frame
            else if (frame.version != initial.version || frame.sampleRate != initial.sampleRate) {
                throw Failure(UNSUPPORTED)
            }
            offset += frame.length
            if (offset > length) throw Failure(UNSUPPORTED)
        }
        return sha256(readExactly(descriptor, prefixSize.toLong(), (offset - prefixSize).toInt()))
    }

    private fun mpegFrame(bytes: ByteArray): MpegFrame? {
        val second = bytes[1].toInt() and 0xff
        val third = bytes[2].toInt() and 0xff
        val version = (second ushr 3) and 3
        val layer = (second ushr 1) and 3
        val bitrateIndex = third ushr 4
        val sampleRateIndex = (third ushr 2) and 3
        if (bytes[0].toInt() and 0xff != 0xff || second and 0xe0 != 0xe0 || version == 1 || layer != 1 ||
            bitrateIndex !in 1..14 || sampleRateIndex == 3) return null
        val divisor = when (version) {
            3 -> 1
            2 -> 2
            else -> 4
        }
        val sampleRate = SAMPLE_RATES[sampleRateIndex] / divisor
        val bitrate = if (version == 3) MPEG1_BITRATES[bitrateIndex - 1] else MPEG2_BITRATES[bitrateIndex - 1]
        val coefficient = if (version == 3) 144000 else 72000
        val padding = (third ushr 1) and 1
        return MpegFrame(version, sampleRate, coefficient * bitrate / sampleRate + padding)
    }

    private fun write(uri: Uri, descriptor: ParcelFileDescriptor, prepared: Prepared): Step.Done {
        var saved: Step.Done? = null
        val journal = recoveryFile(uri)
        try {
            descriptor.use {
                val fd = it.fileDescriptor
                val flags = Os.fcntlInt(fd, OsConstants.F_GETFL, 0)
                if (flags and OsConstants.O_ACCMODE != OsConstants.O_RDWR ||
                    flags and OsConstants.O_APPEND != 0) throw Failure(UNSUPPORTED)
                val current = snapshot(uri, fd)
                if (current.revision != prepared.revision || current.prefix.size != prepared.replacement.size) {
                    throw Failure(CHANGED)
                }
                val recovery = Recovery(current.stamp.identity, current.audioProof, current.prefix, prepared.replacement)
                saveRecovery(journal, recovery)
                if (stamp(fd) != current.stamp) {
                    journal.delete()
                    throw Failure(CHANGED)
                }
                try {
                    writeExactly(fd, recovery.replacement)
                    val proof = verifyWrite(fd, recovery, recovery.replacement).fileProof
                    saved = Step.Done(prepared.values, proof, changed = true)
                } catch (_: Exception) {
                    if (!restore(fd, recovery)) throw Failure(RECOVERY_REQUIRED)
                    journal.delete()
                    throw Failure(FAILED)
                }
            }
        } catch (error: Exception) {
            // The bytes were verified, but the provider did not complete close.
            if (saved != null) throw Failure(RECOVERY_REQUIRED)
            throw error
        }
        journal.delete()
        return checkNotNull(saved)
    }

    private fun verifyWrite(descriptor: FileDescriptor, recovery: Recovery, expected: ByteArray): FileStamp {
        Os.fsync(descriptor)
        val before = stamp(descriptor)
        if (!matchesFile(descriptor, recovery) ||
            !readExactly(descriptor, 0, expected.size).contentEquals(expected) ||
            stamp(descriptor) != before) throw IOException()
        return before
    }

    private fun restore(descriptor: FileDescriptor, recovery: Recovery): Boolean = try {
        if (!matchesFile(descriptor, recovery)) false
        else {
            val current = readExactly(descriptor, 0, recovery.original.size)
            if (isPartialWrite(current, recovery)) {
                if (!current.contentEquals(recovery.original)) writeExactly(descriptor, recovery.original)
                verifyWrite(descriptor, recovery, recovery.original)
                true
            } else false
        }
    } catch (_: Exception) {
        false
    }

    private fun isPartialWrite(current: ByteArray, recovery: Recovery): Boolean {
        // pwrite advances from the start. Anything outside this single transition
        // may be another writer's change and must never be rolled back here.
        var inReplacement = true
        for (index in current.indices) {
            if (inReplacement && current[index] == recovery.replacement[index]) continue
            inReplacement = false
            if (current[index] != recovery.original[index]) return false
        }
        return true
    }

    private fun matchesFile(descriptor: FileDescriptor, recovery: Recovery): Boolean =
        stamp(descriptor).identity == recovery.identity &&
            audioProof(descriptor, recovery.original.size, recovery.identity.length).contentEquals(recovery.audioProof)

    private fun recoveryFile(uri: Uri): AtomicFile {
        val key = hex(sha256(uri.toString().toByteArray(Charsets.UTF_8)))
        return AtomicFile(File(File(context.noBackupFilesDir, "music-tag-recovery"), "$key.bin"))
    }

    private fun saveRecovery(journal: AtomicFile, recovery: Recovery) {
        val folder = journal.baseFile.parentFile ?: throw Failure(FAILED)
        if (!folder.isDirectory) {
            if (!folder.mkdir()) throw Failure(FAILED)
            syncDirectory(context.noBackupFilesDir)
        }
        val stream = journal.startWrite()
        try {
            val output = DataOutputStream(stream)
            output.writeInt(JOURNAL_VERSION)
            output.writeLong(recovery.identity.device)
            output.writeLong(recovery.identity.inode)
            output.writeLong(recovery.identity.length)
            output.writeInt(recovery.original.size)
            output.write(recovery.audioProof)
            output.write(recovery.original)
            output.write(recovery.replacement)
            output.flush()
            stream.fd.sync()
            journal.finishWrite(stream)
        } catch (error: Exception) {
            journal.failWrite(stream)
            throw error
        }
        val saved = readRecovery(journal) ?: throw Failure(FAILED)
        if (saved.identity != recovery.identity || !saved.audioProof.contentEquals(recovery.audioProof) ||
            !saved.original.contentEquals(recovery.original) || !saved.replacement.contentEquals(recovery.replacement)) {
            throw Failure(FAILED)
        }
        syncDirectory(folder)
    }

    private fun syncDirectory(folder: File) {
        val descriptor = Os.open(folder.path, OsConstants.O_RDONLY, 0)
        try {
            if (!OsConstants.S_ISDIR(Os.fstat(descriptor).st_mode)) throw Failure(FAILED)
            Os.fsync(descriptor)
        } finally {
            Os.close(descriptor)
        }
    }

    private fun readRecovery(journal: AtomicFile): Recovery? {
        val input = try {
            DataInputStream(journal.openRead())
        } catch (_: FileNotFoundException) {
            if (journal.baseFile.exists()) throw Failure(RECOVERY_REQUIRED)
            return null
        }
        try {
            return input.use {
                if (it.readInt() != JOURNAL_VERSION) throw Failure(RECOVERY_REQUIRED)
                val identity = FileIdentity(it.readLong(), it.readLong(), it.readLong())
                val size = it.readInt()
                if (size !in ID3_HEADER_SIZE..MAX_PREFIX_SIZE || size >= identity.length) {
                    throw Failure(RECOVERY_REQUIRED)
                }
                val audio = ByteArray(SHA256_SIZE).also(it::readFully)
                val old = ByteArray(size).also(it::readFully)
                val new = ByteArray(size).also(it::readFully)
                if (it.read() != -1) throw Failure(RECOVERY_REQUIRED)
                Recovery(identity, audio, old, new)
            }
        } catch (_: IOException) {
            throw Failure(RECOVERY_REQUIRED)
        }
    }

    private fun inspectRecovery(uri: Uri, descriptor: FileDescriptor, identity: FileIdentity) {
        val journal = recoveryFile(uri)
        val recovery = readRecovery(journal) ?: return
        try {
            if (identity != recovery.identity || !matchesFile(descriptor, recovery)) throw Failure(RECOVERY_REQUIRED)
            val prefix = readExactly(descriptor, 0, recovery.original.size)
            if (!prefix.contentEquals(recovery.original) && !prefix.contentEquals(recovery.replacement)) {
                throw Failure(RECOVERY_REQUIRED)
            }
            journal.delete()
        } catch (_: Exception) {
            throw Failure(RECOVERY_REQUIRED)
        }
    }

    private fun readExactly(descriptor: FileDescriptor, position: Long, size: Int): ByteArray {
        val result = ByteArray(size)
        var offset = 0
        while (offset < size) {
            val count = Os.pread(descriptor, result, offset, size - offset, position + offset)
            if (count <= 0) throw Failure(CHANGED)
            offset += count
        }
        return result
    }

    private fun writeExactly(descriptor: FileDescriptor, bytes: ByteArray) {
        var offset = 0
        while (offset < bytes.size) {
            val count = Os.pwrite(descriptor, bytes, offset, bytes.size - offset, offset.toLong())
            if (count <= 0) throw IOException()
            offset += count
        }
    }

    private inline fun <T> checked(action: () -> T): T = try {
        action()
    } catch (failure: Failure) {
        throw failure
    } catch (_: LocalMusicId3.Unsupported) {
        throw Failure(UNSUPPORTED)
    } catch (_: LocalMusicId3.NoSpace) {
        throw Failure(NO_SPACE)
    } catch (_: LocalMusicId3.InvalidReleaseDate) {
        throw Failure(INVALID_RELEASE_DATE)
    } catch (_: LocalMusicId3.InvalidNumber) {
        throw Failure(INVALID_NUMBER)
    } catch (_: SecurityException) {
        throw Failure(ACCESS)
    } catch (_: FileNotFoundException) {
        throw Failure(CHANGED)
    } catch (error: ErrnoException) {
        throw Failure(if (error.errno == OsConstants.ESPIPE) UNSUPPORTED else FAILED)
    } catch (_: IOException) {
        throw Failure(FAILED)
    } catch (_: UnsupportedOperationException) {
        throw Failure(UNSUPPORTED)
    }

    companion object {
        private const val UNSUPPORTED = "TAGS_UNSUPPORTED"
        private const val CHANGED = "TAGS_CHANGED"
        private const val NO_SPACE = "TAGS_NO_SPACE"
        private const val INVALID_NUMBER = "TAGS_INVALID_NUMBER"
        private const val INVALID_RELEASE_DATE = "TAGS_INVALID_RELEASE_DATE"
        private const val ACCESS = "TAGS_ACCESS"
        private const val FAILED = "TAGS_FAILED"
        private const val RECOVERY_REQUIRED = "TAGS_RECOVERY_REQUIRED"
        private const val EXTERNAL_STORAGE_PROVIDER = "com.android.externalstorage.documents"
        private const val ID3_HEADER_SIZE = 10
        private const val MPEG_HEADER_SIZE = 4
        private const val SHA256_SIZE = 32
        private const val JOURNAL_VERSION = 1
        private const val MAX_PREFIX_SIZE = 8 * 1024 * 1024
        private const val MAX_ARTWORK_DIMENSION = 4096
        private val MPEG1_BITRATES = intArrayOf(32, 40, 48, 56, 64, 80, 96, 112, 128, 160, 192, 224, 256, 320)
        private val MPEG2_BITRATES = intArrayOf(8, 16, 24, 32, 40, 48, 56, 64, 80, 96, 112, 128, 144, 160)
        private val SAMPLE_RATES = intArrayOf(44100, 48000, 32000)

        private fun sha256(bytes: ByteArray): ByteArray = MessageDigest.getInstance("SHA-256").digest(bytes)
        private fun hex(bytes: ByteArray): String = bytes.joinToString("") { "%02x".format(it.toInt() and 0xff) }
    }
}
