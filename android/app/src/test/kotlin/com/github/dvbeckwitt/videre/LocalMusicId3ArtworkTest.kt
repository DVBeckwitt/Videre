package com.github.dvbeckwitt.videre

import java.util.Base64
import org.junit.Assert.assertArrayEquals
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertThrows
import org.junit.Assert.assertTrue
import org.junit.Test

class LocalMusicId3ArtworkTest {
    @Test
    fun appliesPositionAndFrontCoverChangesTogetherWithinTheOriginalTag() {
        for (version in 3..4) {
            val other = otherFrames(version)
            val positions = frame(version, "TRCK", byteArrayOf(0) + ascii("2/10"))
            val front = picture(version, 3, "image/png", png, "Front")
            val input = tag(version, 512, other + listOf(positions, front))
            val before = input.copyOf()
            val output = LocalMusicId3.edit(
                input,
                mapOf("trackNumber" to "7", "discNumber" to "2"),
                LocalMusicId3.ArtworkEdit(jpeg),
            )

            assertArrayEquals(before, input)
            assertEquals(input.size, output.size)
            val values = LocalMusicId3.inspect(output)
            assertEquals("7", values["trackNumber"])
            assertEquals("10", values["trackTotal"])
            assertEquals("2", values["discNumber"])
            val frames = frames(output, version)
            val newFront = frames.single(::isFront)
            assertArrayEquals(jpeg, newFront.copyOfRange(newFront.size - jpeg.size, newFront.size))
            val unrelated = frames.filterNot { isFront(it) || id(it) in listOf("TRCK", "TPOS") }
            assertArrayEquals(other.flatBytes(), unrelated.flatBytes())
        }
    }

    @Test
    fun replacesFrontArtworkAndPreservesOtherFramesAndAudioInBothVersions() {
        for (version in 3..4) {
            val otherFrames = otherFrames(version)
            val oldFront = if (version == 3) picture(version, 3, "image/png", png, "Original front")
                else picture(version, 3, "image/jpeg", jpeg, "Original front")
            val input = tag(version, 512, otherFrames + listOf(oldFront))
            val before = input.copyOf()
            val replacement = if (version == 3) jpeg else png
            val mime = if (version == 3) "image/jpeg" else "image/png"

            assertTrue(LocalMusicId3.artworkState(input).hasFrontCover)
            val output = LocalMusicId3.edit(input, emptyMap(), LocalMusicId3.ArtworkEdit(replacement))

            assertArrayEquals(before, input)
            assertPreserved(input, output, otherFrames, version)
            assertTrue(LocalMusicId3.artworkState(output).editable)
            assertTrue(LocalMusicId3.artworkState(output).hasFrontCover)
            val newFront = frames(output, version).first { id(it) == "APIC" }
            assertTrue(isFront(newFront))
            val mimeEnd = newFront.indexOfMimeEnd()
            assertEquals(mime, String(newFront, 11, mimeEnd - 11, Charsets.US_ASCII))
            val descriptionStart = mimeEnd + 2
            assertEquals("Original front", String(newFront, descriptionStart, 14, Charsets.ISO_8859_1))
            assertArrayEquals(replacement, newFront.copyOfRange(newFront.size - replacement.size, newFront.size))
        }
    }

    @Test
    fun removesOnlyFrontArtworkAndPreservesOtherFramesAndAudioInBothVersions() {
        for (version in 3..4) {
            val otherFrames = otherFrames(version)
            val front = picture(version, 3, "image/jpeg", jpeg, "Front")
            val input = tag(version, 0, otherFrames + listOf(front))

            assertTrue(LocalMusicId3.artworkState(input).removable)
            val output = LocalMusicId3.edit(input, emptyMap(), LocalMusicId3.ArtworkEdit(null))

            assertPreserved(input, output, otherFrames, version)
            assertTrue(LocalMusicId3.artworkState(output).editable)
            assertFalse(LocalMusicId3.artworkState(output).hasFrontCover)
            assertEquals(otherFrames.size, frames(output, version).size)
        }
    }

    @Test
    fun retainsAValidTagWhenTheFrontCoverIsItsOnlyFrame() {
        val version = 4
        val input = tag(version, 256, listOf(picture(version, 3, "image/png", png)))
        val state = LocalMusicId3.artworkState(input)
        assertTrue(state.hasFrontCover)
        assertFalse(state.removable)
        assertThrows(LocalMusicId3.Unsupported::class.java) {
            LocalMusicId3.edit(input, emptyMap(), LocalMusicId3.ArtworkEdit(null))
        }
    }

    @Test
    fun addsFrontCoverWithADistinctDescription() {
        val version = 4
        val existing = otherFrames(version) + listOf(picture(version, 6, "image/png", png, "Front cover"))
        val input = tag(version, 256, existing)
        assertFalse(LocalMusicId3.artworkState(input).hasFrontCover)
        val output = LocalMusicId3.edit(input, emptyMap(), LocalMusicId3.ArtworkEdit(png))
        assertPreserved(input, output, existing, version)
        val newFront = frames(output, version).first { id(it) == "APIC" }
        assertTrue(isFront(newFront))
        val descriptionStart = newFront.indexOfMimeEnd() + 2
        val descriptionEnd = newFront.size - png.size - 1
        assertEquals("Front cover 2", String(newFront, descriptionStart, descriptionEnd - descriptionStart))
    }

    @Test
    fun rejectsAmbiguousArtworkWithoutBlockingTextEdits() {
        val version = 4
        val otherFrames = otherFrames(version)
        val first = picture(version, 3, "image/png", png, "First")
        val second = picture(version, 3, "image/jpeg", jpeg, "Second")
        val readOnly = frame(version, "APIC", first.copyOfRange(10, first.size), status = 0x10)
        val linked = picture(version, 3, "-->", ascii("https://example.test/cover.png"), "Linked")
        val linkFrame = frame(version, "LINK", ascii("APIChttps://example.test/cover.png") + byteArrayOf(0))
        val missingDescriptionTerminator = frame(version, "APIC", byteArrayOf(0) +
            ascii("image/png") + byteArrayOf(0, 3) + ascii("Unterminated"))

        for (extra in listOf(listOf(first, second), listOf(readOnly), listOf(linked),
            listOf(linkFrame), listOf(missingDescriptionTerminator))) {
            val input = tag(version, 128, otherFrames + extra)
            val before = input.copyOf()

            assertFalse(LocalMusicId3.artworkState(input).editable)
            assertThrows(LocalMusicId3.Unsupported::class.java) {
                LocalMusicId3.edit(input, emptyMap(), LocalMusicId3.ArtworkEdit(null))
            }
            assertArrayEquals(before, input)
            val textEdit = LocalMusicId3.edit(input, mapOf("title" to "Edited"))
            assertEquals("Edited", LocalMusicId3.inspect(textEdit)["title"])
            val originalPictures = (otherFrames + extra).filter { id(it) in setOf("APIC", "LINK") }
            val unchangedPictures = frames(textEdit, version).filter { id(it) in setOf("APIC", "LINK") }
            assertArrayEquals(originalPictures.flatBytes(), unchangedPictures.flatBytes())
        }
    }

    @Test
    fun rejectsOversizedOrInvalidReplacementWithoutMutatingTheFixture() {
        val version = 4
        val input = tag(version, 0, otherFrames(version) + listOf(picture(version, 3, "image/png", png)))
        val before = input.copyOf()

        assertThrows(LocalMusicId3.NoSpace::class.java) {
            LocalMusicId3.edit(input, emptyMap(), LocalMusicId3.ArtworkEdit(jpeg))
        }
        assertThrows(LocalMusicId3.Unsupported::class.java) {
            LocalMusicId3.edit(input, emptyMap(), LocalMusicId3.ArtworkEdit(ascii("not an image")))
        }
        assertArrayEquals(before, input)
    }

    private fun assertPreserved(input: ByteArray, output: ByteArray, otherFrames: List<ByteArray>, version: Int) {
        assertEquals(input.size, output.size)
        assertArrayEquals(input.copyOf(10), output.copyOf(10))
        assertArrayEquals(otherFrames.flatBytes(), frames(output, version).filterNot(::isFront).flatBytes())
        val audioAndTrailingTag = silence + ascii("TAG") + ascii("Fixture ID3v1 title").copyOf(125)
        val file = input + audioAndTrailingTag
        val editedFile = file.copyOf().apply { output.copyInto(this) }
        assertArrayEquals(file.copyOfRange(input.size, file.size), editedFile.copyOfRange(input.size, editedFile.size))
    }

    private fun otherFrames(version: Int): List<ByteArray> = listOf(
        frame(version, "TIT2", byteArrayOf(0) + ascii("Fixture title")),
        picture(version, 4, "image/png", png, "Back"),
        frame(version, "COMM", byteArrayOf(0) + ascii("eng") + byteArrayOf(0) + ascii("Studio take")),
        frame(version, "TXXX", byteArrayOf(0) + ascii("REPLAYGAIN_TRACK_GAIN") + byteArrayOf(0) + ascii("-7.09 dB")),
        frame(version, "XABC", byteArrayOf(1, 0, 0x1a, 0x48)),
    )

    private fun frames(tag: ByteArray, version: Int): List<ByteArray> {
        val bits = if (version == 4) 7 else 8
        val frames = mutableListOf<ByteArray>()
        var start = 10
        while (start < tag.size && tag[start] != 0.toByte()) {
            val length = (start + 4 until start + 8).fold(0) { size, index ->
                (size shl bits) or (tag[index].toInt() and 0xff)
            }
            val end = start + 10 + length
            frames.add(tag.copyOfRange(start, end))
            start = end
        }
        return frames
    }

    private fun isFront(frame: ByteArray): Boolean =
        id(frame) == "APIC" && frame[frame.indexOfMimeEnd() + 1] == 3.toByte()

    private fun ByteArray.indexOfMimeEnd(): Int = (11 until size).first { this[it] == 0.toByte() }

    private fun id(frame: ByteArray): String = String(frame, 0, 4, Charsets.US_ASCII)

    private fun picture(version: Int, type: Int, mime: String, image: ByteArray, description: String = ""): ByteArray =
        frame(version, "APIC", byteArrayOf(0) + ascii(mime) + byteArrayOf(0, type.toByte()) +
            ascii(description) + byteArrayOf(0) + image)

    private fun frame(version: Int, id: String, data: ByteArray, status: Int = 0): ByteArray =
        ascii(id) + size(data.size, if (version == 4) 7 else 8) + byteArrayOf(status.toByte(), 0) + data

    private fun tag(version: Int, padding: Int, frames: List<ByteArray>): ByteArray {
        val body = frames.flatBytes() + ByteArray(padding)
        return ascii("ID3") + byteArrayOf(version.toByte(), 0, 0) + size(body.size, 7) + body
    }

    private fun size(value: Int, bits: Int): ByteArray =
        ByteArray(4) { ((value shr ((3 - it) * bits)) and ((1 shl bits) - 1)).toByte() }

    private fun List<ByteArray>.flatBytes(): ByteArray = fold(byteArrayOf(), ByteArray::plus)

    private fun ascii(value: String): ByteArray = value.toByteArray(Charsets.US_ASCII)

    // ffmpeg-generated 16×16 artwork and four MPEG Layer III frames of 8 kHz mono silence.
    private val png = Base64.getDecoder().decode(
        "iVBORw0KGgoAAAANSUhEUgAAABAAAAAQCAIAAACQkWg2AAAACXBIWXMAAAABAAAAAQBPJcTWAAAAFUlE" +
            "QVR4nGNgYPhHIhrVMKph2GoAAAvM/gFuVngMAAAAAElFTkSuQmCC",
    )
    private val jpeg = Base64.getDecoder().decode(
        "/9j/4AAQSkZJRgABAgAAAQABAAD//gAQTGF2YzYxLjIyLjEwMAD/2wBDAAgEBAQEBAUFBQUFBQYGBgYG" +
            "BgYGBgYGBgYHBwcICAgHBwcGBgcHCAgICAkJCQgICAgJCQoKCgwMCwsODg4RERT/xABMAAEBAAAAAAAA" +
            "AAAAAAAAAAAABgEBAQAAAAAAAAAAAAAAAAAABgcQAQAAAAAAAAAAAAAAAAAAAAARAQAAAAAAAAAAAAAA" +
            "AAAAAAD/wAARCAAQABADASIAAhEAAxEA/9oADAMBAAIRAxEAPwCLAFF/f//Z",
    )
    private val silence = Base64.getDecoder().decode(
        "/+MYxAAAAANIAAAAAExBTUUzLjEwMFVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVV" +
            "VVVVVVVVVVVVVVVV/+MYxDsAAANIAAAAAFVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVV" +
            "VVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVV/+MYxHYAAANIAAAAAFVVVVVVVVVVVVVVVVVVVVVVVVVVVVVV" +
            "VVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVV/+MYxLEAAANIAAAAAFVVVVVVVVVVVVVV" +
            "VVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVV",
    )
}
