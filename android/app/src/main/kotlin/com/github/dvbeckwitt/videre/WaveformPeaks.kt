package com.github.dvbeckwitt.videre

import java.nio.ByteBuffer
import java.nio.ByteOrder
import kotlin.math.abs

/** The largest absolute sample across all channels in each equal time interval. */
internal class WaveformPeaks(private val startUs: Long, endUs: Long, binCount: Int) {
    private val durationUs = (endUs - startUs).toDouble()
    private val binsPerMicrosecond = binCount / durationUs
    private val peaks = DoubleArray(binCount)
    private var hasFrames = false

    fun add(
        buffer: ByteBuffer,
        presentationTimeUs: Long,
        sampleRate: Int,
        channels: Int,
        floatPcm: Boolean,
    ) {
        val pcm = buffer.order(ByteOrder.nativeOrder())
        if (floatPcm) {
            val samples = pcm.asFloatBuffer()
            collect(samples.remaining(), presentationTimeUs, sampleRate, channels) {
                samples.get().toDouble().takeIf(Double::isFinite) ?: 0.0
            }
        } else {
            val samples = pcm.asShortBuffer()
            collect(samples.remaining(), presentationTimeUs, sampleRate, channels) {
                samples.get() / 32768.0
            }
        }
    }

    private inline fun collect(
        sampleCount: Int,
        presentationTimeUs: Long,
        sampleRate: Int,
        channels: Int,
        sample: () -> Double,
    ) {
        val offsetUs = presentationTimeUs.toDouble() - startUs
        val frameDurationUs = 1_000_000.0 / sampleRate
        for (frame in 0 until sampleCount / channels) {
            val timeUs = offsetUs + frame * frameDurationUs
            if (timeUs >= durationUs) break
            var peak = 0.0
            repeat(channels) { peak = maxOf(peak, abs(sample())) }
            if (timeUs < 0) continue
            val bin = (timeUs * binsPerMicrosecond).toInt().coerceAtMost(peaks.lastIndex)
            peaks[bin] = maxOf(peaks[bin], peak.coerceAtMost(1.0))
            hasFrames = true
        }
    }

    fun result(): List<Double>? = if (hasFrames) peaks.toList() else null
}
