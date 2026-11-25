package org.vrpassthroughplayer.plugin

import org.junit.Assert.*
import org.junit.Test

class LayerCopyEnlargeTest {
    /** Picture settings with super resolution at [level] for a picture of [kind] (0 flat, 1 VR180, 2 VR360). */
    private fun look(level: Int, kind: Int, across: Int = 1, down: Int = 1) = FloatArray(19).also {
        it[13] = level.toFloat(); it[14] = kind.toFloat(); it[15] = across.toFloat(); it[16] = down.toFloat()
    }

    @Test fun enlargesToTheBoxWithoutACap() {
        assertEquals(5760 to 2880, LayerCopy.enlargedSize(3840, 1920, look(2, 1, across = 2), 0))
        assertEquals(3840 to 2160, LayerCopy.enlargedSize(1920, 1080, look(2, 0), 0))
        assertEquals(3840 to 1920, LayerCopy.enlargedSize(1920, 960, look(1, 1, across = 2), 0))
    }

    @Test fun stopsAtTheOutputCapInsteadOfGivingUp() {
        assertEquals(4096 to 2048, LayerCopy.enlargedSize(1920, 960, look(2, 1, across = 2), 4096))
        assertEquals(3840 to 2160, LayerCopy.enlargedSize(1920, 1080, look(2, 0), 4096))
        // Under the cap 4K VR180 would grow by less than is worth a second pass.
        assertNull(LayerCopy.enlargedSize(3840, 1920, look(2, 1, across = 2), 4096))
    }

    @Test fun leavesTheFrameWhenOffOrAlreadyLarge() {
        assertNull(LayerCopy.enlargedSize(1920, 1080, look(0, 0), 0))
        assertNull(LayerCopy.enlargedSize(8192, 4096, look(2, 1, across = 2), 0))
    }

    @Test fun anime4kDoublesUpTo1080pTwiceAtMost() {
        assertEquals(2, LayerCopy.anime4kDoublings(352, 240, 0)) // DVD (VCD size): 1408 x 960
        assertEquals(2, LayerCopy.anime4kDoublings(720, 480, 0)) // DVD: 2880 x 1920
        assertEquals(1, LayerCopy.anime4kDoublings(1280, 720, 0))
        assertEquals(1, LayerCopy.anime4kDoublings(1920, 1080, 0))
        assertEquals(1, LayerCopy.anime4kDoublings(1080, 1920, 0)) // portrait: the long side counts
        assertEquals(0, LayerCopy.anime4kDoublings(2560, 1440, 0))
        assertEquals(0, LayerCopy.anime4kDoublings(3840, 2160, 0))
    }

    @Test fun anime4kStaysWithinTheOutputCap() {
        assertEquals(1, LayerCopy.anime4kDoublings(720, 480, 2048))
        assertEquals(0, LayerCopy.anime4kDoublings(1920, 1080, 2048))
        assertEquals(1, LayerCopy.anime4kDoublings(1920, 1080, 4096))
    }
}
