package org.vrpassthroughplayer.plugin

import java.nio.ByteBuffer
import kotlin.random.Random
import org.junit.Assert.*
import org.junit.Test

class PortraitShotDetectorTest {
    private val w = PortraitShotDetector.WIDTH
    private val h = PortraitShotDetector.HEIGHT
    private fun picture(seed: Int): ByteBuffer {
        val random = Random(seed)
        return ByteBuffer.allocateDirect(w*h*4).apply {
            for (i in 0 until w*h) { for (c in 0..2) put(i*4+c,random.nextInt(30,200).toByte()); put(i*4+3,255.toByte()) }
        }
    }
    private fun transform(a: ByteBuffer, fn: (Int,Int,Int)->Int): ByteBuffer = ByteBuffer.allocateDirect(w*h*4).apply {
        for (y in 0 until h) for (x in 0 until w) for (c in 0..2) put((y*w+x)*4+c,fn(x,y,c).coerceIn(0,255).toByte())
    }
    private fun pixel(a: ByteBuffer,x: Int,y: Int,c: Int) = a.get((y.coerceIn(0,h-1)*w+x.coerceIn(0,w-1))*4+c).toInt() and 255
    @Test fun cutsWithSameHistogramAndBounds() {
        val detector = PortraitShotDetector(); val a = picture(5)
        assertTrue(detector.observe(a,0).cut)
        val b = transform(a) { x,y,c -> pixel(a,w-1-x,h-1-y,c) }
        val cut = detector.observe(b,33_333)
        assertEquals("hard",cut.reason); assertEquals(2L,cut.shot)
        assertFalse(detector.observe(b,66_666).cut)
    }
    @Test fun motionExposureAndLocalMovementDoNotCut() {
        val a = picture(9)
        for (b in listOf(transform(a) { x,y,c -> pixel(a,x+2,y+1,c) },
            transform(a) { x,y,c -> (pixel(a,x,y,c)*1.15+10).toInt() },
            transform(a) { x,y,c -> if (x in 17..23 && y in 9..16) 230 else pixel(a,x,y,c) })) {
            val detector = PortraitShotDetector(); detector.observe(a,0)
            val result = detector.observe(b,33_333)
            assertFalse(result.toString(),result.cut)
        }
    }
    @Test fun equalLuminanceColourCutIsNotExposure() {
        val a = transform(picture(1)) { _,_,c -> if (c==0) 180 else 40 }
        val b = transform(a) { _,_,c -> if (c==2) 180 else 40 }
        val detector = PortraitShotDetector(); detector.observe(a,0)
        assertTrue(detector.observe(b,33_333).cut)
    }
    @Test fun warmedMotionBaselineStillIgnoresSmallObjectsAndExposure() {
        val a=picture(42)
        for (kind in 0..2) {
            val detector=PortraitShotDetector()
            for (i in 0..8) assertEquals(1L,detector.observe(a,i*33_333L).shot)
            val b=transform(a) { x,y,c -> when (kind) {
                0 -> if (x in 17..23 && y in 9..16) 230 else pixel(a,x,y,c)
                1 -> (pixel(a,x,y,c)*1.15+10).toInt()
                else -> pixel(a,x+2,y+1,c)
            } }
            assertFalse(detector.observe(b,300_000).cut)
            assertFalse(detector.observe(a,333_333).cut)
        }
    }
    @Test fun lowContrastCutUsesStructureAndCompressionNoiseDoesNot() {
        val first=picture(4); val second=picture(18)
        val a=transform(first) { x,y,c -> (128+(pixel(first,x,y,c)-128)*.4).toInt() }
        val b=transform(second) { x,y,c -> (128+(pixel(second,x,y,c)-128)*.4).toInt() }
        val detector=PortraitShotDetector(); detector.observe(a,0)
        val noisy=transform(a) { x,y,c -> pixel(a,x,y,c)+(if ((x+y)%2==0) 3 else -3) }
        assertFalse(detector.observe(noisy,33_333).cut)
        assertTrue(detector.observe(b,66_666).cut)
    }
    @Test fun flashAndPausedRedrawKeepShot() {
        val a = picture(2); val detector = PortraitShotDetector(); detector.observe(a,0)
        assertEquals("flash",detector.observe(transform(a) { _,_,_ -> 255 },33_333).reason)
        assertFalse(detector.observe(a,66_666).cut)
        assertFalse(detector.observe(a,66_666).cut)
        assertEquals(1L,detector.observe(a,99_999).shot)
    }
    @Test fun dissolveAndTimelineDiscontinuitiesInvalidate() {
        val a = picture(3); val b = picture(21); val detector = PortraitShotDetector(); detector.observe(a,0)
        var cuts = 0
        for (i in 1..8) {
            val mix = transform(a) { x,y,c -> ((pixel(a,x,y,c)*(8-i)+pixel(b,x,y,c)*i)/8) }
            if (detector.observe(mix,i*50_000L).cut) cuts++
        }
        assertTrue("Gradual transition must invalidate depth",cuts>0)
        assertEquals("timeline",detector.observe(b,10).reason)
        assertEquals("timeline",detector.observe(b,2_000_000).reason)
    }
}
