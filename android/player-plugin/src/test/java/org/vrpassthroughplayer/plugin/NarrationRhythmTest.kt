package org.vrpassthroughplayer.plugin

import org.junit.Assert.*
import org.junit.Test
import kotlin.math.PI
import kotlin.math.abs
import kotlin.math.sin

class NarrationRhythmTest {
    private fun tone(seconds: Double,hz: Int=220,gain: Double=.1)=FloatArray((seconds*48000).toInt()*2){(gain*sin(2*PI*hz*(it/2)/48000)).toFloat()}
    private data class Result(val pcm: FloatArray,val stats: NarrationRhythm.Stats)
    private fun process(source: FloatArray,text: String="这是一段连续朗读的字幕。",size: Int=30_720): Result {
        val output=ArrayList<FloatArray>();val rhythm=NarrationRhythm(text,"zh"){output+=it}
        source.asList().chunked(size).forEach {rhythm.append(it.toFloatArray())};rhythm.finish()
        val result=Result(output.flatMap {it.asList()}.toFloatArray(),rhythm.stats);rhythm.close();return result
    }
    @Test fun longPauseAndSlowOpeningAreLocalAndTheBodyIsSampleExact() {
        val first=tone(.6);val body=tone(1.4,440)
        val input=first+FloatArray(96000)+body
        val result=process(input,"你好，很高兴为您提供字幕朗读服务。")
        assertEquals(67200,result.stats.removedPauseSamples)
        assertTrue(result.stats.removedDragSamples>0);assertEquals(1.25,result.stats.localTempo,.001)
        assertArrayEquals(body,result.pcm.copyOfRange(result.pcm.size-body.size,result.pcm.size),0f)
        val firstSize=first.size-result.stats.removedDragSamples
        var crossings=0
        for(i in 2 until firstSize step 2)if(result.pcm[i-2]<=0&&result.pcm[i]>0)crossings++
        assertTrue(abs(crossings/(firstSize/96000.0)-220)<15)
        assertTrue(result.pcm.all {it.isFinite()&&abs(it)<.2})
        assertTrue(abs(result.pcm.size/96000.0-(.48+.30+1.4))<.03)
    }
    @Test fun normalOpeningAndShortConsonantGapsAreUnchanged() {
        val input=tone(.36)+FloatArray(19200)+tone(.8,440)
        val result=process(input,"你好，很高兴为您提供字幕朗读服务。")
        assertArrayEquals(input,result.pcm,0f);assertEquals(0,result.stats.removedDragSamples);assertEquals(0,result.stats.removedPauseSamples)
    }
    @Test fun quietRoomNoiseDoesNotTurnANormalGreetingIntoSlowSpeech() {
        val random=java.util.Random(14)
        val room=FloatArray(96000){(random.nextFloat()-.5f)*.002f}
        val result=process(tone(.36)+room+tone(.8,440),"你好，很高兴为您服务。")
        assertEquals(0,result.stats.removedDragSamples)
        assertEquals(1.0,result.stats.localTempo,0.0)
        assertTrue(result.stats.removedPauseSamples>0)
    }
    @Test fun continuousSpeechIsNeverBlanketAcceleratedEvenWhenTextHasAnOpeningComma() {
        val input=tone(3.5)
        val result=process(input,"你好，很高兴为您提供字幕朗读服务。")
        assertArrayEquals(input,result.pcm,0f);assertEquals(1.0,result.stats.localTempo,0.0)
    }
    @Test fun weakSpeechAndAudibleBackgroundAreNotSilence() {
        val input=tone(.4)+tone(.9,330,.003)+tone(.4,440)
        assertArrayEquals(input,process(input).pcm,0f)
        val faint=tone(.4)+tone(.9,220,.0008)+tone(.4,440)
        assertArrayEquals(faint,process(faint).pcm,0f)
        val noise=java.util.Random(7).let {r->FloatArray(96000){(r.nextFloat()-.5f)*.008f}}
        val noisy=tone(.4)+noise+tone(.4)
        assertArrayEquals(noisy,process(noisy).pcm,0f)
    }
    @Test fun allSilenceAndAnUnpunctuatedFastSentenceStayIntact() {
        val silence=FloatArray(96000*3)
        assertArrayEquals(silence,process(silence,"你好。").pcm,0f)
        val fast=tone(.8)
        assertArrayEquals(fast,process(fast,"你好，很高兴为您服务。").pcm,0f)
    }
    @Test fun processingIsIndependentOfDecoderChunkBoundaries() {
        val source=tone(.6)+FloatArray(96000)+tone(.8,440)+FloatArray(19200)+tone(.2)
        val expected=process(source,"你好，很高兴为您服务。")
        val small=process(source,"你好，很高兴为您服务。",218)
        assertArrayEquals(expected.pcm,small.pcm,0f)
    }
    @Test fun outputStartsBeforeEosAndHeldPayloadIsBounded() {
        var output=0;val rhythm=NarrationRhythm("你好，很高兴为您服务。","zh"){output+=it.size}
        rhythm.append(tone(.6));assertEquals(0,output)
        rhythm.append(FloatArray(48000));assertTrue(output>=38400)
        repeat(50){rhythm.append(FloatArray(30720))}
        rhythm.append(tone(2.0));rhythm.finish()
        assertTrue(rhythm.stats.maxBufferedSamples<200000)
        assertTrue(rhythm.stats.removedPauseSamples>96000*10)
        rhythm.close()
    }
    @Test fun localAndSubtitleCatchupTogetherStayWithinTheApprovedCeiling() {
        for(local in listOf(1.0,1.15,1.25))for(global in listOf(.8,1.0,1.5,1.8,2.0))
            assertTrue(NarrationRhythm.presentationTempo(global,local)*local<=1.800001)
        assertEquals(1.8,NarrationRhythm.presentationTempo(1.8,1.0),0.0)
        assertEquals(1.0,NarrationRhythm.presentationTempo(1.0,1.25),0.0)
    }
    @Test fun stereoIsKeptAndNonfiniteAudioFailsWithoutPoisoningOutput() {
        val input=tone(.4).also {for(i in 1 until it.size step 2)it[i]*=.5f}
        val result=process(input)
        assertArrayEquals(input,result.pcm,0f)
        assertThrows(IllegalArgumentException::class.java){process(FloatArray(960){Float.NaN})}
    }
}
