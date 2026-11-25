package com.ryanheise.just_audio;

import androidx.media3.common.C;
import androidx.media3.common.audio.BaseAudioProcessor;
import java.nio.ByteBuffer;
import java.nio.ByteOrder;

/** A per-decoder gain stage before the player's volume and Android effects. */
final class MusicGainProcessor extends BaseAudioProcessor {
    private volatile double gain;

    MusicGainProcessor(double gain) {
        this.gain = gain;
    }

    static boolean isValidGain(double gain) {
        return gain >= 0 && gain <= 16;
    }

    void setGain(double gain) {
        this.gain = gain;
    }

    boolean requiresPcm() {
        return gain != 1.0;
    }

    @Override
    protected AudioFormat onConfigure(AudioFormat input) throws UnhandledAudioFormatException {
        if (input.encoding != C.ENCODING_PCM_16BIT) {
            throw new UnhandledAudioFormatException(input);
        }
        return input;
    }

    @Override
    public void queueInput(ByteBuffer input) {
        ByteBuffer output = replaceOutputBuffer(input.remaining());
        double factor = gain;
        if (factor == 1) {
            output.put(input);
        } else {
            input.order(ByteOrder.nativeOrder());
            while (input.hasRemaining()) {
                long sample = Math.round(input.getShort() * factor);
                output.putShort((short) Math.max(Short.MIN_VALUE, Math.min(Short.MAX_VALUE, sample)));
            }
        }
        output.flip();
    }
}
