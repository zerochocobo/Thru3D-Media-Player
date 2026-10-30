package org.vrpassthroughplayer.plugin

import java.nio.ByteBuffer
import kotlin.math.ceil
import kotlin.math.max
import kotlin.math.min

/** Coarse foreground observations. Base relief reuses low-frequency ROI readbacks; optional ZipDepth
 * alignment passes a current 64-grid Alpha. ROI coordinates always map back to source UV. */
internal object PortraitMask {
    data class Observation(val bounds: List<Double>, val subjects: Int, val cropped: Boolean)

    fun observe(planes: ByteBuffer, width: Int, height: Int, rect: FloatArray): Observation {
        require(width > 0 && height > 0 && planes.capacity() >= width * height)
        require(rect.size == 4 && rect.all { it.isFinite() } && rect[2] > 0 && rect[3] > 0)
        val step = max(1, ceil(max(width, height) / 64.0).toInt())
        val w = (width + step - 1) / step; val h = (height + step - 1) / step
        val occupied = BooleanArray(w * h)
        for (y in 0 until height) for (x in 0 until width) {
            val u = ((x + .5) / width - rect[0]) / rect[2]
            val v = ((y + .5) / height - rect[1]) / rect[3]
            if (u in 0.0..1.0 && v in 0.0..1.0 && (planes.get(y * width + x).toInt() and 255) >= 128)
                occupied[(y / step) * w + x / step] = true
        }
        val queue = IntArray(w * h)
        val blobs = ArrayList<IntArray>()
        for (start in occupied.indices) {
            if (!occupied[start]) continue
            var head = 0; var tail = 1; queue[0] = start; occupied[start] = false
            var x0 = w; var y0 = h; var x1 = 0; var y1 = 0
            while (head < tail) {
                val p = queue[head++]; val x = p % w; val y = p / w
                x0 = min(x0, x); x1 = max(x1, x); y0 = min(y0, y); y1 = max(y1, y)
                for (direction in 0..3) {
                    val q = when (direction) {
                        0 -> if (x > 0) p-1 else -1
                        1 -> if (x+1 < w) p+1 else -1
                        2 -> if (y > 0) p-w else -1
                        else -> if (y+1 < h) p+w else -1
                    }
                    if (q >= 0 && occupied[q]) { occupied[q] = false; queue[tail++] = q }
                }
            }
            if (tail >= 8) blobs.add(intArrayOf(x0, y0, x1+1, y1+1, tail))
        }
        val main = blobs.maxByOrNull { it[4] } ?: return Observation(emptyList(), 0, false)
        val subjects = blobs.count { it[4] >= max(8.0, main[4] * .15) }
        val model = doubleArrayOf(main[0] * step.toDouble() / width, main[1] * step.toDouble() / height,
            min(width, main[2] * step).toDouble() / width, min(height, main[3] * step).toDouble() / height)
        val source = model.mapIndexed { i, v -> ((v - rect[i % 2]) / rect[i % 2 + 2]).coerceIn(0.0, 1.0) }
        val cropped = (main[0] == 0 && source[0] > .035) || (main[2] == w && source[2] < .965) ||
            (main[1] == 0 && source[1] > .035) || (main[3] == h && source[3] < .965)
        return Observation(source, subjects, cropped)
    }
}
