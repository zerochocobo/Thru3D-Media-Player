package org.vrpassthroughplayer.plugin

import java.io.ByteArrayOutputStream
import java.nio.ByteBuffer

/** Streaming Matroska with the received H.264 access units and decoded PCM on one clock. */
internal class AirplayMatroska(private val width: Int, private val height: Int,
                              private val rate: Int, private val channels: Int, private val originNs: Long) {
    private var started = false
    private var audioEndNs = originNs

    init { require(width > 0 && height > 0 && rate in 8000..96000 && channels in 1..2 && originNs > 0) }

    fun video(data: ByteArray, config: ByteArray, ns: Long): ByteArray {
        val units = AirplayPackets.nals(data)
        val key = units.any { data[it.first].toInt() and 31 == 5 }
        if (!started && !key) return byteArrayOf()
        val out = ByteArrayOutputStream()
        if (!started) { out.write(header(config)); started = true }
        // Include current parameter sets at every keyframe, including phone rotation.
        val packet = ByteArrayOutputStream()
        if (key) avcc(packet, config)
        avcc(packet, data)
        out.write(block(1, packet.toByteArray(), ns, key))
        return out.toByteArray()
    }

    fun audio(data: ByteArray, ns: Long): ByteArray {
        if (!started || data.isEmpty()) return byteArrayOf()
        val frameBytes = channels * 2
        require(data.size % frameBytes == 0)
        // Late audio after a silent interval must not replay already presented time.
        val skip = (((audioEndNs - ns).coerceAtLeast(0) * rate + 999_999_999) / 1_000_000_000)
            .coerceAtMost((data.size / frameBytes).toLong()).toInt()
        if (skip * frameBytes >= data.size) return byteArrayOf()
        val start = ns + skip.toLong() * 1_000_000_000 / rate
        audioEndNs = ns + (data.size / frameBytes).toLong() * 1_000_000_000 / rate
        return block(2, if (skip == 0) data else data.copyOfRange(skip * frameBytes, data.size), start, true)
    }

    /** Phone UI often sends no audio. Keep MPV's audio clock alive after a small jitter allowance. */
    fun silence(liveNs: Long): ByteArray {
        if (!started) return byteArrayOf()
        val out = ByteArrayOutputStream()
        val samples = rate / 50 // 20 ms, bounded writes even after a scheduling stall.
        repeat(10) {
            if (audioEndNs + 220_000_000 > liveNs) return out.toByteArray()
            out.write(audio(ByteArray(samples * channels * 2), audioEndNs))
        }
        return out.toByteArray()
    }

    private fun header(config: ByteArray): ByteArray {
        val units = AirplayPackets.nals(config)
        val sps = units.first { config[it.first].toInt() and 31 == 7 }.let { config.copyOfRange(it.first, it.last + 1) }
        val pps = units.first { config[it.first].toInt() and 31 == 8 }.let { config.copyOfRange(it.first, it.last + 1) }
        require(sps.size >= 4 && sps.size <= 65535 && pps.size <= 65535)
        val privateData = byteArrayOf(1, sps[1], sps[2], sps[3], -1, -31) + short(sps.size) + sps + byteArrayOf(1) + short(pps.size) + pps
        val ebml = element(0x1a45dfa3, uint(0x4286, 1) + uint(0x42f7, 1) + uint(0x42f2, 4) + uint(0x42f3, 8) +
            string(0x4282, "matroska") + uint(0x4287, 4) + uint(0x4285, 2))
        val info = element(0x1549a966, uint(0x2ad7b1, 1_000_000) + string(0x4d80, "Thru3D") + string(0x5741, "Thru3D"))
        val video = element(0xae, uint(0xd7, 1) + uint(0x73c5, 1) + uint(0x83, 1) + uint(0x9c, 0) +
            string(0x86, "V_MPEG4/ISO/AVC") + element(0x63a2, privateData) + element(0xe0, uint(0xb0, width.toLong()) + uint(0xba, height.toLong())))
        val audio = element(0xae, uint(0xd7, 2) + uint(0x73c5, 2) + uint(0x83, 2) + uint(0x9c, 0) + string(0x86, "A_PCM/INT/LIT") +
            element(0xe1, element(0xb5, ByteBuffer.allocate(8).putDouble(rate.toDouble()).array()) + uint(0x9f, channels.toLong()) + uint(0x6264, 16)))
        return ebml + id(0x18538067) + byteArrayOf(1, -1, -1, -1, -1, -1, -1, -1) + info + element(0x1654ae6b, video + audio)
    }

    private fun block(track: Int, data: ByteArray, ns: Long, key: Boolean): ByteArray =
        element(0x1f43b675, uint(0xe7, ((ns - originNs) / 1_000_000).coerceAtLeast(0)) +
            element(0xa3, byteArrayOf((0x80 or track).toByte(), 0, 0, if (key) -128 else 0) + data))

    private fun avcc(out: ByteArrayOutputStream, bytes: ByteArray) {
        for (span in AirplayPackets.nals(bytes)) {
            out.write(ByteBuffer.allocate(4).putInt(span.last - span.first + 1).array())
            out.write(bytes, span.first, span.last - span.first + 1)
        }
    }

    private fun short(value: Int) = byteArrayOf((value ushr 8).toByte(), value.toByte())
    private fun id(value: Int): ByteArray = ByteBuffer.allocate(4).putInt(value).array().dropWhile { it == 0.toByte() }.toByteArray()
    private fun uint(tag: Int, value: Long): ByteArray {
        val bytes = ByteBuffer.allocate(8).putLong(value).array().dropWhile { it == 0.toByte() }.toByteArray()
        return element(tag, if (bytes.isEmpty()) byteArrayOf(0) else bytes)
    }
    private fun string(tag: Int, value: String) = element(tag, value.toByteArray(Charsets.UTF_8))
    private fun element(tag: Int, payload: ByteArray): ByteArray {
        var count = 1
        while (payload.size.toLong() >= (1L shl (7 * count)) - 1) count++
        var size = payload.size.toLong() or (1L shl (7 * count))
        val prefix = ByteArray(count)
        for (index in count - 1 downTo 0) { prefix[index] = size.toByte(); size = size ushr 8 }
        return id(tag) + prefix + payload
    }
}
