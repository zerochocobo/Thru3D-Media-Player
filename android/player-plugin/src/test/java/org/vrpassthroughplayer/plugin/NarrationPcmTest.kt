package org.vrpassthroughplayer.plugin

import org.junit.Assert.*
import org.junit.Test
import kotlin.math.PI
import kotlin.math.abs
import kotlin.math.sin

class NarrationPcmTest {
    private fun tone(seconds: Double): FloatArray = FloatArray((48000*seconds).toInt()*2) { (.1*sin(2*PI*440*(it/2)/48000)).toFloat() }
    @Test fun normalSpeedKeepsApprovedSamplesExactly() {
        val input=tone(.5);val pcm=NarrationPcm(1.0)
        pcm.update(listOf(input),true)
        assertTrue(pcm.done);assertSame(input,pcm.chunks.single());assertEquals(input.size,pcm.samples)
        pcm.close()
    }
    @Test fun longSpeechFitsItsWindowAndPitchIsPreserved() {
        val input=tone(6.72);val pcm=NarrationPcm(1.2)
        pcm.update(listOf(input),true)
        val output=pcm.chunks.flatMap { it.toList() }
        val duration=pcm.samples/96000.0
        assertTrue(abs(duration-5.6)<.04)
        var crossings=0
        for(i in 2 until output.size step 2)if(output[i-2]<=0&&output[i]>0)crossings++
        assertTrue(abs(crossings/duration-440)<15)
        assertTrue(output.all { it.isFinite()&&abs(it)<=1f });assertTrue(pcm.done)
        pcm.close()
    }
    @Test fun streamingChunksCanSlowDownAndFlushTheTail() {
        val source=mutableListOf<FloatArray>();val pcm=NarrationPcm(.8)
        repeat(50) { source+=tone(.02);pcm.update(source,false) }
        pcm.update(source,true)
        assertTrue(pcm.done);assertTrue(abs(pcm.samples/96000.0-1.25)<.04)
        val count=pcm.samples;pcm.update(source,true);assertEquals(count,pcm.samples)
        pcm.close()
    }
    @Test fun maximumAdmittedSixSecondSentenceLeavesRoomForTheNextCue() {
        // Full production Sonic processing, including its EOS tail, must fit.
        // The old 1.3x cap needs over six seconds for 7.84 seconds of speech.
        val pcm=NarrationPcm(8.0/5.75)
        pcm.update(listOf(tone(8.0)),true)
        assertTrue(pcm.done)
        assertTrue(pcm.samples/96000.0<5.80)
        pcm.close()
    }
    @Test fun onlyOuterQuietPaddingIsRemovedAcrossChunkBoundaries() {
        val speech=tone(.5)
        val source=listOf(FloatArray(38400),speech,FloatArray(57600))
        val trimmed=NarrationPcm.trimOuterSilence(source)
        assertTrue(abs(trimmed.sumOf {it.size}/96000.0-.66)<.02)
        assertTrue(trimmed.any {it===speech}) // Spoken waveform is shared unchanged.
    }
    @Test fun internalPausesAndUnpaddedSpeechStayUnchanged() {
        val unpadded=listOf(tone(.25))
        assertSame(unpadded,NarrationPcm.trimOuterSilence(unpadded))
        val pause=FloatArray(28800)
        val trimmed=NarrationPcm.trimOuterSilence(listOf(FloatArray(19200),tone(.1),pause,tone(.1),FloatArray(19200)))
        assertTrue(trimmed.any {it===pause})
        assertTrue(abs(trimmed.sumOf {it.size}/96000.0-.66)<.02)
        assertTrue(runCatching {NarrationPcm.trimOuterSilence(listOf(floatArrayOf(Float.NaN,0f)))}.isFailure)
    }
    @Test fun denseSubtitleCatchupKeepsPitchAtItsMaximumTempo() {
        for(tempo in listOf(1.5,2.0)) {
        val pcm=NarrationPcm(tempo);pcm.update(listOf(tone(2.7)),true)
        val output=pcm.chunks.flatMap {it.toList()};val duration=pcm.samples/96000.0
        var crossings=0
        for(i in 2 until output.size step 2)if(output[i-2]<=0&&output[i]>0)crossings++
        assertTrue(abs(duration-2.7/tempo)<.04);assertTrue(abs(crossings/duration-440)<20)
        assertTrue(output.all {it.isFinite()&&abs(it)<=1f});pcm.close()
        }
    }
    @Test fun completedStreamingTailAcceleratesWithoutReplayingSubmittedPrefix() {
        val prefix=FloatArray(19200){.9f};val tail=tone(.9)
        val source=NarrationPcm(1.0);source.update(listOf(prefix,tail),true);source.cursor=prefix.size
        val remaining=source.remaining()
        assertSame(tail,remaining.single())
        val faster=NarrationPcm(1.5);faster.update(remaining,true);source.close()
        assertTrue(abs(faster.samples/96000.0-.6)<.04)
        assertTrue(faster.chunks.all {it.all {value -> abs(value)<.2f}})
        assertTrue(faster.done);faster.close()
    }
}
