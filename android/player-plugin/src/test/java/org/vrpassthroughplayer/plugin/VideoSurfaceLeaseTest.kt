package org.vrpassthroughplayer.plugin

import org.junit.Assert.*
import org.junit.Test
import org.vrpassthroughplayer.plugin.VideoSurfaceLease.Output

class VideoSurfaceLeaseTest {
    @Test fun normalSwitchWaitsForAcknowledgementAndKeepsLayerOutput() {
        val lease = VideoSurfaceLease<Any>()
        val old = Any()
        val next = Any()
        assertEquals(Output.LAYER, lease.selectOutput(old, wantsLayer = true, slotsClosing = false, expired = false))
        assertEquals(Output.WAIT, lease.selectOutput(next, true, false, false))
        assertTrue(lease.release(old) {})
        assertEquals(Output.LAYER, lease.selectOutput(next, true, false, true))
    }

    @Test fun heldSurfaceAtTheDeadlineFailsTheLayerOpenInsteadOfFallingBack() {
        val lease = VideoSurfaceLease<Any>()
        val writing = Any()
        val next = Any()
        assertTrue(lease.acquire(writing))
        // An eye-buffer open never needs the Surface.
        assertEquals(Output.EYE_BUFFER, lease.selectOutput(next, false, false, false))
        assertEquals(Output.WAIT, lease.selectOutput(next, true, false, false))
        // No second source at the deadline: a stuck one can wedge the process (5YKQKKN4).
        assertEquals(Output.SURFACE_TIMEOUT, lease.selectOutput(next, true, false, true))
        assertSame(writing, lease.owner)
        assertFalse(lease.release(next) { fail("A failed open must not destroy the live Surface") })
        assertTrue(lease.release(writing) {})
        assertEquals(Output.LAYER, lease.selectOutput(Any(), true, false, true))
    }

    @Test fun thirdOpenCannotTakeEitherOutputWhenBothNativeSlotsAreClosing() {
        val lease = VideoSurfaceLease<Any>()
        val old = Any()
        val next = Any()
        assertTrue(lease.acquire(old))
        for (wantsLayer in listOf(false, true)) {
            assertEquals(Output.WAIT, lease.selectOutput(next, wantsLayer, true, false))
            assertEquals(Output.SLOTS_FULL, lease.selectOutput(next, wantsLayer, true, true))
        }
        assertSame(old, lease.owner)
        assertTrue(lease.release(old) {})
        assertEquals(Output.SLOTS_FULL, lease.selectOutput(next, true, true, true))
        assertNull(lease.owner)
        assertEquals(Output.LAYER, lease.selectOutput(next, true, false, false))
    }

    @Test fun delayedBrowserDecoderKeepsItsSurfaceUntilAcknowledgedClose() {
        for (origin in listOf("browser", "dlna", "external", "library")) {
            val lease = VideoSurfaceLease<Any>()
            val previous = Any()
            val replacement = Any()
            val events = mutableListOf<String>()
            assertTrue(lease.acquire(previous))
            events += "$origin:start"
            // RequestClose only sets a flag; MediaCodec can still write while it drains.
            events += "$origin:request_close"
            repeat(30) {
                if (lease.acquire(replacement)) events += "new_surface_destroys_previous"
                events += "$origin:decoder_write"
            }
            assertFalse(events.contains("new_surface_destroys_previous"))
            events += "$origin:native_close_complete"
            assertTrue(lease.release(previous) { events += "$origin:destroy_surface" })
            assertTrue(lease.acquire(replacement))
            events += "replacement:create_surface"
            assertTrue(events.indexOf("$origin:destroy_surface") > events.lastIndexOf("$origin:decoder_write"))
            assertTrue(events.indexOf("replacement:create_surface") > events.indexOf("$origin:destroy_surface"))
        }
    }

    @Test fun delayedOrRepeatedOldCleanupCannotDestroyTheReplacement() {
        val lease = VideoSurfaceLease<Any>()
        val previous = Any()
        val replacement = Any()
        var destroyed = 0
        assertTrue(lease.acquire(previous))
        assertTrue(lease.release(previous) { destroyed++ })
        assertTrue(lease.acquire(replacement))
        assertFalse(lease.release(previous) { destroyed++ })
        assertEquals(1, destroyed)
        assertTrue(lease.release(replacement) { destroyed++ })
        assertEquals(2, destroyed)
    }

    @Test fun failedDestructionKeepsOwnershipForRetry() {
        val lease = VideoSurfaceLease<Any>()
        val previous = Any()
        val replacement = Any()
        assertTrue(lease.acquire(previous))
        try {
            lease.release(previous) { error("native teardown pending") }
            fail("Expected teardown failure")
        } catch (_: IllegalStateException) { }
        assertFalse(lease.acquire(replacement))
        assertTrue(lease.release(previous) {})
        assertTrue(lease.acquire(replacement))
    }

    @Test fun cancelledWaiterNeverTakesTheSurfaceFromAnActiveProducer() {
        val lease = VideoSurfaceLease<Any>()
        val previous = Any()
        val cancelled = Any()
        val latest = Any()
        assertTrue(lease.acquire(previous))
        assertFalse(lease.acquire(cancelled))
        assertFalse(lease.release(cancelled) { fail("A waiting request owns no native Surface") })
        assertTrue(lease.release(previous) {})
        assertTrue(lease.acquire(latest))
        assertFalse(lease.acquire(cancelled))
    }
}
