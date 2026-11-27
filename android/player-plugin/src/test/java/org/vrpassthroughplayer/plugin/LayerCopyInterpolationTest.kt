package org.vrpassthroughplayer.plugin

import org.junit.Assert.assertEquals
import org.junit.Test

/** Frame interpolation's timing: which latch a draw is for, and where between two frames it falls. */
class LayerCopyInterpolationTest {
    private val period = 13_888_889L // 72 Hz
    private val lead = 16_000_000L
    private val display = 1_000_000_000L
    private val grid = display - lead

    @Test fun successfulSubmissionsCountEachVideoMomentOnce() {
        val frames = LayerCopy.OutputFrames()
        frames.submitted(5)
        frames.submitted(5) // a settings redraw
        frames.submitted(5, 0.33f)
        frames.submitted(5, 0.33f)
        frames.submitted(5, 0.67f)
        frames.submitted(6) // a fallback to the nearer source, followed by that same source
        frames.submitted(6)
        assertEquals(4L, frames.total)
        assertEquals(2L, frames.between)
    }

    @Test fun aDrawIsForTheFirstLatchHalfAPeriodAway() {
        // Just after a latch: the next one is nearly a whole period away.
        assertEquals(grid + period, LayerCopy.latchAfter(grid + 1_000_000L, display, period, lead))
        // Past the middle: that latch is too close for the GPU, the one after it.
        assertEquals(grid + 2 * period, LayerCopy.latchAfter(grid + period / 2 + 1_000_000L, display, period, lead))
        // The reported display time may lie ahead of now or long behind it.
        assertEquals(grid - 2 * period, LayerCopy.latchAfter(grid - 3 * period + 1_000_000L, display, period, lead))
        assertEquals(grid + 1001 * period, LayerCopy.latchAfter(grid + 1000 * period + 1_000_000L, display, period, lead))
    }

    @Test fun successiveDrawsTakeSuccessiveLatches() {
        var latch = LayerCopy.latchAfter(grid + 2_000_000L, display, period, lead)
        repeat(200) {
            // Each draw starts 15% of a period after the latch before its own.
            val next = LayerCopy.latchAfter(latch + period * 3 / 20, display, period, lead)
            assertEquals(latch + period, next)
            latch = next
        }
    }

    @Test fun aFilmFrameSpansThreeRefreshes() {
        val step = 41_708_333L // 23.976 fps
        assertEquals(0f, LayerCopy.phaseBetween(0L, 0L, step), 0f)
        assertEquals(1f / 3f, LayerCopy.phaseBetween(step / 3, 0L, step), 1e-4f)
        assertEquals(2f / 3f, LayerCopy.phaseBetween(step * 2 / 3, 0L, step), 1e-4f)
    }

    @Test fun nextToAFrameIsTheFrame() {
        assertEquals(0f, LayerCopy.phaseBetween(-5L, 0L, 1000L), 0f)
        assertEquals(0f, LayerCopy.phaseBetween(30L, 0L, 1000L), 0f)
        assertEquals(1f, LayerCopy.phaseBetween(970L, 0L, 1000L), 0f)
        assertEquals(1f, LayerCopy.phaseBetween(5000L, 0L, 1000L), 0f)
        assertEquals(0.5f, LayerCopy.phaseBetween(500L, 0L, 1000L), 1e-6f)
        // Frames out of order (a seek's leftovers) never divide by zero or run backwards.
        assertEquals(0f, LayerCopy.phaseBetween(500L, 1000L, 1000L), 0f)
        assertEquals(0f, LayerCopy.phaseBetween(500L, 1000L, 0L), 0f)
    }
}
