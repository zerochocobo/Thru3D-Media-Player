package org.vrpassthroughplayer.plugin

import org.junit.Assert.*
import org.junit.Test

class PhotoMemoryTest {
    private val m=PhotoMemory.MIB
    private fun budget(available: Long=2048, heap: Long=512, used: Long=100, low: Boolean=false)=
        PhotoMemory.evaluate(6144*m,available*m,128*m,low,heap*m,used*m)
    @Test fun currentFreeMemoryChangesAdmissionOnTheSameDevice() {
        assertTrue(budget(3072).native>budget(1024).native)
        assertTrue(budget(3072).output>budget(1024).output)
        assertEquals(0L,budget(200).native)
    }
    @Test fun javaHeapAlsoBoundsOutputEvenWithPlentyOfSystemRam() {
        assertTrue(budget(4096,512,480).output<budget(4096,512,100).output)
        assertEquals(0L,budget(4096,512,500).output)
    }
    @Test fun pressureAndExhaustedHeadroomDoNotBecomeUnsignedAllowances() {
        assertEquals(PhotoMemory.Budget(0,0),budget(low=true))
        assertEquals(PhotoMemory.Budget(0,0),budget(0))
        assertEquals(0L,budget(heap=128,used=256).output)
    }
    @Test fun reserveIncludesTheOsThresholdAndLeavesRoomForConcurrentWork() {
        val b=PhotoMemory.evaluate(8192*m,2048*m,1024*m,false,1024*m,128*m)
        assertTrue(b.native<=1024*m*2/3)
        assertTrue(b.output<=b.native/6)
    }
}
