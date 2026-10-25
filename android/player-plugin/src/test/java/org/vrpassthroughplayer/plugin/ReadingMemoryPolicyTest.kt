package org.vrpassthroughplayer.plugin

import org.junit.Assert.*
import org.junit.Test

class ReadingMemoryPolicyTest {
    private val m = ReadingMemoryPolicy.MIB
    @Test fun sixGiBAndLowRamUseSmallerSpreadAwareBudgets() {
        fun policy(total: Long, double: Boolean, lowRam: Boolean = false) =
            ReadingMemoryPolicy.evaluate(total*m, 2048*m, 128*m, false, lowRam, double)
        assertEquals(64*m, policy(6144,false).budget)
        assertEquals(96*m, policy(6144,true).budget)
        assertEquals(128*m, policy(8192,false).budget)
        assertEquals(192*m, policy(8192,true).budget)
        assertEquals(96*m, policy(8192,true,true).budget)
    }
    @Test fun SeparateAdmissionAndEvictionAvoidCancellingReservedAllocations() {
        fun policy(available: Long) = ReadingMemoryPolicy.evaluate(6144*m,available*m,128*m,false,false,true)
        assertFalse(policy(767).color)
        assertTrue(policy(768).color)
        assertEquals(96*m,policy(767).budget)
        assertTrue(policy(512).retain)
        assertFalse(policy(511).retain)
        assertEquals(0L,policy(511).budget)
    }
    @Test fun OsPressureAndUnknownMemoryFailClosed() {
        assertFalse(ReadingMemoryPolicy.evaluate(8192*m,4096*m,128*m,true,false,false).color)
        assertFalse(ReadingMemoryPolicy.evaluate(0,4096*m,0,false,false,false).color)
        assertFalse(ReadingMemoryPolicy.evaluate(8192*m,1024*m,512*m,false,false,false).color)
    }
}
