package org.vrpassthroughplayer.plugin

import org.junit.Assert.*
import org.junit.Test
import java.util.Random
import kotlin.math.abs

class StereoFocusProbeTest {
    private val width = 400
    private val height = 60
    private val eye = 200

    /** Both eyes' patches side by side: the same smooth texture, the left eye's [shift] pixels further right. */
    private fun strip(shift: Float, flat: Boolean = false): FloatArray {
        val random = Random(7)
        val coarse = Array(height / 4 + 2) { FloatArray(eye + 80) { if (flat) 90f else random.nextFloat() * 255f } }
        fun texture(x: Float, y: Int): Float {
            val row = coarse[y / 4]
            val at = (x + 40f) / 4f
            val index = at.toInt()
            return row[index] + (row[index + 1] - row[index]) * (at - index)
        }
        return FloatArray(width * height) { i ->
            val x = i % width
            val y = i / width
            if (x < eye) texture(x - shift / 2f, y) else texture(x - eye + shift / 2f, y)
        }
    }

    private fun match(luma: FloatArray) = StereoFocusProbe.match(luma, width, height, eye / 2, height / 2, eye + eye / 2, height / 2, 40, 24, -12, 40)

    @Test fun findsNearAndFarDisparityToAFractionOfAPixel() {
        for (shift in listOf(-6f, 0f, 3.5f, 17f, 31f)) {
            val found = match(strip(shift))
            assertTrue("shift $shift found ${found[0]}", abs(found[0] - shift) < 0.35f)
            assertTrue("shift $shift peak ${found[1]}", found[1] > 0.85f)
            assertTrue(found[1] - found[2] > 0.3f)
            assertTrue(found[3] > 10f)
        }
    }

    @Test fun reportsNothingForAFlatPictureOrADisparityOutsideTheSearch() {
        assertEquals(0f, match(strip(5f, flat = true))[1], 0f)
        assertTrue(match(strip(-30f))[1] < 0.5f)
    }

    @Test fun reportsNothingWhenAWindowLeavesThePicture() {
        assertEquals(0f, StereoFocusProbe.match(strip(4f), width, height, 20, height / 2, eye + 20, height / 2, 40, 24, -12, 40)[1], 0f)
    }

    @Test fun measuresStraightenedLensPatchesInDegrees() {
        // Both eyes' patches at twice the matched density (12 px per degree), 29 x 12 degrees each.
        val patch = 348
        val rows = 144
        val random = Random(11)
        val coarse = Array(rows / 8 + 2) { FloatArray(patch / 8 + 20) { random.nextFloat() * 255f } }
        fun texture(x: Float, y: Int): Float {
            val row = coarse[y / 8]
            val at = (x + 60f) / 8f
            val index = at.toInt()
            return row[index] + (row[index + 1] - row[index]) * (at - index)
        }
        for (degrees in listOf(-1.5f, 0f, 2f, 9f)) {
            val shift = degrees * 12f
            val pixels = ByteArray(patch * 2 * rows * 4)
            for (y in 0 until rows) for (x in 0 until patch * 2) {
                val value = if (x < patch) texture(x - shift / 2f, y) else texture(x - patch + shift / 2f, y)
                pixels[(y * patch * 2 + x) * 4] = value.toInt().toByte()
            }
            val found = StereoFocusProbe.measureLens(pixels, patch * 2, rows)
            assertTrue("$degrees degrees found ${found[0]}", abs(found[0] - degrees) < 0.1f)
            assertTrue("$degrees degrees peak ${found[1]}", found[1] > 0.85f)
        }
    }
}
