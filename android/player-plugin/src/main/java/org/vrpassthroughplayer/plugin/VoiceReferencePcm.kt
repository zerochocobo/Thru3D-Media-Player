package org.vrpassthroughplayer.plugin

import java.io.File
import java.nio.ByteBuffer
import java.nio.ByteOrder
import kotlin.math.*

/** One-time conditioning of the reference, before the audio tokenizer sees it. */
internal object VoiceReferencePcm {
    const val REVISION="reference-v2"
    data class Result(val pcm: FloatArray,val inputDb: Double,val outputDb: Double,val gainDb: Double,val crestDb: Double,val targetDb: Double)
    fun prepare(source: FloatArray): Result {
        require(source.size in 288000..960000&&source.size%2==0)
        require(source.all {it.isFinite()})
        val pcm=FloatArray(source.size)
        // A gentle DC/rumble filter; no word-by-word compression or noise gate.
        val pole=exp(-2*PI*60/48000)
        val previous=doubleArrayOf(source[0].toDouble(),source[1].toDouble());val filtered=DoubleArray(2)
        for(i in source.indices){val c=i%2;val x=source[i].toDouble()
            val y=pole*(filtered[c]+x-previous[c]);previous[c]=x;filtered[c]=y;pcm[i]=y.toFloat()}
        val levels=ArrayList<Double>()
        var at=0
        while(at<pcm.size){val end=minOf(at+1920,pcm.size);var power=0.0
            for(i in at until end)power+=pcm[i].toDouble()*pcm[i]
            levels+=sqrt(power/(end-at));at=end}
        val ordered=levels.sorted();val high=ordered[(ordered.lastIndex*.95).toInt()]
        val active=levels.filter {it>maxOf(.001,high*.12)}
        require(active.size>=30&&active.size>=levels.size*.15&&high>=.003){"voice_reference_too_quiet"}
        val rms=sqrt(active.sumOf {it*it}/active.size)
        val peak=pcm.maxOf {abs(it).toDouble()}
        // Transient-heavy movie references need a more conservative speech target.
        // Clear, even recordings can use -20 dBFS; high-crest material stays at -23.
        // Neither branch compresses words or tries to convert whispered delivery.
        val crest=20*log10(peak/rms);val target=if(crest>18)-23.0 else -20.0
        val gain=minOf(10.0.pow(target/20)/rms,10.0.pow(6.0/20),10.0.pow(-3.0/20)/maxOf(peak,1e-9))
        for(i in pcm.indices)pcm[i]=(pcm[i]*gain).toFloat()
        return Result(pcm,20*log10(rms),20*log10(rms*gain),20*log10(gain),crest,target)
    }
    fun write(file: File,pcm: FloatArray) {
        require(pcm.size in 288000..960000&&pcm.size%2==0&&pcm.all {it.isFinite()&&abs(it)<=1f})
        val b=ByteBuffer.allocate(44+pcm.size*2).order(ByteOrder.LITTLE_ENDIAN)
        b.put("RIFF".toByteArray()).putInt(36+pcm.size*2).put("WAVEfmt ".toByteArray()).putInt(16)
            .putShort(1).putShort(2).putInt(48000).putInt(192000).putShort(4).putShort(16)
            .put("data".toByteArray()).putInt(pcm.size*2)
        pcm.forEach {b.putShort((it*32767).roundToInt().toShort())};file.writeBytes(b.array())
    }
}
