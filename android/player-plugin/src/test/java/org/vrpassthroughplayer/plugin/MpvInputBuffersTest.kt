package org.vrpassthroughplayer.plugin

import java.nio.ByteBuffer
import java.nio.ByteOrder
import org.junit.Assert.*
import org.junit.Test

class MpvInputBuffersTest {
    @Test fun hostFallbackProvidesExactChwInputsForEveryRvmProfile() {
        // Neo3 can decode to a HardwareBuffer while RVM rejects GPU sharing. The host
        // transport must satisfy readInputs even for mono portrait (which fills both planes).
        for (profile in RvmProfiles.keys) {
            val (width, height) = profile.split('x').map { it.toInt() }
            val buffers = MpvInputBuffers(width, height).acquire(sharedAlpha = false)
            val bytes = width * height * 3 * 4
            assertInput(buffers.first, bytes)
            assertInput(buffers.second, bytes)
            buffers.first.putFloat(bytes - 4, 0.75f)
            buffers.second.putFloat(bytes - 4, 0.25f)
            assertEquals(0.75f, buffers.first.getFloat(bytes - 4), 0f)
            assertEquals(0.25f, buffers.second.getFloat(bytes - 4), 0f)
        }
    }

    @Test fun inFlightFramesKeepIndependentInputsAndRetiredFramesReuseStorage() {
        val pool = MpvInputBuffers(256, 144)
        val first = pool.acquire(sharedAlpha = false)
        val second = pool.acquire(sharedAlpha = false)
        first.first.putFloat(0, 0.75f)
        second.first.putFloat(0, 0.25f)
        assertEquals(0.75f, first.first.getFloat(0), 0f)
        pool.release(first.first, first.second)
        val reused = pool.acquire(sharedAlpha = false)
        assertSame(first.first, reused.first)
        assertSame(first.second, reused.second)
        assertNotSame(second.first, reused.first)
        assertNotSame(second.second, reused.second)
    }

    @Test fun zeroCopyNeverConsumesOrReturnsEmptyPlanesToTheHostPool() {
        val pool = MpvInputBuffers(320, 320)
        val host = pool.acquire(sharedAlpha = false)
        pool.release(host.first, host.second)
        repeat(32) {
            val shared = pool.acquire(sharedAlpha = true)
            assertSame(MpvInputBuffers.EMPTY, shared)
            assertEquals(0, shared.first.capacity())
            assertEquals(0, shared.second.capacity())
            pool.release(shared.first, shared.second)
        }
        val reused = pool.acquire(sharedAlpha = false)
        assertSame(host.first, reused.first)
        assertSame(host.second, reused.second)
        assertInput(pool.acquire(sharedAlpha = false).first, 320 * 320 * 12)
    }

    @Test fun clearingSessionDropsRetiredBuffers() {
        val pool = MpvInputBuffers(256, 144)
        val old = pool.acquire(sharedAlpha = false)
        pool.release(old.first, old.second)
        pool.clear()
        val next = pool.acquire(sharedAlpha = false)
        assertNotSame(old.first, next.first)
        assertNotSame(old.second, next.second)
        assertInput(next.first, 256 * 144 * 12)
    }

    private fun assertInput(buffer: ByteBuffer, bytes: Int) {
        assertTrue(buffer.isDirect)
        assertFalse(buffer.isReadOnly)
        assertEquals(ByteOrder.LITTLE_ENDIAN, buffer.order())
        assertEquals(bytes, buffer.capacity())
        assertEquals(0, buffer.position())
        assertEquals(bytes, buffer.limit())
    }
}
