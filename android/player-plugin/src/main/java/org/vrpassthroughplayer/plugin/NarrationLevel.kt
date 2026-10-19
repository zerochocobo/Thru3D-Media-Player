package org.vrpassthroughplayer.plugin

import kotlin.math.*

/** Shared bounded speech leveller. Measures speech, never boosts each word or pause
 * independently. Stereo-linked lookahead limits peaks without hard clipping. */
internal class NarrationLevel(private val emit: (FloatArray)->Unit) : AutoCloseable {
    data class Stats(var initialGainDb: Double=0.0,var gainDb: Double=0.0,
                     var limitedFrames: Int=0,var maxBufferedSamples: Int=0)
    val stats=Stats()
    private val frame=FloatArray(1920)
    private var fill=0
    private val lead=ArrayList<FloatArray>()
    private val powers=ArrayDeque<Double>()
    private var ready=false
    private var gainDb=0.0
    private var pending: FloatArray?=null
    private var pendingGain=1.0
    private var limiterGain=1.0
    private var first=true
    private val output=FloatArray(19200)
    private var written=0
    private var ended=false
    fun append(pcm: FloatArray) {
        check(!ended);require(pcm.size%2==0&&pcm.all {it.isFinite()})
        var at=0
        while(at<pcm.size){val n=minOf(frame.size-fill,pcm.size-at);pcm.copyInto(frame,fill,at,at+n);at+=n;fill+=n
            if(fill==frame.size){accept(frame.copyOf());fill=0}}
    }
    private fun power(pcm: FloatArray)=pcm.sumOf {it.toDouble()*it}/pcm.size
    private fun target(): Double {
        val sorted=powers.sorted();if(sorted.isEmpty())return 0.0
        val gate=maxOf(1e-8,sorted[(sorted.lastIndex*.95).toInt()]*.0144)
        val active=sorted.filter {it>gate}
        if(active.isEmpty())return gainDb
        val rms=sqrt(active.average())
        // -20 dBFS active speech, bounded correction for unusually weak outputs.
        return (20*log10(.1/rms)).coerceIn(-18.0,18.0)
    }
    private fun accept(pcm: FloatArray) {
        val energy=power(pcm)
        // Codec noise before the first syllable is not evidence of a quiet voice.
        // Preserve those samples at unity while waiting for measurable speech.
        if(!ready&&lead.isEmpty()&&energy<1e-6){enqueue(pcm);return}
        powers.addLast(energy);while(powers.size>80)powers.removeFirst()
        if(!ready){lead+=pcm;stats.maxBufferedSamples=maxOf(stats.maxBufferedSamples,lead.sumOf {it.size}+output.size+frame.size)
            if(lead.size<64)return
            start()
        }else{
            // A 1.6s speech window and <=1.5 dB/s correction preserve local stress.
            gainDb+=(target()-gainDb).coerceIn(-.03,.03)
            enqueue(pcm)
        }
    }
    private fun start(){
        ready=true;gainDb=target();stats.initialGainDb=gainDb
        lead.forEach {enqueue(it)};lead.clear()
    }
    private fun ceiling(pcm: FloatArray,gain: Double): Double = minOf(1.0,.94/maxOf(1e-12,pcm.maxOf {abs(it).toDouble()}*gain))
    private fun enqueue(pcm: FloatArray) {
        val gain=10.0.pow(gainDb/20)
        pending?.let {render(it,pendingGain,ceiling(pcm,gain))}
        pending=pcm;pendingGain=gain;stats.gainDb=gainDb
    }
    private fun render(pcm: FloatArray,gain: Double,nextCeiling: Double) {
        val bound=ceiling(pcm,gain)
        if(first){limiterGain=bound;first=false}
        val from=minOf(limiterGain,bound)
        val to=minOf(bound,nextCeiling,from+(1-from)*(1-exp(-.02/.08)))
        if(minOf(from,to)<.999)stats.limitedFrames++
        val count=pcm.size/2
        for(i in 0 until count){val linked=gain*(from+(to-from)*(i+1)/count)
            output[written++]=(pcm[i*2]*linked).toFloat();output[written++]=(pcm[i*2+1]*linked).toFloat()
            if(written==output.size){emit(output.copyOf());written=0}}
        limiterGain=to
    }
    fun finish(){
        if(ended)return
        if(fill>0){accept(frame.copyOf(fill));fill=0}
        if(!ready&&lead.isNotEmpty())start()
        pending?.let {render(it,pendingGain,1.0)};pending=null
        if(written>0){emit(output.copyOf(written));written=0}
        ended=true
    }
    override fun close(){ended=true;lead.clear();powers.clear();pending=null;fill=0;written=0}
}
