package org.vrpassthroughplayer.plugin

import java.io.File
import org.junit.Assert.*
import org.junit.Test

class AirplayMatroskaTest {
    private val config = byteArrayOf(0, 0, 1, 0x67, 0x42, 0, 0x1f, 0, 0, 1, 0x68, 1)
    private val key = byteArrayOf(0, 0, 1, 0x65, 1)
    private val predicted = byteArrayOf(0, 0, 1, 0x41, 2)
    private fun mux() = AirplayMatroska(1280, 720, 44100, 2, 1_000_000_000)

    @Test fun startsOnlyOnAKeyframeAndEmitsHeaderOnce() {
        val stream = mux()
        assertEquals(0, stream.video(predicted, config, 1_000_000_000).size)
        assertEquals(0, stream.audio(ByteArray(1764), 1_000_000_000).size)
        val first = stream.video(key, config, 1_000_000_000)
        assertArrayEquals(byteArrayOf(0x1a, 0x45, 0xdf.toByte(), 0xa3.toByte()), first.take(4).toByteArray())
        val next = stream.video(key, config, 1_040_000_000)
        assertArrayEquals(byteArrayOf(0x1f, 0x43, 0xb6.toByte(), 0x75), next.take(4).toByteArray())
    }

    @Test fun rotationCarriesFreshSpsAndPpsWithoutASecondSegment() {
        val stream = mux(); stream.video(key, config, 1_000_000_000)
        val changed = config.copyOf().also { it[6] = 0x2a }
        val packet = stream.video(key, changed, 1_040_000_000)
        val expected = byteArrayOf(0, 0, 0, 4, 0x67, 0x42, 0, 0x2a)
        assertTrue(packet.toList().windowed(expected.size).any { it == expected.toList() })
        assertFalse(packet.toString(Charsets.ISO_8859_1).contains("matroska"))
    }

    @Test fun silenceKeepsTheClockRunningAndLatePcmCannotReplayIt() {
        val stream = mux(); stream.video(key, config, 1_000_000_000)
        assertEquals(0, stream.silence(1_200_000_000).size)
        assertTrue(stream.silence(1_400_000_000).isNotEmpty())
        assertEquals(0, stream.audio(ByteArray(1764), 1_000_000_000).size)
        assertTrue(stream.audio(ByteArray(1764), 1_400_000_000).isNotEmpty())
    }

    @Test fun prerollAndOldAudioNeverProduceNegativeTimestamps() {
        val stream = mux()
        val first = stream.video(key, config, 950_000_000)
        assertTrue(first.isNotEmpty())
        assertEquals(0, stream.audio(ByteArray(1764), 900_000_000).size)
        assertTrue(stream.audio(ByteArray(1764), 1_000_000_000).isNotEmpty())
    }

    /** Host integration probe: AUD-delimited x264 fixtures -> production mux -> ffprobe/ffmpeg. */
    companion object {
        @JvmStatic fun main(args: Array<String>) {
            require(args.size >= 2)
            val stream = AirplayMatroska(640, 360, 44100, 2, 1_000_000_000)
            var ns = 1_000_000_000L
            File(args[0]).outputStream().use { out ->
                for ((part, input) in args.drop(1).withIndex()) {
                    val bytes = File(input).readBytes()
                    val spans = AirplayPackets.nals(bytes)
                    val config = spans.filter { (bytes[it.first].toInt() and 31) in 7..8 }
                        .take(2).fold(byteArrayOf()) { acc, span -> acc + byteArrayOf(0, 0, 0, 1) + bytes.copyOfRange(span.first, span.last + 1) }
                    var frame = byteArrayOf()
                    fun flush() {
                        if (frame.isEmpty()) return
                        out.write(stream.video(frame, config, ns))
                        if (part != 1) {
                            val pcm = java.nio.ByteBuffer.allocate(1764 * 4).order(java.nio.ByteOrder.LITTLE_ENDIAN)
                            repeat(1764) { sample ->
                                val time = (ns - 1_000_000_000) / 1e9 + sample / 44100.0
                                val value = (kotlin.math.sin(time * 440 * 2 * Math.PI) * 6000).toInt().toShort()
                                pcm.putShort(value); pcm.putShort(value)
                            }
                            out.write(stream.audio(pcm.array(), ns))
                        }
                        // Middle section deliberately omits sender audio (phone desktop).
                        out.write(stream.silence(ns + 240_000_000))
                        ns += 40_000_000; frame = byteArrayOf()
                    }
                    for (span in spans) {
                        if (bytes[span.first].toInt() and 31 == 9) flush()
                        frame += byteArrayOf(0, 0, 0, 1) + bytes.copyOfRange(span.first, span.last + 1)
                    }
                    flush()
                }
            }
        }
    }
}
