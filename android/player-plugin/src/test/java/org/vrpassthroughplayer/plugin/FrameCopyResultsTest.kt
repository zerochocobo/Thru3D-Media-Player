package org.vrpassthroughplayer.plugin

import org.junit.Assert.*
import org.junit.Test

class FrameCopyResultsTest {
    @Test fun copyIsConsumedOnce() {
        val copies = FrameCopyResults()
        val id = copies.reserve()
        assertEquals("pending", copies.state(id))
        copies.complete(id, byteArrayOf(1, 2, 3))
        assertEquals("ready", copies.state(id))
        assertArrayEquals(byteArrayOf(1, 2, 3), copies.take(id))
        copies.complete(id, byteArrayOf(9))
        assertEquals("failed:unknown", copies.state(id))
        assertTrue(copies.take(id).isEmpty())
    }

    @Test fun closeOrTimeoutDiscardsLateCopy() {
        val copies = FrameCopyResults()
        val id = copies.reserve()
        copies.cancel(id)
        copies.complete(id, ByteArray(4096))
        assertEquals("failed:unknown", copies.state(id))
        val next = copies.reserve()
        copies.complete(next, "failed:pixel_copy_3")
        assertEquals("failed:pixel_copy_3", copies.state(next))
        assertEquals("failed:unknown", copies.state(next))
    }

    @Test fun boundedPendingCopiesCannotReappearAfterEviction() {
        val copies = FrameCopyResults(2)
        val first = copies.reserve()
        val second = copies.reserve()
        val third = copies.reserve()
        copies.complete(first, ByteArray(4096))
        assertEquals("failed:unknown", copies.state(first))
        assertEquals("pending", copies.state(second))
        copies.complete(third, byteArrayOf(7))
        assertArrayEquals(byteArrayOf(7), copies.take(third))
        assertEquals("pending", copies.state(second))
    }
}
