package org.vrpassthroughplayer.plugin

import org.junit.Assert.*
import org.junit.Test

class TextProtectionTransitionTest {
    private val line=TextProtectionPolicy.Box(.2f,.8f,.8f,.85f)
    @Test fun lateDetectionStartsAtCurrentRenderTimeWithoutOneFrameJump() {
        val transition=TextProtectionTransition()
        assertEquals(0f,transition.sample(listOf(line),5000).weights.single(),0f)
        var previous=0f
        for(t in 5016L..5240L step 16) {
            val state=transition.sample(listOf(line),t)
            val weight=state.weights.single()
            assertTrue(weight>=previous&&weight-previous<.11f)
            previous=weight
        }
        val finished=transition.sample(listOf(line),5240)
        assertEquals(1f,finished.weights.single(),0f);assertFalse(finished.animating)
    }
    @Test fun shortSubtitleGapKeepsPlaneAndRealDisappearanceFadesOut() {
        val t=TextProtectionTransition();t.sample(listOf(line),0);t.sample(listOf(line),300)
        assertEquals(1f,t.sample(emptyList(),310).weights.single(),0f)
        assertEquals(1f,t.sample(listOf(line),450).weights.single(),0f)
        t.sample(emptyList(),500)
        assertEquals(.5f,t.sample(emptyList(),860).weights.single(),1e-6f)
        assertTrue(t.sample(emptyList(),1020).regions.isEmpty())
    }
    @Test fun rectangleChangesMoveContinuouslyInsteadOfChangingSamplingInOneFrame() {
        val t=TextProtectionTransition();t.sample(listOf(line),0);t.sample(listOf(line),300)
        val changed=line.copy(x0=.1f,x1=.9f)
        val start=t.sample(listOf(changed),400)
        assertEquals(.2f,start.regions[0],0f)
        val middle=t.sample(listOf(changed),490)
        assertEquals(.15f,middle.regions[0],1e-6f)
        assertEquals(.1f,t.sample(listOf(changed),580).regions[0],0f)
    }
    @Test fun seekResetAndBackwardsClockCannotCarryOldMasks() {
        val t=TextProtectionTransition();t.sample(listOf(line),1000);t.sample(listOf(line),1300)
        t.reset();assertTrue(t.sample(emptyList(),2000).regions.isEmpty())
        t.sample(listOf(line),2100);assertTrue(t.sample(emptyList(),100).regions.isEmpty())
    }
    @Test fun aNewLineDoesNotUnprotectAnAlreadyStableLine() {
        val t=TextProtectionTransition();t.sample(listOf(line),0);t.sample(listOf(line),300)
        val top=line.copy(y0=.1f,y1=.15f)
        val state=t.sample(listOf(line,top),400)
        assertArrayEquals(floatArrayOf(1f,0f),state.weights,0f)
        val middle=t.sample(listOf(line,top),520)
        assertArrayEquals(floatArrayOf(1f,.5f),middle.weights,1e-6f)
    }
    @Test fun confidenceUpdatesDoNotRestartAnimationAndFullCapacityEventuallyAcceptsNewTargets() {
        val t=TextProtectionTransition();t.sample(listOf(line),0)
        assertEquals(.5f,t.sample(listOf(line.copy(score=.8f)),120).weights.single(),1e-6f)
        t.reset()
        val old=(0..7).map { line.copy(y0=.01f+it*.1f,y1=.03f+it*.1f) }
        val fresh=old.map { it.copy(y0=it.y0+.05f,y1=it.y1+.05f) }
        t.sample(old,0);t.sample(old,300);t.sample(fresh,400)
        val accepted=t.sample(fresh,920)
        assertEquals(8,accepted.weights.size)
        assertEquals(fresh.first().y0,accepted.regions[1],0f)
        assertTrue(t.sample(fresh,1200).weights.all { it==1f })
    }
}
