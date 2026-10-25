package org.vrpassthroughplayer.plugin

import kotlin.math.abs
import kotlin.math.sqrt

/** Bounded playback copy: retain weak edges, shorten only confidently quiet long
 * gaps and gently pace an identifiable short opening clause. Never edits a voice
 * or its raw disk cache, and never applies a blanket utterance speed. */
internal class NarrationRhythm(text: String, language: String, fastStart: Boolean=false, private val emit: (FloatArray)->Unit) {
    companion object {
        const val FRAME_SAMPLES=960 // 10 ms, 48 kHz stereo
        const val BLOCK_SAMPLES=30_720
        const val LONG_GAP_FRAMES=48
        const val GAP_HEAD_FRAMES=10
        const val GAP_TAIL_FRAMES=20
        const val FIRST_LIMIT_FRAMES=120
        const val MAX_LOCAL_TEMPO=1.25
        fun presentationTempo(requested: Double,local: Double)=minOf(requested,NarrationPolicy.MAX_ADAPTIVE_RATE/maxOf(1.0,local))
        fun openingTarget(text: String,language: String): Double? {
            val clause=text.trim().split(Regex("[,，;；:：.!?。！？؟\\n]"),limit=2).first().trim()
            if(clause.isEmpty())return null
            val units=clause.count {it.isLetterOrDigit()}
            return when {
                language=="zh"&&units in 1..4&&clause.filter {it.isLetterOrDigit()}.all {Character.isIdeographic(it.code)} -> maxOf(.36,.22*units+.04)
                language=="ja"&&units in 1..7 -> maxOf(.42,.14*units+.08)
                language !in setOf("zh","ja","ko")&&units in 2..18&&Regex("[\\p{L}\\p{N}]+").findAll(clause).count()<=2 -> maxOf(.42,.055*units+.18)
                else -> null
            }
        }
    }
    data class Stats(val inputSamples: Int,val outputSamples: Int,val removedPauseSamples: Int,
                     val removedDragSamples: Int,val localTempo: Double,val maxBufferedSamples: Int)
    private val target=openingTarget(text,language)
    private val wholeShortClause=text.trim().trimEnd('.', '。','!','！','?','？','؟').none {it in ",，;；:：.!?。！？؟\n"}
    private var holdFirst=target!=null&&!fastStart
    private val blockSamples=if(fastStart)9600 else BLOCK_SAMPLES
    private var first=ArrayList<FloatArray>()
    private var firstSamples=0
    private var firstSignalSamples=0
    private val quiet=ArrayList<FloatArray>()
    private var quietFrames=0
    private var compacted=false
    private var heardSpeech=false
    private var peakRms=0.0
    private var frame=FloatArray(FRAME_SAMPLES)
    private var frameUsed=0
    private var block=FloatArray(blockSamples)
    private var blockUsed=0
    private var inputSamples=0
    private var outputSamples=0
    private var removedPause=0
    private var removedDrag=0
    private var highWater=0
    var localTempo=1.0;private set
    val tempoCeiling get()=if(holdFirst)MAX_LOCAL_TEMPO else localTempo
    private var ended=false
    val stats get()=Stats(inputSamples,outputSamples,removedPause,removedDrag,localTempo,highWater)
    private fun water(){highWater=maxOf(highWater,firstSamples+quiet.sumOf {it.size}+frameUsed+blockUsed)}

    fun append(pcm: FloatArray) {
        check(!ended);require(pcm.size%2==0)
        inputSamples+=pcm.size
        var offset=0
        while(offset<pcm.size) {
            val count=minOf(FRAME_SAMPLES-frameUsed,pcm.size-offset)
            pcm.copyInto(frame,frameUsed,offset,offset+count);frameUsed+=count;offset+=count
            if(frameUsed==FRAME_SAMPLES){val complete=frame;frame=FloatArray(FRAME_SAMPLES);frameUsed=0;accept(complete)}
        }
        water()
    }
    private fun accept(pcm: FloatArray) {
        var energy=0.0;var peak=0f
        for(value in pcm){require(value.isFinite());energy+=value*value;peak=maxOf(peak,abs(value))}
        val rms=sqrt(energy/pcm.size);peakRms=maxOf(peakRms,rms)
        // Relative to the unscaled utterance. A quiet voice is not a silence:
        // keep the floor near quantization noise and require low peaks as well.
        val threshold=(peakRms*.025).coerceIn(.00006,.002)
        val low=rms<=threshold&&peak<=maxOf(.0004,threshold*4)
        // Pacing uses actual audible activity, never the size of a held buffer:
        // faint room/codec noise between words must not make a normal greeting
        // look like a drawn-out vowel.
        if(holdFirst&&rms>maxOf(.00012,peakRms*.06))firstSignalSamples+=pcm.size
        if(low&&heardSpeech) {
            quietFrames++;quiet+=pcm
            // Protect a faint voiced syllable after louder speech. This cheap
            // 8kHz periodicity guard is only run on quiet 40ms windows; it is not
            // a second neural VAD/model or a reason to delete breath sounds.
            if(quietFrames%4==0&&quietVoicing()){flushQuiet();water();return}
            if(!compacted&&quietFrames>=LONG_GAP_FRAMES) {
                finishFirst(true)
                quiet.take(GAP_HEAD_FRAMES).forEachIndexed {i,part->output(if(i==GAP_HEAD_FRAMES-1)fade(part,false) else part)}
                val tail=quiet.takeLast(GAP_TAIL_FRAMES)
                removedPause+=quiet.sumOf {it.size}-GAP_HEAD_FRAMES*FRAME_SAMPLES-tail.sumOf {it.size}
                quiet.clear();quiet.addAll(tail);compacted=true
                flushBlock() // Start the first phrase without waiting for EOS.
            } else if(compacted&&quiet.size>GAP_TAIL_FRAMES)removedPause+=quiet.removeAt(0).size
        } else {
            flushQuiet()
            if(!low)heardSpeech=true
            speech(pcm)
        }
        water()
    }
    private fun quietVoicing(): Boolean {
        if(quiet.size<4||quiet.takeLast(4).any {it.size!=FRAME_SAMPLES})return false
        val left=DoubleArray(320);val right=DoubleArray(320);var at=0
        for(part in quiet.takeLast(4))for(i in 0 until FRAME_SAMPLES step 12){left[at]=part[i].toDouble();right[at]=part[i+1].toDouble();at++}
        val signal=if(left.sumOf {it*it}>=right.sumOf {it*it})left else right
        val mean=signal.average();var energy=0.0
        for(i in signal.indices){signal[i]-=mean;energy+=signal[i]*signal[i]}
        if(energy/signal.size<.00012*.00012)return false
        for(lag in 12..112 step 2) {
            var xy=0.0;var xx=0.0;var yy=0.0
            for(i in lag until signal.size){val x=signal[i];val y=signal[i-lag];xy+=x*y;xx+=x*x;yy+=y*y}
            if(xx>0&&yy>0&&xy/sqrt(xx*yy)>.92)return true
        }
        return false
    }
    private fun speech(pcm: FloatArray) {
        if(holdFirst) {
            first+=pcm;firstSamples+=pcm.size
            if(firstSamples>=FIRST_LIMIT_FRAMES*FRAME_SAMPLES)finishFirst(false)
        } else output(pcm)
    }
    private fun flushQuiet() {
        if(compacted)quiet.forEachIndexed {i,part->output(if(i==0)fade(part,true) else part)} else quiet.forEach {speech(it)}
        quiet.clear();quietFrames=0;compacted=false
    }
    private fun fade(source: FloatArray,fadeIn: Boolean): FloatArray=source.copyOf().also {pcm->
        val frames=minOf(240,pcm.size/2) // 5ms on the quiet cut only, never spoken edges.
        for(i in 0 until frames){val gain=i.toFloat()/maxOf(1,frames-1)
            val at=if(fadeIn)i*2 else pcm.size-2-i*2
            pcm[at]*=gain;pcm[at+1]*=gain}
    }
    private fun finishFirst(allowTempo: Boolean) {
        if(!holdFirst)return
        holdFirst=false
        val duration=firstSignalSamples/96000.0
        val tempo=if(allowTempo&&target!=null&&peakRms>=.003&&duration>=.52&&duration>target*1.15)
            (duration/target).coerceAtMost(MAX_LOCAL_TEMPO) else 1.0
        if(tempo>1.0) {
            // Sonic changes duration with pitch fixed; only this short region is
            // fed to it. Subsequent speech is copied exactly at its original pace.
            NarrationPcm(tempo).also {pcm->
                try {
                    pcm.update(first,true);localTempo=tempo
                    removedDrag+=firstSamples-pcm.samples
                    pcm.chunks.forEach {output(it)}
                } finally {pcm.close()}
            }
        } else first.forEach {output(it)}
        first.clear();firstSamples=0
    }
    private fun output(pcm: FloatArray) {
        var at=0
        while(at<pcm.size) {
            val count=minOf(block.size-blockUsed,pcm.size-at)
            pcm.copyInto(block,blockUsed,at,at+count);blockUsed+=count;at+=count
            if(blockUsed==block.size)flushBlock()
        }
    }
    private fun flushBlock() {
        if(blockUsed==0)return
        val ready=if(blockUsed==block.size)block else block.copyOf(blockUsed)
        block=FloatArray(blockSamples);blockUsed=0;outputSamples+=ready.size;emit(ready)
    }
    fun finish() {
        if(ended)return
        if(frameUsed>0){accept(frame.copyOf(frameUsed));frameUsed=0}
        // A complete short sentence may be paced at EOS. A multi-clause sentence
        // without an acoustic boundary must never be mistaken for its first clause.
        finishFirst(wholeShortClause)
        flushQuiet();finishFirst(false);flushBlock();ended=true
        check(inputSamples-outputSamples==removedPause+removedDrag)
    }
    fun close(){ended=true;first.clear();firstSamples=0;quiet.clear();frameUsed=0;blockUsed=0}
}
