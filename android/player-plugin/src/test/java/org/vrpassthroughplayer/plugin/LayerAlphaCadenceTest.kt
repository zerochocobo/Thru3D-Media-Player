package org.vrpassthroughplayer.plugin

import org.junit.Assert.*
import org.junit.Test

class LayerAlphaCadenceTest {
    private val ms = 1_000_000L

    @Test fun oneInfersWhileTheNewestWaitsAndNoMore() {
        val cadence = LayerAlphaCadence()
        assertTrue(cadence.hasRoom(0))
        cadence.captured(1, 0, 0)
        assertTrue(cadence.hasRoom(0)) // the model is busy: the next frame waits behind it
        cadence.captured(2, 33 * ms, 33 * ms)
        assertFalse(cadence.hasRoom(40 * ms))
        cadence.finished(1)
        assertTrue(cadence.hasRoom(50 * ms))
        assertEquals(1, cadence.size)
    }

    @Test fun limitOneKeepsOneAtATime() {
        val cadence = LayerAlphaCadence(1)
        cadence.captured(1, 0, 0)
        assertFalse(cadence.hasRoom(10 * ms))
        cadence.finished(1)
        assertTrue(cadence.hasRoom(10 * ms))
    }

    @Test fun droppedCapturesStopCountingAfterASecond() {
        val cadence = LayerAlphaCadence(2)
        cadence.captured(1, 0, 0)
        cadence.captured(2, 33 * ms, 33 * ms)
        assertFalse(cadence.hasRoom(1_000 * ms))
        assertTrue(cadence.hasRoom(1_001 * ms + 1)) // token 1 is stale, token 2 still counts
        assertEquals(1, cadence.size)
        cadence.finished(99) // unknown or already finished tokens are harmless
        assertEquals(1, cadence.size)
    }

    @Test fun framesAreSpacedByTheirTimestampsNotTheDrawClock() {
        val cadence = LayerAlphaCadence()
        assertTrue(cadence.due(5_000 * ms, 30))
        cadence.captured(1, 5_000 * ms, 0)
        // 30 fps frames with jitter are each due at a 30 FPS limit, however late the GL thread looks.
        assertTrue(cadence.due(5_000 * ms + 31 * ms, 30))
        assertTrue(cadence.due(5_000 * ms + 33_333_333L, 30))
        // 60 fps: every other frame.
        assertFalse(cadence.due(5_000 * ms + 16_666_667L, 30))
        // 20 FPS limit skips the next 30 fps frame.
        assertFalse(cadence.due(5_000 * ms + 33_333_333L, 20))
        assertTrue(cadence.due(5_000 * ms + 66_666_667L, 20))
    }

    @Test fun aTimestampGoingBackStartsAgain() {
        val cadence = LayerAlphaCadence()
        cadence.captured(1, 5_000 * ms, 0)
        assertTrue(cadence.due(1_000 * ms, 30))
        assertTrue(cadence.due(5_000 * ms - 1, 30))
    }
}
