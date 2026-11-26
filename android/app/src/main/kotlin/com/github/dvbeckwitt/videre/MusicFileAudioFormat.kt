package com.github.dvbeckwitt.videre

import android.content.ContentResolver
import android.content.Context
import android.content.res.AssetFileDescriptor
import android.media.MediaExtractor
import android.media.MediaFormat
import android.media.MediaMetadataRetriever
import android.net.Uri
import java.io.FileDescriptor
import java.io.IOException

internal object MusicFileAudioFormat {
    /** Reads format metadata for a local file the caller has already authorized. */
    fun read(context: Context, uri: Uri): Map<String, Any?> {
        if (uri.scheme != ContentResolver.SCHEME_CONTENT && uri.scheme != ContentResolver.SCHEME_FILE) {
            return emptyMap()
        }
        return try {
            context.contentResolver.openAssetFileDescriptor(uri, "r")?.use { file ->
                read(file.fileDescriptor, file.startOffset, file.declaredLength)
            }.orEmpty()
        } catch (_: IOException) {
            emptyMap()
        } catch (_: RuntimeException) {
            // The file can be missing, unreadable, or unsupported by the extractor.
            emptyMap()
        }
    }

    /** Reads within an authorized file region. The caller owns the descriptor. */
    fun read(fileDescriptor: FileDescriptor, offset: Long, length: Long): Map<String, Any?> = try {
        val extractor = MediaExtractor()
        try {
            if (length == AssetFileDescriptor.UNKNOWN_LENGTH) {
                extractor.setDataSource(fileDescriptor)
            } else {
                extractor.setDataSource(fileDescriptor, offset, length)
            }
            val trackCount = extractor.trackCount
            buildMap {
                for (index in 0 until trackCount) {
                    val format = extractor.getTrackFormat(index)
                    val mime = format.getString(MediaFormat.KEY_MIME) ?: continue
                    if (!mime.startsWith("audio/")) continue
                    val sampleRate = format.positiveInteger(MediaFormat.KEY_SAMPLE_RATE)
                    // The retriever's bitrate is for the whole file. It is only a
                    // fallback when the extractor found a single track and it is audio.
                    val bitrate = format.positiveInteger(MediaFormat.KEY_BIT_RATE)
                        ?: if (trackCount == 1) readAverageBitrate(fileDescriptor, offset, length) else null
                    put("codecMimeType", mime)
                    if (bitrate != null) put("bitrateBps", bitrate)
                    if (sampleRate != null) put("sampleRateHz", sampleRate)
                    break
                }
            }
        } finally {
            extractor.release()
        }
    } catch (_: IOException) {
        emptyMap()
    } catch (_: RuntimeException) {
        emptyMap()
    }

    private fun MediaFormat.positiveInteger(key: String): Int? = try {
        if (containsKey(key)) getInteger(key).takeIf { it > 0 } else null
    } catch (_: ClassCastException) {
        null
    }

    private fun readAverageBitrate(fileDescriptor: FileDescriptor, offset: Long, length: Long): Int? {
        val retriever = MediaMetadataRetriever()
        return try {
            if (length == AssetFileDescriptor.UNKNOWN_LENGTH) {
                retriever.setDataSource(fileDescriptor)
            } else {
                retriever.setDataSource(fileDescriptor, offset, length)
            }
            retriever.extractMetadata(MediaMetadataRetriever.METADATA_KEY_BITRATE)
                ?.toIntOrNull()?.takeIf { it > 0 }
        } catch (_: RuntimeException) {
            null
        } finally {
            try { retriever.release() } catch (_: IOException) { }
        }
    }
}
