package org.vrpassthroughplayer.plugin

import org.junit.Assert.assertArrayEquals
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test
import java.nio.ByteBuffer
import java.nio.ByteOrder

class PhotoPagesTest {
    private fun floats(values: FloatArray) = ByteBuffer.allocateDirect(values.size * 4).order(ByteOrder.LITTLE_ENDIAN)
        .apply { asFloatBuffer().put(values) }
    private fun bytes(values: IntArray) = ByteBuffer.allocateDirect(values.size).order(ByteOrder.LITTLE_ENDIAN)
        .apply { values.forEach { put(it.toByte()) }; rewind() }
    private fun read(buffer: ByteBuffer) = ByteArray(buffer.remaining()).also { buffer.duplicate().get(it) }.map { it.toInt() }

    @Test fun pagesKeepTheirOwnDepthInTheirOwnColumns() {
        // Each page's map is constant: the joined map takes one page's value on each side of the seam.
        val w = 8; val h = 2
        val joined = PhotoPages.compose(floats(FloatArray(w*h) { 0.2f }), floats(FloatArray(w*h) { 0.9f }), w, h, 0.5f)
        val values = FloatArray(w*h).also { joined.duplicate().order(ByteOrder.LITTLE_ENDIAN).asFloatBuffer().get(it) }
        for (y in 0 until h) for (x in 0 until w) assertEquals(if (x < 4) 0.2f else 0.9f, values[y*w+x], 1e-6f)
        val (left, right) = PhotoPages.rects(w, 0.5f)
        assertArrayEquals(floatArrayOf(0f, 0f, 0.5f, 1f), left, 1e-6f)
        assertArrayEquals(floatArrayOf(0.5f, 0f, 0.5f, 1f), right, 1e-6f)
    }

    @Test fun pageMapsAreSqueezedEdgeToEdge() {
        // A left-to-right ramp over the whole page map stays a ramp from its first to its last column.
        val w = 8; val h = 1
        val ramp = floats(FloatArray(w) { it / 7f })
        val joined = PhotoPages.compose(ramp, ramp, w, h, 0.5f)
        val values = FloatArray(w).also { joined.duplicate().order(ByteOrder.LITTLE_ENDIAN).asFloatBuffer().get(it) }
        assertTrue(values[0] < 0.15f && values[3] > 0.85f && values[4] < 0.15f && values[7] > 0.85f)
        for (x in 1..3) assertTrue(values[x] > values[x - 1])
    }

    @Test fun pairsStitchEyeByEye() {
        // Left page pair 1 column per eye (L=1, R=2), right page 2 columns (L=3,4, R=5,6), one pixel = 4 bytes.
        val left = bytes(intArrayOf(1,1,1,1, 2,2,2,2))
        val right = bytes(intArrayOf(3,3,3,3, 4,4,4,4, 5,5,5,5, 6,6,6,6))
        val joined = read(PhotoPages.stitch(left, 1, right, 2, 1))
        assertEquals(listOf(1,3,4,2,5,6), joined.chunked(4).map { it.first() })
    }

    @Test fun cropTakesColumnsOfEveryRow() {
        val rgba = bytes(IntArray(3*2*4) { it / 4 }) // pixel index in each byte
        assertEquals(listOf(1,2,4,5), read(PhotoPages.crop(rgba, 3, 2, 1, 2)).chunked(4).map { it.first() })
    }

    @Test fun splitsAreValidatedAndPerId() {
        assertFalse(PhotoPages.set(91, 0f))
        assertFalse(PhotoPages.set(91, Float.NaN))
        assertTrue(PhotoPages.set(91, 0.42f))
        assertEquals(0.42f, PhotoPages.split(91), 0f)
        assertEquals(0f, PhotoPages.split(92), 0f)
        PhotoPages.clear(91)
        assertEquals(0f, PhotoPages.split(91), 0f)
    }
}
