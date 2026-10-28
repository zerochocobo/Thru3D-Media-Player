package org.vrpassthroughplayer.plugin

import java.nio.ByteBuffer
import org.junit.Assert.*
import org.junit.Test

class PortraitMaskTest {
    private fun image(vararg boxes: IntArray): ByteBuffer {
        val result = ByteBuffer.allocateDirect(320 * 320)
        for (b in boxes) for (y in b[1] until b[3]) for (x in b[0] until b[2]) result.put(y * 320 + x, 255.toByte())
        return result
    }
    @Test fun paddedSourceMapsBackWithoutIncludingPadding() {
        val mask = image(intArrayOf(120, 100, 200, 220), intArrayOf(0, 0, 320, 60))
        val result = PortraitMask.observe(mask, 320, 320, floatArrayOf(0f, .25f, 1f, .5f))
        assertEquals(1, result.subjects)
        assertEquals(listOf(.375, .125, .625, .875), result.bounds)
        assertFalse(result.cropped)
    }
    @Test fun halfBodyAndDisjointSubjectsRemainDistinguishable() {
        val body = PortraitMask.observe(image(intArrayOf(120, 60, 200, 320)), 320, 320, floatArrayOf(0f, 0f, 1f, 1f))
        assertEquals(1.0, body.bounds[3], .00001)
        assertFalse(body.cropped)
        val multiple = PortraitMask.observe(image(intArrayOf(50, 80, 110, 300), intArrayOf(200, 80, 270, 300)),
            320, 320, floatArrayOf(0f, 0f, 1f, 1f))
        assertEquals(2, multiple.subjects)
    }
    @Test fun croppedRoiCannotPretendToBeACompletePerson() {
        val result = PortraitMask.observe(image(intArrayOf(120, 0, 200, 300)), 320, 320,
            floatArrayOf(-.5f, -.05f, 2f, .9f))
        assertTrue(result.cropped) // content height < 1 still clips at the top of the ROI
        assertTrue(result.bounds[1] > 0)
    }
    @Test fun emptyAndSmallNoiseDoNotProvideDistanceEvidence() {
        val result = PortraitMask.observe(image(intArrayOf(15, 15, 18, 18)), 320, 320, floatArrayOf(0f, 0f, 1f, 1f))
        assertEquals(0, result.subjects)
        assertTrue(result.bounds.isEmpty())
    }
}
