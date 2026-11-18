package com.github.dvbeckwitt.videre.proxy

import android.content.Context
import android.net.Uri
import android.os.Build
import android.os.ParcelFileDescriptor
import android.provider.DocumentsContract
import android.system.Os
import android.system.OsConstants
import android.system.StructStat
import androidx.media3.common.C
import androidx.media3.datasource.BaseDataSource
import androidx.media3.datasource.DataSource
import androidx.media3.datasource.DataSpec
import java.io.File
import java.io.FileInputStream
import java.io.IOException
import java.nio.ByteBuffer
import java.security.MessageDigest

/** A local candidate may be skipped, but its bytes must never become remote cache spans. */
class LocalDownloadUnavailable : IOException("The saved rendition is unavailable.")

internal data class DownloadedRenditionDescriptor(
    val uri: String,
    val remoteUri: String?,
    val byteLength: Long,
    val sha256: String,
    val folderUri: String?,
) {
    companion object {
        fun parse(value: Any?, sourceUri: String): DownloadedRenditionDescriptor? {
            if (value == null) return null
            val values = value as? Map<*, *> ?: throw LocalDownloadUnavailable()
            val uri = values["uri"] as? String ?: throw LocalDownloadUnavailable()
            val remote = values["remoteUri"] as? String
            val size = values["byteLength"] as? Number ?: throw LocalDownloadUnavailable()
            val bytes = size.toLong()
            val digest = values["sha256"] as? String ?: throw LocalDownloadUnavailable()
            val folder = values["folderUri"] as? String
            if (uri != sourceUri || uri.length !in 1..32768 || (remote != null && remote.length !in 1..32768) ||
                (values.containsKey("remoteUri") && values["remoteUri"] != null && remote == null) ||
                (values.containsKey("folderUri") && values["folderUri"] != null && folder == null) ||
                bytes <= 0 || size.toDouble() != bytes.toDouble() ||
                !Regex("[0-9a-f]{64}").matches(digest) ||
                (folder != null && folder.length !in 1..32768)) throw LocalDownloadUnavailable()
            return DownloadedRenditionDescriptor(uri, remote, bytes, digest, folder)
        }
    }
}

/** One selection's proof. Hashing happens on the loader thread, once, from the same handle read later. */
internal class DownloadedRendition(
    private val context: Context,
    private val identity: PlaybackCacheIdentity,
    private val descriptor: DownloadedRenditionDescriptor,
) {
    private var verified: DownloadFileStamp? = null
    internal var verificationCount = 0
        private set

    fun source(admit: () -> Unit): DataSource = object : BaseDataSource(false) {
        private var opened: OpenDownload? = null
        private var position = 0L
        private var remaining = 0L

        override fun open(dataSpec: DataSpec): Long {
            admit()
            if (dataSpec.uri.toString() != descriptor.uri || dataSpec.httpMethod != DataSpec.HTTP_METHOD_GET ||
                dataSpec.position < 0 || dataSpec.position > descriptor.byteLength) throw LocalDownloadUnavailable()
            transferInitializing(dataSpec)
            val handle = openDownload(context, descriptor, identity.profileId, identity.contentId)
            try {
                synchronized(this@DownloadedRendition) {
                    val initial = handle.stamp()
                    if (handle.length != descriptor.byteLength) throw LocalDownloadUnavailable()
                    val previous = verified
                    if (previous == null) {
                        val digest = hashDownload(handle, admit)
                        if (digest != descriptor.sha256 || handle.stamp() != initial) throw LocalDownloadUnavailable()
                        verified = initial
                        verificationCount++
                    } else if (previous != initial) {
                        // A modified document/file is a new source, even if its name is unchanged.
                        throw LocalDownloadUnavailable()
                    }
                }
                admit()
                handle.checkCurrent()
                opened = handle
                position = dataSpec.position
                remaining = descriptor.byteLength - position
                if (dataSpec.length != C.LENGTH_UNSET.toLong()) remaining = minOf(remaining, dataSpec.length)
                transferStarted(dataSpec)
                return remaining
            } catch (error: Exception) {
                handle.close()
                throw error
            }
        }

        override fun read(buffer: ByteArray, offset: Int, length: Int): Int {
            admit()
            val handle = opened ?: throw LocalDownloadUnavailable()
            handle.checkCurrent()
            if (length == 0) return 0
            if (remaining == 0L) return C.RESULT_END_OF_INPUT
            val count = handle.read(buffer, offset, minOf(length.toLong(), remaining).toInt(), position)
            if (count <= 0) throw LocalDownloadUnavailable()
            handle.checkCurrent()
            position += count
            remaining -= count
            bytesTransferred(count)
            return count
        }

        override fun getUri(): Uri? = if (opened == null) null else Uri.parse(descriptor.uri)

        override fun close() {
            val previous = opened
            opened = null
            if (previous != null) {
                try { previous.close() } finally { transferEnded() }
            }
        }
    }
}

private data class DownloadFileStamp(
    val device: Long,
    val inode: Long,
    val size: Long,
    val modifiedSeconds: Long,
    val modifiedNanos: Long,
    val changedSeconds: Long,
    val changedNanos: Long,
    val offset: Long,
    val length: Long,
)

private fun stamp(stat: StructStat, offset: Long, length: Long): DownloadFileStamp {
    if (!OsConstants.S_ISREG(stat.st_mode) || stat.st_nlink <= 0) throw LocalDownloadUnavailable()
    return DownloadFileStamp(stat.st_dev, stat.st_ino, stat.st_size,
        stat.st_mtime, if (Build.VERSION.SDK_INT >= 27) stat.st_mtim.tv_nsec else 0,
        stat.st_ctime, if (Build.VERSION.SDK_INT >= 27) stat.st_ctim.tv_nsec else 0,
        offset, length)
}

private class OpenDownload(
    private val input: FileInputStream,
    val offset: Long,
    val length: Long,
    private val checkLocation: () -> Unit,
) {
    private val initial = stamp()

    fun stamp(): DownloadFileStamp = localStorage { stamp(Os.fstat(input.fd), offset, length) }

    fun checkCurrent() = localStorage {
        checkLocation()
        if (stamp() != initial) throw LocalDownloadUnavailable()
    }

    fun read(bytes: ByteArray, start: Int, count: Int, position: Long): Int = localStorage {
        input.channel.read(ByteBuffer.wrap(bytes, start, count), offset + position)
    }

    fun close() { try { input.close() } catch (_: IOException) {} }
}

private inline fun <T> localStorage(action: () -> T): T = try {
    action()
} catch (error: LocalDownloadUnavailable) {
    throw error
} catch (_: Exception) {
    // File/provider exceptions can contain local paths and account identifiers.
    throw LocalDownloadUnavailable()
}

private fun openDownload(context: Context, descriptor: DownloadedRenditionDescriptor,
                         profileId: String, contentId: String): OpenDownload = localStorage {
    val uri = Uri.parse(descriptor.uri)
    when (uri.scheme) {
        "file" -> {
            if (descriptor.folderUri != null || !Regex("[A-Za-z0-9_-]{1,128}").matches(profileId) ||
                !Regex("[A-Za-z0-9_-]{1,128}").matches(contentId) || !uri.authority.isNullOrEmpty() ||
                uri.query != null || uri.fragment != null) throw LocalDownloadUnavailable()
            val downloads = File(File(context.applicationInfo.dataDir).canonicalFile, "app_flutter/downloads")
            val owner = if (profileId == "default") downloads else File(downloads, "profiles/$profileId")
            val file = File(uri.path ?: throw LocalDownloadUnavailable()).canonicalFile
            if (owner.canonicalFile != owner.absoluteFile || file.parentFile?.canonicalFile != owner.canonicalFile ||
                file.name !in listOf("$contentId.webm", "$contentId.mp4", "$contentId.m4a", "$contentId.mp3", "$contentId.ogg") || !file.isFile)
                throw LocalDownloadUnavailable()
            val fd = ParcelFileDescriptor.open(file, ParcelFileDescriptor.MODE_READ_ONLY)
            val input = ParcelFileDescriptor.AutoCloseInputStream(fd)
            try {
                val original = Os.fstat(input.fd)
                OpenDownload(input, 0, original.st_size) {
                    val current = Os.stat(file.path)
                    if (current.st_dev != original.st_dev || current.st_ino != original.st_ino)
                        throw LocalDownloadUnavailable()
                }
            } catch (error: Exception) { input.close(); throw error }
        }
        "content" -> openDocument(context, uri, descriptor.folderUri ?: throw LocalDownloadUnavailable())
        else -> throw LocalDownloadUnavailable()
    }
}

private fun requireDocumentGrant(context: Context, uri: Uri, folderValue: String) {
    if (folderValue == SharedMusicDownload.COLLECTION) {
        if (SharedMusicDownload.pending(context, uri) != false) throw LocalDownloadUnavailable()
        return
    }
    val folder = Uri.parse(folderValue)
    if (uri.scheme != "content" || folder.scheme != "content" ||
        !DocumentsContract.isTreeUri(uri) || !DocumentsContract.isTreeUri(folder) ||
        !DocumentsContract.isDocumentUri(context, uri) || uri.authority != folder.authority ||
        DocumentsContract.getTreeDocumentId(uri) != DocumentsContract.getTreeDocumentId(folder))
        throw LocalDownloadUnavailable()
    val tree = DocumentsContract.buildTreeDocumentUri(folder.authority, DocumentsContract.getTreeDocumentId(folder))
    if (context.contentResolver.persistedUriPermissions.none { it.uri == tree && it.isReadPermission })
        throw LocalDownloadUnavailable()
}

private fun openDocument(context: Context, uri: Uri, folder: String): OpenDownload = localStorage {
    requireDocumentGrant(context, uri, folder)
    val asset = context.contentResolver.openAssetFileDescriptor(uri, "r") ?: throw LocalDownloadUnavailable()
    val input = try { asset.createInputStream() } catch (error: Exception) { asset.close(); throw error }
    try {
        val length = if (asset.declaredLength >= 0) asset.declaredLength else Os.fstat(input.fd).st_size - asset.startOffset
        if (asset.startOffset < 0 || length <= 0 || asset.startOffset > Long.MAX_VALUE - length)
            throw LocalDownloadUnavailable()
        OpenDownload(input, asset.startOffset, length) { requireDocumentGrant(context, uri, folder) }
    } catch (error: Exception) { input.close(); throw error }
}

private fun hashDownload(handle: OpenDownload, admit: () -> Unit): String {
    val digest = MessageDigest.getInstance("SHA-256")
    val buffer = ByteArray(64 * 1024)
    var position = 0L
    while (position < handle.length) {
        admit()
        if (Thread.currentThread().isInterrupted) throw LocalDownloadUnavailable()
        val count = handle.read(buffer, 0, minOf(buffer.size.toLong(), handle.length - position).toInt(), position)
        if (count <= 0) throw LocalDownloadUnavailable()
        digest.update(buffer, 0, count)
        position += count
    }
    handle.checkCurrent()
    return digest.digest().joinToString("") { "%02x".format(it) }
}

/** Completion proof for an owned document or shared music file. */
object DownloadDocumentIntegrity {
    @JvmStatic
    fun inspect(context: Context, uri: String, folderUri: String): Map<String, Any> {
        val handle = openDocument(context, Uri.parse(uri), folderUri)
        return try {
            val digest = hashDownload(handle) { }
            mapOf("byteLength" to handle.length, "sha256" to digest)
        } finally { handle.close() }
    }
}
