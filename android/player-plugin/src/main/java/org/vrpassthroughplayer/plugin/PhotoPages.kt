package org.vrpassthroughplayer.plugin

import java.nio.ByteBuffer
import java.nio.ByteOrder
import java.util.concurrent.ConcurrentHashMap

/** Magazine and comic spreads: two pages joined side by side. Each page gets its own depth inference
 * and normalization, and its own warp, so one page's scene never sets the other's depth and nothing
 * is stretched or filled across the seam. The spread keeps one near map (each page's map resampled
 * into its own columns), so caching, refinement and Godot see an ordinary photo. */
internal object PhotoPages {
    private val splits = ConcurrentHashMap<Int, Float>()

    /** [split]: the left page's share of the spread's width; ids are unique across the photo bridges. */
    fun set(id: Int, split: Float): Boolean {
        if (!split.isFinite() || split <= 0.05f || split >= 0.95f) return false
        splits[id] = split
        return true
    }
    fun split(id: Int): Float = splits[id] ?: 0f
    fun clear(id: Int) { splits.remove(id) }

    /** The spread map's first column of the right page. */
    fun seam(width: Int, split: Float) = (split * width).let { kotlin.math.round(it).toInt() }.coerceIn(1, width - 1)

    /** Each page's full map (width x height floats, content covering the map) squeezed into its columns. */
    fun compose(left: ByteBuffer, right: ByteBuffer, width: Int, height: Int, split: Float): ByteBuffer {
        require(width > 1 && height > 0 && left.remaining() >= width * height * 4 && right.remaining() >= width * height * 4)
        val seam = seam(width, split)
        val output = ByteBuffer.allocateDirect(width * height * 4).order(ByteOrder.LITTLE_ENDIAN)
        val pages = listOf(left, right).map { page ->
            FloatArray(width * height).also { page.duplicate().order(ByteOrder.LITTLE_ENDIAN).asFloatBuffer().get(it) }
        }
        for (y in 0 until height) for (x in 0 until width) {
            val page = if (x < seam) 0 else 1
            val first = if (page == 0) 0 else seam
            val columns = if (page == 0) seam else width - seam
            val values = pages[page]
            val fx = ((x - first + 0.5f) * width / columns - 0.5f).coerceIn(0f, width - 1f)
            val x0 = fx.toInt(); val x1 = minOf(x0 + 1, width - 1); val wx = fx - x0
            output.putFloat(values[y * width + x0] * (1 - wx) + values[y * width + x1] * wx)
        }
        output.rewind()
        return output
    }

    /** The pages' own content rects within the spread map (x, y, width, height as fractions). */
    fun rects(width: Int, split: Float): Pair<FloatArray, FloatArray> {
        val seam = seam(width, split).toFloat() / width
        return floatArrayOf(0f, 0f, seam, 1f) to floatArrayOf(seam, 0f, 1f - seam, 1f)
    }

    /** RGBA rows of [rgba] (width x height) from column [from], [columns] wide. */
    fun crop(rgba: ByteBuffer, width: Int, height: Int, from: Int, columns: Int): ByteBuffer {
        require(from >= 0 && columns > 0 && from + columns <= width)
        val source = rgba.duplicate()
        val output = ByteBuffer.allocateDirect(columns * height * 4).order(ByteOrder.LITTLE_ENDIAN)
        for (y in 0 until height) {
            source.limit((y * width + from + columns) * 4).position((y * width + from) * 4)
            output.put(source)
        }
        output.rewind()
        return output
    }

    /** Two pages' side-by-side pairs ([L|R], 2 x page width each) as the spread's pair: L = left page L +
     * right page L. */
    fun stitch(left: ByteBuffer, leftWidth: Int, right: ByteBuffer, rightWidth: Int, height: Int): ByteBuffer {
        val output = ByteBuffer.allocateDirect((leftWidth + rightWidth) * 2 * height * 4).order(ByteOrder.LITTLE_ENDIAN)
        fun row(pair: ByteBuffer, width: Int, y: Int, eye: Int) {
            val start = (y * width * 2 + eye * width) * 4
            output.put(pair.duplicate().apply { limit(start + width * 4); position(start) })
        }
        for (y in 0 until height) for (eye in 0..1) { row(left, leftWidth, y, eye); row(right, rightWidth, y, eye) }
        output.rewind()
        return output
    }
}
