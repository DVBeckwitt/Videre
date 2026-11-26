package com.github.dvbeckwitt.videre

import java.nio.ByteBuffer
import java.nio.ByteOrder
import org.junit.Assert.assertArrayEquals
import org.junit.Assert.assertNull
import org.junit.Test

class WaveformPeaksTest {
    @Test
    fun quietAndLoudSectionsRetainTheirActualRatioAcrossBuffers() {
        val peaks = WaveformPeaks(startUs = 0, endUs = 20_000, binCount = 4)
        val quiet = ShortArray(80) { if (it % 2 == 0) -4096 else 4096 }
        val loud = ShortArray(80) { if (it % 2 == 0) -24576 else 24576 }
        peaks.add(pcm16(quiet), presentationTimeUs = 0, sampleRate = 8000, channels = 1, floatPcm = false)
        peaks.add(pcm16(loud), presentationTimeUs = 10_000, sampleRate = 8000, channels = 1, floatPcm = false)

        assertArrayEquals(doubleArrayOf(0.125, 0.125, 0.75, 0.75),
            peaks.result()!!.toDoubleArray(), 0.0001)
    }

    @Test
    fun clipUsesItsOwnTimelineAndTheLoudestChannel() {
        val peaks = WaveformPeaks(startUs = 10_000, endUs = 30_000, binCount = 2)
        val pcm = ByteBuffer.allocate(8 * Float.SIZE_BYTES).order(ByteOrder.nativeOrder())
        pcm.putFloat(0f).putFloat(1f) // Before the clip.
        pcm.putFloat(0.125f).putFloat(-0.25f)
        pcm.putFloat(-0.75f).putFloat(0.5f)
        pcm.putFloat(1f).putFloat(0f) // At the clip's exclusive end.
        pcm.flip()

        peaks.add(pcm, presentationTimeUs = 0, sampleRate = 100, channels = 2, floatPcm = true)

        assertArrayEquals(doubleArrayOf(0.25, 0.75), peaks.result()!!.toDoubleArray(), 0.0001)
    }

    @Test
    fun distinguishesSilenceFromNoDecodedSampleInTheWindow() {
        val peaks = WaveformPeaks(startUs = 0, endUs = 1_000, binCount = 1)
        peaks.add(pcm16(shortArrayOf(0)), presentationTimeUs = 1_000, sampleRate = 8000, channels = 1,
            floatPcm = false)
        assertNull(peaks.result())

        peaks.add(pcm16(shortArrayOf(0)), presentationTimeUs = 0, sampleRate = 8000, channels = 1, floatPcm = false)
        assertArrayEquals(doubleArrayOf(0.0), peaks.result()!!.toDoubleArray(), 0.0001)
    }

    private fun pcm16(samples: ShortArray): ByteBuffer {
        val pcm = ByteBuffer.allocate(samples.size * Short.SIZE_BYTES).order(ByteOrder.nativeOrder())
        pcm.asShortBuffer().put(samples)
        return pcm
    }
}
