package org.vrpassthroughplayer.plugin

import org.junit.Assert.*
import org.junit.Test

class PhotoStereoTest {
    @Test fun rotationCacheIdentityIncludesAngleAndStrength() {
        val rotations = listOf(0,90,180,270)
        assertEquals(4,rotations.map { PhotoStereo.cachePrefix(1f,it) }.toSet().size)
        assertNotEquals(PhotoStereo.cachePrefix(1f,90),PhotoStereo.cachePrefix(2f,90))
        assertTrue(PhotoStereo.cachePrefix(1f,0).startsWith("stereo-v4-r0-"))
        for (rotation in listOf(-90,45,360,450)) {
            assertFalse(PhotoStereo.validRotation(rotation))
            try { PhotoStereo.cachePrefix(1f,rotation); fail("invalid rotation") } catch (_: IllegalArgumentException) { }
        }
    }
    @Test fun screenPlaneIsPartOfCacheIdentity() {
        assertEquals(PhotoStereo.cachePrefix(1f,0), PhotoStereo.cachePrefix(1f,0,0.35f))
        for (rotation in listOf(0,90,180,270)) {
            assertEquals(3, listOf(0.05f,0.35f,0.65f).map { PhotoStereo.cachePrefix(1f,rotation,it) }.toSet().size)
        }
        for (plane in listOf(Float.NaN,Float.POSITIVE_INFINITY,-0.01f,1.01f)) {
            try { PhotoStereo.cachePrefix(1f,0,plane); fail("invalid plane") } catch (_: IllegalArgumentException) { }
        }
    }
    @Test fun boundStereoAllocationWithoutUpscaling() {
        for ((w,h) in listOf(640 to 480,8192 to 8192,8192 to 4000,100 to 32000,32000 to 100)) {
            val (a,b)=PhotoStereo.size(w,h)
            assertTrue(a in 1..PhotoStereo.MAX_EDGE && b in 1..PhotoStereo.MAX_EDGE)
            assertTrue(a.toLong()*b<=PhotoStereo.MAX_PIXELS)
            assertTrue(a<=w && b<=h)
            assertTrue(kotlin.math.abs(a-b*w.toDouble()/h)<=1.01 || kotlin.math.abs(b-a*h.toDouble()/w)<=1.01)
        }
        assertEquals(640 to 480,PhotoStereo.size(640,480))
    }
}
