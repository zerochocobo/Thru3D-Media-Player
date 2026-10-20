package org.vrpassthroughplayer.plugin

import org.junit.Assert.*
import org.junit.Test

class HeardPcmTest {
    private data class Chunk(val pcm: FloatArray,val ns: Long,val gain: Float)
    @Test fun outputOnlyContainsPresentedFramesAndNotQueuedOrDiscardedSpeech() {
        val saved=ArrayList<Chunk>()
        val heard=HeardPcm {pcm,count,ns,gain->saved+=Chunk(pcm.copyOf(count),ns,gain)}
        heard.write(FloatArray(4800*2){it/9600f},0,4800*2)
        val now=10_000_000_000L
        heard.present(480,now,now,0.25f,true)
        assertEquals(960,saved.sumOf{it.pcm.size}) // 10 ms heard, 90 ms still queued.
        assertEquals(0.25f,saved.first().gain,0f)
        assertEquals(now-10_000_000,saved.first().ns)
        heard.reset() // The next subtitle interrupted this one; no queued tail may escape.
        assertEquals(960,saved.sumOf{it.pcm.size})
    }
    @Test fun startingMidSentenceSkipsAlreadyHeardFramesAndHonorsPartialWrites() {
        val saved=ArrayList<Chunk>();val heard=HeardPcm{pcm,count,ns,gain->saved+=Chunk(pcm.copyOf(count),ns,gain)}
        val input=FloatArray(6000){it.toFloat()}
        heard.write(input,200,2000)
        val now=10_000_000_000L
        heard.present(400,now,now,1f,false)
        heard.present(600,now+4_166_667,now+4_166_667,1f,true)
        assertEquals(400,saved.sumOf{it.pcm.size})
        assertEquals(1000f,saved.first().pcm.first(),0f)
        assertEquals(1399f,saved.last().pcm.last(),0f)
    }
    @Test fun pauseDoesNotReplayFramesAndFutureCommittedTimestampsAreNotHeardYet() {
        var samples=0;val heard=HeardPcm{_,count,_,_->samples+=count}
        heard.write(FloatArray(4000){.5f},0,4000)
        val now=10_000_000_000L
        heard.present(960,now+10_000_000,now,1f,true)
        assertEquals(960,samples) // Frame 960 is committed for the future: only 480 are heard.
        repeat(4){heard.present(480,now,now,1f,true)}
        assertEquals(960,samples)
        heard.present(960,now+10_000_000,now+10_000_000,1f,true)
        assertEquals(1920,samples)
    }
    @Test fun submittedPcmIsRetainedByReferenceAndCanSpanTempoOutputChanges() {
        val values=ArrayList<Float>();val heard=HeardPcm{pcm,count,_,_->values.addAll(pcm.take(count))}
        heard.write(floatArrayOf(.1f,.2f,.3f,.4f),0,4)
        heard.write(floatArrayOf(.8f,.9f),0,2)
        heard.present(3,10_000_000_000,10_000_000_000,0f,true)
        assertEquals(listOf(.1f,.2f,.3f,.4f,.8f,.9f),values)
    }
    @Test fun timestampJitterNeverCutsHolesOrOverlapsInContinuousPlayedSamples() {
        val saved=ArrayList<Chunk>();val heard=HeardPcm{pcm,count,ns,gain->saved+=Chunk(pcm.copyOf(count),ns,gain)}
        heard.write(FloatArray(96000){.2f},0,96000)
        val origin=10_000_000_000L
        for(part in 1..100) {
            val frame=part*480L
            val jitter=if(part==1)0L else ((part*37)%31-15)*20_000L
            val timestamp=origin+frame*1_000_000_000/48000+jitter
            heard.present(frame,timestamp,timestamp,1f,true)
        }
        var next=origin
        for(chunk in saved) {
            assertEquals("A fresh timestamp must not move an adjacent PCM block",next,chunk.ns)
            next=chunk.ns+chunk.pcm.size/2*1_000_000_000L/48000
        }
        assertEquals(96000,saved.sumOf{it.pcm.size})
    }
    @Test fun aBackwardClockEstimateNeverReplaysAlreadyHeardSamples() {
        val saved=ArrayList<Chunk>();val heard=HeardPcm{pcm,count,ns,gain->saved+=Chunk(pcm.copyOf(count),ns,gain)}
        heard.write(FloatArray(4000){it.toFloat()},0,4000)
        val ns=10_000_000_000L
        heard.present(960,ns,ns,1f,true)
        heard.present(900,ns,ns,1f,true)
        heard.present(1000,ns,ns,1f,true)
        assertEquals(2000,saved.sumOf{it.pcm.size})
        assertEquals((0 until 2000).map{it.toFloat()},saved.flatMap{it.pcm.toList()})
    }
    @Test fun realPauseOrUnderrunReanchorsWithoutFillingTheHeardGap() {
        val saved=ArrayList<Chunk>();val heard=HeardPcm{pcm,count,ns,gain->saved+=Chunk(pcm.copyOf(count),ns,gain)}
        heard.write(FloatArray(1920){.2f},0,1920)
        val origin=10_000_000_000L
        heard.present(480,origin+10_000_000,origin+10_000_000,1f,true)
        heard.discontinuity()
        heard.present(960,origin+120_000_000,origin+120_000_000,1f,true)
        assertEquals(origin,saved[0].ns)
        assertEquals(origin+110_000_000,saved[1].ns)
        assertEquals(1920,saved.sumOf{it.pcm.size})
    }
}
