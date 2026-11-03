package org.vrpassthroughplayer.plugin

import androidx.media3.container.NalUnitUtil
import java.io.ByteArrayOutputStream

/** Reassemble only the PMT-selected video PID; use the pinned Media3 H.264 SPS parser. */
internal object WebVideoTsDimensions {
    @androidx.annotation.OptIn(androidx.media3.common.util.UnstableApi::class)
    fun avc(data: ByteArray, pid: Int): Pair<Int, Int>? = runCatching {
        require(pid in 0..8190)
        val elementary = ByteArrayOutputStream()
        var continuity = -1
        for (p in 0 until minOf(data.size - 187, 512 * 1024) step 188) {
            require(data[p] == 0x47.toByte())
            if (((data[p + 1].toInt() and 31) shl 8 or (data[p + 2].toInt() and 255)) != pid) continue
            require(data[p + 1].toInt() and 0x80 == 0 && data[p + 3].toInt() and 0xc0 == 0)
            val control = (data[p + 3].toInt() ushr 4) and 3
            require(control != 0)
            if (control == 2) continue
            val next = data[p + 3].toInt() and 15
            if (continuity == next) continue // retransmission
            if (continuity >= 0) require(next == (continuity + 1) % 16)
            continuity = next
            var start = p + 4 + if (control == 3) (data[p + 4].toInt() and 255) + 1 else 0
            require(start <= p + 188)
            if (data[p + 1].toInt() and 0x40 != 0) {
                require(start + 9 <= p + 188 && data[start] == 0.toByte() && data[start + 1] == 0.toByte() && data[start + 2] == 1.toByte())
                start += 9 + (data[start + 8].toInt() and 255)
                require(start <= p + 188)
            }
            elementary.write(data, start, p + 188 - start)
        }
        val bytes = elementary.toByteArray()
        val starts = ArrayList<Pair<Int, Int>>()
        var i = 0
        while (i + 3 < bytes.size) {
            val n = if (bytes[i] == 0.toByte() && bytes[i + 1] == 0.toByte()) {
                if (bytes[i + 2] == 1.toByte()) 3
                else if (bytes[i + 2] == 0.toByte() && bytes[i + 3] == 1.toByte()) 4 else 0
            } else 0
            if (n > 0) { starts.add(i to i + n); i += n } else i++
        }
        for (index in starts.indices) {
            val begin = starts[index].second
            val end = starts.getOrNull(index + 1)?.first ?: bytes.size
            if (begin >= end || bytes[begin].toInt() and 31 != 7) continue
            val sps = NalUnitUtil.parseSpsNalUnit(bytes, begin, end)
            if (sps.width in 1..16384 && sps.height in 1..16384) return@runCatching sps.width to sps.height
        }
        null
    }.getOrNull()
}
