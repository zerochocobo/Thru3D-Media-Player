package org.vrpassthroughplayer.plugin

import org.junit.Assert.*
import org.junit.Test

class TextProtectionPolicyTest {
    private fun box(x: Float=.2f,y: Float=.8f,w: Float=.6f,h: Float=.05f,score: Float=.9f)=TextProtectionPolicy.Box(x,y,x+w,y+h,score)
    @Test fun lineMergingAndNoise() {
        val rows=TextProtectionPolicy.lines(listOf(box(w=.2f),box(x=.42f,w=.3f),box(y=.9f),box(h=.2f),box(score=.1f)))
        assertEquals(2,rows.size)
        assertTrue(rows.any { it.x0==.2f&&it.x1>.7f })
        assertTrue(TextProtectionPolicy.lines(listOf(box(x=Float.NaN))).isEmpty())
    }
    @Test fun stationaryCentreRequiresConfirmationAndMovingTextIsRejected() {
        val t=TextProtectionPolicy.Tracker()
        assertTrue(t.update(listOf(box(y=.4f))).isEmpty())
        assertEquals(1,t.update(listOf(box(y=.4f))).size)
        assertTrue(t.update(listOf(box(x=.01f,y=.1f,w=.025f,h=.03f))).isEmpty())
        assertTrue(t.update(emptyList()).isEmpty())
        t.reset();assertTrue(t.regions.isEmpty())
    }
    @Test fun stableSubtitleDoesNotGrowOnEveryDetection() {
        val t=TextProtectionPolicy.Tracker();val line=box()
        t.update(listOf(line));val first=t.update(listOf(line))
        repeat(100) { assertEquals(first,t.update(listOf(line))) }
        assertEquals(4,TextProtectionPolicy.flatten(t.regions).size)
    }
    @Test fun croppedCoordinatesRoundTripAndAspectIsBounded() {
        val crop=TextProtectionPolicy.Crop(.1f,.7f,.8f,.2f)
        val b=crop.map(TextProtectionPolicy.Box(0f,0f,1f,1f))
        assertEquals(.1f,b.x0,1e-6f);assertEquals(.9f,b.y1,1e-6f)
        val rect=crop.content()
        assertEquals(0f,rect[1]+crop.y*rect[3],1e-6f)
        assertEquals(1f,rect[0]+(crop.x+crop.w)*rect[2],1e-6f)
        for((w,h) in listOf(1920 to 1080,1080 to 1920,4000 to 10,10 to 4000)) {
            val (dw,dh)=TextProtectionPolicy.dimensions(w,h)
            assertTrue(dw in 32..640&&dh in 32..640&&dw%32==0&&dh%32==0)
        }
    }
    @Test fun staleFutureSeekAndGenerationBoundaries() {
        assertTrue(TextProtectionPolicy.current(100,100))
        assertFalse(TextProtectionPolicy.current(200,100))
        assertFalse(TextProtectionPolicy.current(100,1_000_001))
        assertFalse(TextProtectionPolicy.current(-1,100))
        assertTrue(TextProtectionPolicy.discontinuity(200,100))
        assertTrue(TextProtectionPolicy.discontinuity(0,2_000_000))
        assertFalse(TextProtectionPolicy.discontinuity(100,200))
    }
    @Test fun boundedRegionsAndLocalCrop() {
        val t=TextProtectionPolicy.Tracker();assertNull(t.crop())
        t.update(listOf(box()));assertNotNull(t.crop())
        val many=(0..30).map { box(y=.01f+it*.03f,h=.01f) }
        assertTrue(TextProtectionPolicy.lines(many).size<=TextProtectionPolicy.MAX_REGIONS)
    }
    @Test fun localEdgesIgnoreSmallNoiseButReactToChangedGlyphs() {
        val still=FloatArray(128) { .1f }
        assertFalse(TextProtectionPolicy.edgeChanged(null,still))
        assertFalse(TextProtectionPolicy.edgeChanged(still,FloatArray(128) { .11f }))
        assertTrue(TextProtectionPolicy.edgeChanged(still,FloatArray(128) { if(it%2==0).5f else .1f }))
    }
}
