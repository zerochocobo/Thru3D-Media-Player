package org.vrpassthroughplayer.plugin

import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

class OriginalCaptureFrameTest {
    @Test
    fun blackGridIsAFailedSystemFrame() {
        assertTrue(OriginalCapture.uniformPixels(IntArray(1024) { 0xFF000000.toInt() }))
    }

    @Test
    fun anyDifferingSampleKeepsTheSystemFrame() {
        assertFalse(OriginalCapture.uniformPixels(IntArray(1024) { if (it == 700) 0xFF010000.toInt() else 0xFF000000.toInt() }))
    }
}
