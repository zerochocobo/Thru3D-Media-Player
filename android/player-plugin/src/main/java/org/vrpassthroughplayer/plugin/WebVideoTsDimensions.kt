package org.vrpassthroughplayer.plugin

import androidx.media3.container.NalUnitUtil
import java.io.ByteArrayOutputStream

/** Reassemble only the PMT-selected video PID; reuse the pinned Media3 SPS parsers. */
internal object WebVideoTsDimensions {
    fun avc(data: ByteArray, pid: Int): Pair<Int, Int>? = dimensions(data,pid,false)
    fun hevc(data: ByteArray, pid: Int): Pair<Int, Int>? = dimensions(data,pid,true)

    @androidx.annotation.OptIn(androidx.media3.common.util.UnstableApi::class)
    private fun dimensions(data: ByteArray, pid: Int, hevc: Boolean): Pair<Int, Int>? = runCatching {
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
            if (begin >= end) continue
            val size = if(hevc) {
                if(begin+1>=end || (bytes[begin].toInt() ushr 1) and 63 != 33) continue
                // Inspect the base-layer SPS only, with a valid HEVC NAL header.
                if(bytes[begin].toInt() and 0x81 != 0 || bytes[begin+1].toInt() and 0xf8 != 0 || bytes[begin+1].toInt() and 7 == 0) continue
                val sps=NalUnitUtil.parseH265SpsNalUnit(bytes,begin,end,null)
                sps.width to sps.height
            } else {
                if(bytes[begin].toInt() and 31 != 7) continue
                val sps=NalUnitUtil.parseSpsNalUnit(bytes,begin,end)
                sps.width to sps.height
            }
            if (size.first in 1..16384 && size.second in 1..16384) return@runCatching size
        }
        null
    }.getOrNull()
}
