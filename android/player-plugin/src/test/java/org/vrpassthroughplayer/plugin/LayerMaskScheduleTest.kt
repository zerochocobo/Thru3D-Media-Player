package org.vrpassthroughplayer.plugin

import org.junit.Assert.*
import org.junit.Test

class LayerMaskScheduleTest {
    private val ms = 1_000_000L
    private val retired = ArrayList<Long>()
    private fun LayerMaskSchedule<String>.at(frame: Long) = show(frame) { retired.add(it) }

    @Test fun aMaskWaitsForItsFrameAndIsDrawnOnce() {
        val schedule = LayerMaskSchedule<String>()
        schedule.add(1, 10, "a", 0)
        assertNull(schedule.at(9))
        val shown = schedule.at(10)!!
        assertEquals(1L, shown.mask.token); assertNull(shown.next); assertEquals(0f, shown.weight, 0f)
        assertNull(schedule.at(10)) // already on the layer
        assertNull(schedule.at(11)) // no later mask: the earlier one stays
        assertTrue(retired.isEmpty())
    }

    @Test fun aFrameBetweenTwoMasksMixesThemByItsPlace() {
        val schedule = LayerMaskSchedule<String>()
        schedule.add(1, 10, "a", 0); schedule.add(2, 13, "b", 50 * ms)
        schedule.at(10)
        val first = schedule.at(11)!!
        assertEquals(1L, first.mask.token); assertEquals(2L, first.next!!.token); assertEquals(1f / 3, first.weight, 1e-6f)
        assertNull(schedule.at(11))
        assertEquals(2f / 3, schedule.at(12)!!.weight, 1e-6f)
        val own = schedule.at(13)!!
        assertEquals(2L, own.mask.token); assertNull(own.next)
        assertEquals(listOf(1L), retired) // the earlier mask is kept until the later one's frame
    }

    @Test fun aLaterMaskArrivingLateIsMixedFromThenOn() {
        val schedule = LayerMaskSchedule<String>()
        schedule.add(1, 10, "a", 0)
        schedule.at(10); assertNull(schedule.at(11))
        schedule.add(2, 13, "b", 50 * ms)
        assertEquals(2f / 3, schedule.at(12)!!.weight, 1e-6f)
    }

    @Test fun withoutBlendingAFrameKeepsTheEarlierMask() {
        val schedule = LayerMaskSchedule<String>(blend = false)
        schedule.add(1, 10, "a", 0); schedule.add(2, 12, "b", 50 * ms)
        assertNotNull(schedule.at(10))
        assertNull(schedule.at(11))
        assertEquals(2L, schedule.at(12)!!.mask.token)
    }

    @Test fun theSwitchAppliesFromTheNextFrame() {
        val schedule = LayerMaskSchedule<String>()
        schedule.add(1, 10, "a", 0); schedule.add(2, 14, "b", 50 * ms)
        schedule.at(10)
        assertEquals(0.25f, schedule.at(11)!!.weight, 1e-6f)
        schedule.blend = false
        val plain = schedule.at(12)!! // the mixed draw is replaced by the earlier mask alone
        assertEquals(1L, plain.mask.token); assertNull(plain.next)
        assertNull(schedule.at(13))
    }

    @Test fun masksFarApartDoNotMix() {
        val schedule = LayerMaskSchedule<String>()
        schedule.add(1, 10, "a", 0); schedule.add(2, 10 + LayerMaskSchedule.SPAN_LIMIT + 1, "b", 50 * ms)
        assertNotNull(schedule.at(10))
        assertNull(schedule.at(12))
    }

    @Test fun skippedMasksRetireAndTheNewestPresentedShows() {
        val schedule = LayerMaskSchedule<String>()
        schedule.add(1, 10, "a", 0); schedule.add(2, 12, "b", 0); schedule.add(3, 14, "c", 0)
        val shown = schedule.at(13)!!
        assertEquals(2L, shown.mask.token); assertEquals(3L, shown.next!!.token); assertEquals(0.5f, shown.weight, 1e-6f)
        assertEquals(listOf(1L), retired)
    }

    @Test fun aStalledCopyLetsMasksThrough() {
        val schedule = LayerMaskSchedule<String>()
        for (index in 1..5L) schedule.add(index, 100 + index, "m", 0)
        val shown = schedule.at(50)!! // the copy never reached these frames
        assertEquals(2L, shown.mask.token); assertNull(shown.next)
        assertEquals(listOf(1L), retired)
        assertEquals(LayerMaskSchedule.LIMIT, schedule.size)
    }

    @Test fun theIntervalFollowsTheMasksAndIgnoresPauses() {
        val schedule = LayerMaskSchedule<String>()
        schedule.add(1, 1, "a", 0)
        assertEquals(0.0, schedule.intervalMs, 0.0)
        schedule.add(2, 3, "b", 50 * ms)
        assertEquals(50.0, schedule.intervalMs, 1e-9)
        schedule.add(3, 5, "c", 2050 * ms) // paused for two seconds
        assertEquals(50.0, schedule.intervalMs, 1e-9)
        schedule.add(4, 7, "d", 2110 * ms)
        assertEquals(51.0, schedule.intervalMs, 1e-9)
    }
}
