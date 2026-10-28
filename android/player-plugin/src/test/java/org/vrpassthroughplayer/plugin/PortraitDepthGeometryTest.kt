package org.vrpassthroughplayer.plugin

import java.nio.ByteBuffer
import java.nio.ByteOrder
import org.junit.Assert.*
import org.junit.Test

class PortraitDepthGeometryTest {
    private fun mask(bounds: FloatArray = floatArrayOf(.25f,.125f,.625f,.875f), hole: Boolean = false,
                     rect: FloatArray = floatArrayOf(0f,0f,1f,1f)): PortraitDepthGeometry.Mask {
        val bytes = ByteBuffer.allocateDirect(64*64)
        for (y in 0..63) for (x in 0..63) {
            val u=((x+.5f)/64-rect[0])/rect[2]; val v=((y+.5f)/64-rect[1])/rect[3]
            bytes.put(y*64+x,if (u in bounds[0]..bounds[2] && v in bounds[1]..bounds[3] &&
                !(hole && u in .4f.. .5f && v in .35f.. .55f)) 255.toByte() else 0)
        }
        return PortraitDepthGeometry.Mask(bytes,rect,bounds)
    }
    private fun map(mask: PortraitDepthGeometry.Mask = mask()) = PortraitDepthGeometry.Map(10,1_000_000,2,
        PortraitDepthGeometry.Crop(floatArrayOf(0f,0f,1f,1f),intArrayOf(0,0,64,64)),mask,64,64,FloatArray(4096){.4f})
    @Test fun cropPreservesPixelsAndLetterbox() {
        val bounds = floatArrayOf(.4f,.1f,.6f,.9f)
        val crop = PortraitDepthGeometry.crop(bounds,1920,1080,364,210)
        assertTrue(crop.content[2] < 364); assertEquals(210,crop.content[3])
        val r = crop.rect
        assertEquals(1920f/1080, r[2]*364/(r[3]*210),.02f)
        for (i in 0..3) {
            val axis=i%2; val uv=r[axis]+bounds[i]*r[axis+2]
            assertTrue(uv in 0f..1f)
        }
    }
    @Test fun rejectsOtherShotFutureExpiredAndScaleJump() {
        val map=map(); val current=mask()
        assertNull(PortraitDepthGeometry.align(map,current,11,1_100_000,3))
        assertNull(PortraitDepthGeometry.align(map,current,9,1_100_000,2))
        assertNull(PortraitDepthGeometry.align(map,current,11,999_999,2))
        assertNull(PortraitDepthGeometry.align(map,current,11,1_750_001,2))
        assertNull(PortraitDepthGeometry.align(map,mask(floatArrayOf(.4f,.4f,.5f,.5f)),11,1_100_000,2))
        assertNotNull(PortraitDepthGeometry.align(map,current,10,1_000_000,2))
    }
    @Test fun alignsTranslationAndFadesWithAge() {
        val moved = mask(floatArrayOf(.35f,.125f,.725f,.875f))
        val fresh=PortraitDepthGeometry.align(map(),moved,11,1_100_000,2)!!
        val old=PortraitDepthGeometry.align(map(),moved,12,1_700_000,2)!!
        val center=32*64+34
        assertTrue((fresh.get(center).toInt() and 255)>180)
        assertTrue((old.get(center).toInt() and 255) < (fresh.get(center).toInt() and 255))
        assertEquals(128,fresh.get(5*64+5).toInt() and 255)
    }
    @Test fun newlyCoveredAlphaUsesBaseAndDiscontinuitiesAreBounded() {
        val result=PortraitDepthGeometry.align(map(mask(hole=true)),mask(),11,1_100_000,2)!!
        assertEquals(128,result.get(28*64+28).toInt() and 255)
        var maximum=0
        for (y in 0..63) for (x in 0..62) maximum=maxOf(maximum,kotlin.math.abs(
            (result.get(y*64+x).toInt() and 255)-(result.get(y*64+x+1).toInt() and 255)))
        assertTrue("Residual slope $maximum",maximum<=22)
    }
    @Test fun foregroundCenterDoesNotSetVirtualDistance() {
        val near=ByteBuffer.allocateDirect(64*64*4).order(ByteOrder.LITTLE_ENDIAN)
        for (y in 0..63) for (x in 0..63) near.putFloat((y*64+x)*4,x/63f)
        val crop=PortraitDepthGeometry.Crop(floatArrayOf(0f,0f,1f,1f),intArrayOf(0,0,64,64))
        val residual=PortraitDepthGeometry.residual(near,64,64,crop,mask())
        assertTrue(residual[32*64+36]>0); assertTrue(residual[32*64+18]<0)
        assertTrue(residual.all { it.isFinite() && it in -.5f.. .5f })
    }
    @Test fun changingRvmCropDoesNotMoveTheDepthCoordinates() {
        val bounds=floatArrayOf(.3f,.3f,.6f,.7f)
        val old=mask(bounds,rect=floatArrayOf(-.25f,-.25f,1.5f,1.5f))
        val current=mask(bounds,rect=floatArrayOf(0f,.125f,1f,.75f))
        val result=PortraitDepthGeometry.align(map(old),current,11,1_100_000,2)!!
        assertTrue((result.get(32*64+28).toInt() and 255)>180)
        assertEquals(128,result.get(3*64+28).toInt() and 255)
    }
    @Test fun signedDepthCliffsCannotStretchAcrossAnUnboundedStep() {
        val base=map()
        val cliff=base.copy(residual=FloatArray(4096) { if (it%64<28) .5f else -.5f })
        val result=PortraitDepthGeometry.align(cliff,mask(),11,1_100_000,2)!!
        for (i in 0 until 4096) {
            val value=result.get(i).toInt() and 255
            if (i%64<63) assertTrue(kotlin.math.abs(value-(result.get(i+1).toInt() and 255))<=22)
            if (i+64<4096) assertTrue(kotlin.math.abs(value-(result.get(i+64).toInt() and 255))<=22)
        }
    }
}
