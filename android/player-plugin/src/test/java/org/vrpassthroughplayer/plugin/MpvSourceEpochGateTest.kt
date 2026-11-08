package org.vrpassthroughplayer.plugin

import org.junit.Assert.*
import org.junit.Test

class MpvSourceEpochGateTest {
    @Test fun spontaneousResetRetiresAllFurtherWorkUntilANewProcessingScope() {
        val old=MpvSourceEpochGate()
        assertEquals(MpvSourceEpochGate.Action.ACCEPT,old.observe(7))
        assertEquals(MpvSourceEpochGate.Action.ACCEPT,old.observe(7))
        assertEquals(MpvSourceEpochGate.Action.DROP,old.observe(6))
        assertEquals(MpvSourceEpochGate.Action.REVISE,old.observe(8))
        assertTrue(old.revisionPending)
        // Do not relabel an old frame or emit another revision for every new frame.
        for(epoch in listOf(6L,7L,8L,9L))assertEquals(MpvSourceEpochGate.Action.DROP,old.observe(epoch))
        assertEquals(7L,old.epoch)
        val next=MpvSourceEpochGate(old.floorForNextGeneration)
        assertFalse(next.revisionPending)
        // A retained old native redraw must not become the first frame of the new scope.
        assertEquals(MpvSourceEpochGate.Action.DROP,next.observe(7))
        assertEquals(0L,next.epoch)
        assertEquals(MpvSourceEpochGate.Action.ACCEPT,next.observe(9))
        assertEquals(MpvSourceEpochGate.Action.DROP,next.observe(8))
    }
    @Test fun invalidEpochCannotBecomeAFrameIdentity() {
        val gate=MpvSourceEpochGate()
        for(epoch in listOf(0L,-1L))assertThrows(IllegalArgumentException::class.java){gate.observe(epoch)}
        assertEquals(0L,gate.epoch)
        assertEquals(MpvSourceEpochGate.Action.ACCEPT,gate.observe(1))
    }
}
