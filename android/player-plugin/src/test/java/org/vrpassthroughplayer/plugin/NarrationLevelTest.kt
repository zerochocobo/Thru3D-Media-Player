package org.vrpassthroughplayer.plugin

import org.junit.Assert.*
import org.junit.Test
import kotlin.math.*

class NarrationLevelTest {
    private fun tone(seconds: Double,amplitude: Double)=FloatArray((seconds*48000).roundToInt()*2){(amplitude*sin(2*PI*220*(it/2)/48000)).toFloat()}
    private fun rms(x: FloatArray)=sqrt(x.sumOf {it.toDouble()*it}/x.size)
    private fun process(x: FloatArray,block: Int=30720): FloatArray {
        val output=ArrayList<FloatArray>();NarrationLevel {output+=it}.use {level->
            var at=0;while(at<x.size){val end=minOf(at+block,x.size);level.append(x.copyOfRange(at,end));at=end};level.finish()
            assertTrue(level.stats.maxBufferedSamples<=160000)}
        val result=FloatArray(output.sumOf {it.size});var at=0;output.forEach {it.copyInto(result,at);at+=it.size};return result
    }
    @Test fun differentSentenceLevelsConvergeWithoutChangingDuration() {
        val outputs=listOf(.025,.06,.25,.65).map {a->val x=tone(2.0,a);val y=process(x);assertEquals(x.size,y.size);rms(y)}
        assertTrue(20*log10(outputs.max()/outputs.min())<.2)
        assertEquals(.1,outputs.average(),.003)
    }
    @Test fun chunkBoundariesCannotChangeSoundAndStereoBalanceIsPreserved() {
        val x=tone(2.3,.06);for(i in 1 until x.size step 2)x[i]*=.5f
        val a=process(x,640);val b=process(x,30720)
        assertArrayEquals(a,b,0f)
        for(i in a.indices step 2)assertEquals(a[i]*.5f,a[i+1],1e-6f)
    }
    @Test fun isolatedLoudPeaksCannotClipAfterWeakSpeechWasAmplified() {
        val x=tone(2.0,.025);x[96000]=.99f;x[96001]=-.99f
        val y=process(x);assertTrue(y.maxOf {abs(it)}<=.94001f)
        assertTrue(y.all {it.isFinite()});assertEquals(x.size,y.size)
    }
    @Test fun withinSentenceStressRemainsAndSilenceStaysSilent() {
        val x=tone(2.0,.1);for(i in 96000 until 115200)x[i]*=.5f
        val y=process(x);val before=rms(y.copyOfRange(76800,96000));val soft=rms(y.copyOfRange(96000,115200))
        assertTrue(soft/before in .48.. .55)
        assertArrayEquals(FloatArray(96000),process(FloatArray(96000)),0f)
    }
    @Test fun boundedLeadEmitsBeforeTheSentenceEnds() {
        var count=0;val level=NarrationLevel {count+=it.size}
        level.append(tone(1.28,.1));assertTrue(count>=38400);level.close()
    }
    @Test fun quietPrerollCannotSetTheGainOfFollowingSpeech() {
        val quiet=FloatArray(153600){.0001f};val speech=tone(1.0,.14)
        val result=process(quiet+speech)
        assertEquals(quiet.size+speech.size,result.size)
        assertEquals(.1,rms(result.copyOfRange(quiet.size,result.size)),.003)
    }
    @Test fun referenceIsConditionedOnceWithPeakHeadroomAndNoDc() {
        val source=tone(3.0,.12);for(i in source.indices)source[i]+=.1f
        val before=source.copyOf();val result=VoiceReferencePcm.prepare(source)
        assertArrayEquals(before,source,0f);assertEquals(source.size,result.pcm.size)
        assertEquals(-20.0,result.outputDb,.15)
        assertTrue(abs(result.pcm.average())<.001)
        assertTrue(result.pcm.maxOf {abs(it)}<=.708f)
        assertTrue(VoiceReferencePcm.prepare(tone(3.0,.01)).gainDb<=6.00001)
    }
    @Test fun silentReferencesAreRejectedInsteadOfAmplifyingTheNoiseFloor() {
        assertThrows(IllegalArgumentException::class.java){VoiceReferencePcm.prepare(FloatArray(288000))}
        assertThrows(IllegalArgumentException::class.java){VoiceReferencePcm.prepare(tone(3.0,.0001))}
    }
    @Test fun aReferenceWithLargeTransientPeaksUsesTheConservativeTarget() {
        val source=tone(3.0,.05);source[96000]=.65f;source[96001]=.65f
        val result=VoiceReferencePcm.prepare(source)
        assertTrue(result.crestDb>18);assertEquals(-23.0,result.targetDb,0.0)
        assertTrue(result.gainDb<=6.00001);assertTrue(result.pcm.maxOf {abs(it)}<=.708f)
    }
}
