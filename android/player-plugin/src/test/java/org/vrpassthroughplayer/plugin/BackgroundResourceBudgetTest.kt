package org.vrpassthroughplayer.plugin

import org.junit.Assert.*
import org.junit.Test

class BackgroundResourceBudgetTest {
    private val mib = BackgroundResourceBudget.MIB
    private fun sample(available: Long = 4096 * mib, low: Boolean = false, thermal: Int = 0,
                       total: Long = 8192 * mib, heapUsed: Long = 64 * mib) =
        BackgroundResourceBudget.evaluate(total, available, 256 * mib, low, 512 * mib, heapUsed, thermal)

    @Test fun headroomUsesSystemPressureAndLeavesAReserve() {
        val value = sample()
        assertTrue(value.retain); assertTrue(value.work)
        assertEquals(8192 * mib / 100 * 15, value.reserve)
        assertEquals(4096 * mib - value.reserve, value.spare)
        assertEquals(768 * mib, value.cacheLimit)
        assertTrue(value.admits(value.spare)); assertFalse(value.admits(value.spare + 1))
        assertFalse(value.admits(0))
        assertEquals(768 * mib, sample(total = 4096 * mib).reserve)
        val threshold = BackgroundResourceBudget.evaluate(4096 * mib, 3000 * mib, 700 * mib,
            false, 512 * mib, 0, 0)
        assertEquals(1400 * mib, threshold.reserve)
    }

    @Test fun pressureUnknownDataAndHeapExhaustionCannotAdmitBackgroundWork() {
        for (value in listOf(sample(available = 128 * mib), sample(low = true), sample(total = 0),
            sample(heapUsed = 510 * mib), sample(thermal = -1), sample(thermal = 2), sample(thermal = 6))) {
            assertFalse(value.work); assertFalse(value.admits(mib))
        }
        assertFalse(sample(low = true).retain)
        assertTrue("Heat blocks new computation, not useful existing results", sample(thermal = 2).retain)
        assertFalse(BackgroundResourceBudget.snapshot(null).retain)
    }

    @Test fun photoPeakScalesWithWorkPixelsAndBoundsExtremeDimensions() {
        assertEquals(512 * mib + 640L * 480 * 48, BackgroundResourceBudget.photoPeak(640, 480))
        assertEquals(Long.MAX_VALUE, BackgroundResourceBudget.photoPeak(0, 100))
        val huge = BackgroundResourceBudget.photoPeak(Int.MAX_VALUE, Int.MAX_VALUE)
        assertTrue(huge in (512 * mib + 1)..(1536 * mib))
        assertTrue(sample().admits(huge))
        assertFalse(sample(available = 1600 * mib).admits(huge))
    }
}
