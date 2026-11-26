package com.ryanheise.just_audio;

import static org.junit.Assert.assertEquals;
import static org.junit.Assert.assertFalse;

import androidx.media3.common.audio.AudioProcessor;
import java.nio.ByteBuffer;
import java.nio.ByteOrder;
import org.junit.Test;

public class MusicGainProcessorTest {
    @Test
    public void sharedEmptyInputAtUnityGainDoesNotBlockPlayback() {
        MusicGainProcessor processor = new MusicGainProcessor(1.0);
        processor.queueInput(AudioProcessor.EMPTY_BUFFER);
        assertFalse(processor.getOutput().hasRemaining());

        ByteBuffer input = ByteBuffer.allocateDirect(Short.BYTES).order(ByteOrder.nativeOrder());
        input.putShort((short) 12000).flip();
        processor.queueInput(input);
        assertFalse(input.hasRemaining());
        ByteBuffer output = processor.getOutput();
        assertEquals(12000, output.getShort());
        assertFalse(output.hasRemaining());
    }
}
