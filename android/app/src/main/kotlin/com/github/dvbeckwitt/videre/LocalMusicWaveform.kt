package com.github.dvbeckwitt.videre

import android.content.Context
import android.content.res.AssetFileDescriptor
import android.media.AudioFormat
import android.media.MediaCodec
import android.media.MediaExtractor
import android.media.MediaFormat
import android.net.Uri
import android.os.Build
import android.os.ParcelFileDescriptor
import android.os.SystemClock
import android.provider.DocumentsContract
import android.system.Os
import android.system.OsConstants
import android.system.StructStat
import java.io.File
import java.io.FileDescriptor

/** Only local handles reach the extractor. It cannot follow a URL or a media manifest. */
internal class LocalMusicWaveform(private val context: Context) {
    fun revision(uri: Uri, cancellation: WaveformCancellation): String? =
        withAudio(uri, cancellation) { source -> source.revision() }

    fun extract(
        uri: Uri,
        binCount: Int,
        startUs: Long,
        endUs: Long?,
        expectedRevision: String?,
        cancellation: WaveformCancellation,
    ): List<Double>? = withAudio(uri, cancellation) { source ->
        val revision = source.revision(allowCoarse = expectedRevision == null)
            ?: return@withAudio null
        if (expectedRevision != null && revision != expectedRevision) return@withAudio null
        val peaks = decode(source, cancellation, startUs, endUs, binCount) ?: return@withAudio null
        cancellation.check()
        peaks.takeIf { source.revision(allowCoarse = true) == revision }
    }

    private fun <T> withAudio(
        uri: Uri,
        cancellation: WaveformCancellation,
        action: (AudioFile) -> T?,
    ): T? {
        if (!uri.isHierarchical || uri.query != null || uri.fragment != null) return null
        cancellation.check()
        val descriptor = when (uri.scheme) {
            "file" -> openPrivateDownload(uri)
            "content" -> if (admittedContent(uri)) {
                cancellation.check()
                context.contentResolver.openAssetFileDescriptor(uri, "r", cancellation.providerSignal)
            } else null
            else -> null
        } ?: return null
        return descriptor.use { asset ->
            cancellation.check()
            val stat = Os.fstat(asset.fileDescriptor)
            if (!stat.isRegularAudioFile()) return@use null
            val offset = asset.startOffset
            if (offset < 0 || offset >= stat.st_size) return@use null
            val available = stat.st_size - offset
            val length = asset.declaredLength.takeUnless { it == AssetFileDescriptor.UNKNOWN_LENGTH }
                ?: available
            if (length !in 1..available) return@use null
            action(AudioFile(asset.fileDescriptor, offset, length))
        }
    }

    private fun openPrivateDownload(uri: Uri): AssetFileDescriptor? {
        if (!uri.authority.isNullOrEmpty()) return null
        val path = uri.path?.takeIf { File(it).isAbsolute } ?: return null
        val file = File(path).canonicalFile
        val root = File(File(context.applicationInfo.dataDir).canonicalFile, "app_flutter/downloads")
        if (!file.path.startsWith(root.path + File.separator) || !file.isFile) return null
        val descriptor = ParcelFileDescriptor.open(file, ParcelFileDescriptor.MODE_READ_ONLY)
        return AssetFileDescriptor(descriptor, 0, AssetFileDescriptor.UNKNOWN_LENGTH)
    }

    private fun admittedContent(uri: Uri): Boolean {
        val authority = uri.authority ?: return false
        if (MEDIA_ROW.matches(uri.toString())) return true
        if (!DocumentsContract.isTreeUri(uri) || !DocumentsContract.isDocumentUri(context, uri)) {
            return false
        }
        val tree = DocumentsContract.buildTreeDocumentUri(
            authority, DocumentsContract.getTreeDocumentId(uri),
        )
        return context.contentResolver.persistedUriPermissions.any {
            it.isReadPermission && it.uri == tree
        }
    }

    private fun decode(
        source: AudioFile,
        cancellation: WaveformCancellation,
        startUs: Long,
        requestedEndUs: Long?,
        binCount: Int,
    ): List<Double>? {
        val extractor = MediaExtractor()
        try {
            extractor.setDataSource(source.descriptor, source.offset, source.length)
            cancellation.check()
            val audioTracks = (0 until extractor.trackCount).filter {
                extractor.getTrackFormat(it).getString(MediaFormat.KEY_MIME)?.startsWith("audio/") == true
            }
            // Without a playback track selection, multiple audio streams are ambiguous.
            val audioTrack = audioTracks.singleOrNull() ?: return null
            val format = extractor.getTrackFormat(audioTrack)
            val mimeType = format.getString(MediaFormat.KEY_MIME) ?: return null
            val durationUs = if (format.containsKey(MediaFormat.KEY_DURATION)) {
                format.getLong(MediaFormat.KEY_DURATION).takeIf { it > 0 }
            } else null
            val endUs = when {
                durationUs == null -> requestedEndUs
                requestedEndUs == null -> durationUs
                else -> minOf(requestedEndUs, durationUs)
            }
            if (endUs == null || endUs <= startUs) return null

            extractor.selectTrack(audioTrack)
            if (startUs > 0) extractor.seekTo(startUs, MediaExtractor.SEEK_TO_PREVIOUS_SYNC)
            val codec = MediaCodec.createDecoderByType(mimeType)
            try {
                codec.configure(format, null, null, 0)
                codec.start()
                return decodePcm(extractor, codec, cancellation, startUs, endUs, binCount)
            } finally {
                codec.release()
            }
        } finally {
            extractor.release()
        }
    }

    private fun decodePcm(
        extractor: MediaExtractor,
        codec: MediaCodec,
        cancellation: WaveformCancellation,
        startUs: Long,
        endUs: Long,
        binCount: Int,
    ): List<Double>? {
        val peaks = WaveformPeaks(startUs, endUs, binCount)
        val info = MediaCodec.BufferInfo()
        var pcmFormat: PcmFormat? = null
        var inputEnded = false
        var lastProgress = SystemClock.elapsedRealtime()
        while (SystemClock.elapsedRealtime() - lastProgress < DECODER_STALL_MS) {
            cancellation.check()
            if (!inputEnded) {
                val input = codec.dequeueInputBuffer(0)
                if (input >= 0) {
                    val buffer = codec.getInputBuffer(input) ?: return null
                    val size = extractor.readSampleData(buffer, 0)
                    if (size < 0) {
                        codec.queueInputBuffer(input, 0, 0, 0, MediaCodec.BUFFER_FLAG_END_OF_STREAM)
                        inputEnded = true
                    } else {
                        if (extractor.sampleFlags and MediaExtractor.SAMPLE_FLAG_ENCRYPTED != 0) return null
                        codec.queueInputBuffer(input, 0, size, extractor.sampleTime, 0)
                        extractor.advance()
                    }
                    lastProgress = SystemClock.elapsedRealtime()
                }
            }

            val output = codec.dequeueOutputBuffer(info, DEQUEUE_WAIT_US)
            if (output == MediaCodec.INFO_OUTPUT_FORMAT_CHANGED) {
                pcmFormat = PcmFormat.parse(codec.outputFormat) ?: return null
                lastProgress = SystemClock.elapsedRealtime()
            }
            if (output < 0) continue
            try {
                if (info.size > 0 && info.flags and MediaCodec.BUFFER_FLAG_CODEC_CONFIG == 0) {
                    if (info.presentationTimeUs >= endUs) return peaks.result()
                    val pcm = pcmFormat ?: PcmFormat.parse(codec.getOutputFormat(output))
                        ?: return null
                    pcmFormat = pcm
                    val buffer = codec.getOutputBuffer(output) ?: return null
                    peaks.add(buffer, info.presentationTimeUs, pcm.sampleRate, pcm.channels, pcm.floatPcm)
                }
                if (info.flags and MediaCodec.BUFFER_FLAG_END_OF_STREAM != 0) return peaks.result()
            } finally {
                codec.releaseOutputBuffer(output, false)
            }
            lastProgress = SystemClock.elapsedRealtime()
        }
        return null
    }

    private data class AudioFile(val descriptor: FileDescriptor, val offset: Long, val length: Long) {
        fun revision(allowCoarse: Boolean = false): String? {
            val stat = Os.fstat(descriptor)
            if (!stat.isRegularAudioFile()) return null
            // API 24–26 can detect some changes during decoding. Their
            // second-precision timestamps cannot safely key the cache.
            val nanos = Build.VERSION.SDK_INT >= Build.VERSION_CODES.O_MR1
            if (!nanos && !allowCoarse) return null
            val modifiedNanos = if (nanos) stat.st_mtim.tv_nsec else 0
            val changedNanos = if (nanos) stat.st_ctim.tv_nsec else 0
            return listOf(stat.st_dev, stat.st_ino, stat.st_size, stat.st_mtime, modifiedNanos,
                stat.st_ctime, changedNanos, offset, length).joinToString("/")
        }
    }

    private data class PcmFormat(val sampleRate: Int, val channels: Int, val floatPcm: Boolean) {
        companion object {
            fun parse(format: MediaFormat): PcmFormat? {
                val rate = format.getInteger(MediaFormat.KEY_SAMPLE_RATE)
                val channels = format.getInteger(MediaFormat.KEY_CHANNEL_COUNT)
                if (rate <= 0 || channels !in 1..32) return null
                val encoding = if (format.containsKey(MediaFormat.KEY_PCM_ENCODING)) {
                    format.getInteger(MediaFormat.KEY_PCM_ENCODING)
                } else AudioFormat.ENCODING_PCM_16BIT
                if (encoding != AudioFormat.ENCODING_PCM_16BIT &&
                    encoding != AudioFormat.ENCODING_PCM_FLOAT) return null
                return PcmFormat(rate, channels, encoding == AudioFormat.ENCODING_PCM_FLOAT)
            }
        }
    }

    private companion object {
        val MEDIA_ROW = Regex("content://media/[A-Za-z0-9_-]+/audio/media/[1-9][0-9]*")
        const val DEQUEUE_WAIT_US = 10_000L
        const val DECODER_STALL_MS = 3_000L
    }
}

private fun StructStat.isRegularAudioFile() =
    OsConstants.S_ISREG(st_mode) && st_ino != 0L && st_nlink > 0
