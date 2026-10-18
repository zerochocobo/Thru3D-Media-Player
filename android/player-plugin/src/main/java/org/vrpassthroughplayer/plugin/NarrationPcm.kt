package org.vrpassthroughplayer.plugin

import androidx.media3.common.C
import androidx.media3.common.audio.AudioProcessor
import androidx.media3.common.audio.SonicAudioProcessor
import java.nio.ByteBuffer
import java.nio.ByteOrder

/** Per-utterance software tempo. AudioTrack always receives ordinary 48 kHz PCM. */
internal class NarrationPcm(speed: Double) {
    private val processor=SonicAudioProcessor().let {
        it.setSpeed(speed.toFloat().coerceIn(.25f,3.9f));it.setPitch(1f)
        it.configure(AudioProcessor.AudioFormat(48000,2,C.ENCODING_PCM_16BIT))
        if(it.isActive) {it.flush(AudioProcessor.StreamMetadata.DEFAULT);it} else {it.reset();null}
    }
    private var input=ByteBuffer.allocateDirect(0).order(ByteOrder.nativeOrder())
    private var inputChunks=0
    val chunks=mutableListOf<FloatArray>()
    var samples=0;private set
    var cursor=0
    var done=false;private set

    fun update(source: List<FloatArray>, ended: Boolean) {
        check(!done || inputChunks==source.size)
        while(inputChunks<source.size) {
            val chunk=source[inputChunks++]
            if(processor==null) append(chunk) // Preserve the approved 1x PCM exactly.
            else {
                if(input.capacity()<chunk.size*2)input=ByteBuffer.allocateDirect(chunk.size*2).order(ByteOrder.nativeOrder())
                input.clear();input.limit(chunk.size*2)
                for(value in chunk)input.putShort((value*32768f).toInt().coerceIn(-32768,32767).toShort())
                input.flip();processor.queueInput(input);check(!input.hasRemaining());drain()
            }
        }
        if(ended&&!done) {processor?.queueEndOfStream();drain();done=true}
    }
    private fun append(chunk: FloatArray) { if(chunk.isNotEmpty()){chunks+=chunk;samples+=chunk.size} }
    private fun drain() {
        val value=processor?.output ?: return
        if(value.hasRemaining()) {
            val chunk=FloatArray(value.remaining()/2)
            for(i in chunk.indices)chunk[i]=value.short/32768f
            append(chunk)
        }
    }
    fun close() {processor?.reset();chunks.clear()}
    /** Samples already submitted to AudioTrack must never be replayed when an
     * utterance finishes generating and its unheard tail needs a faster tempo. */
    fun remaining(): List<FloatArray> {
        var skip=cursor
        return chunks.mapNotNull { chunk ->
            if(skip>=chunk.size) {skip-=chunk.size;null}
            else chunk.let {val begin=skip;skip=0;if(begin==0)it else it.copyOfRange(begin,it.size)}
        }
    }
    companion object {
        /** Outer padding only, preserving 80 ms around soft consonants. */
        fun trimOuterSilence(source: List<FloatArray>): List<FloatArray> {
            val count=source.sumOf {it.size}
            if(count==0)return source
            var energy=0.0
            for(chunk in source)for(value in chunk) {require(value.isFinite());energy+=value*value}
            val threshold=maxOf(.00025,kotlin.math.sqrt(energy/count)*.01)
            val block=960 // 10 ms stereo at 48 kHz.
            var offset=0;var used=0;var sum=0.0;var first=-1;var last=0
            for(chunk in source)for(value in chunk) {
                sum+=value*value;used++;offset++
                if(used==block||offset==count) {
                    if(kotlin.math.sqrt(sum/used)>threshold) {if(first<0)first=offset-used;last=offset}
                    used=0;sum=0.0
                }
            }
            if(first<0)return source
            val begin=(first-7680).coerceAtLeast(0)/2*2
            val end=(last+7680).coerceAtMost(count)/2*2
            if(begin==0&&end==count)return source
            var at=0;val result=mutableListOf<FloatArray>()
            for(chunk in source) {
                val start=(begin-at).coerceAtLeast(0);val limit=(end-at).coerceAtMost(chunk.size)
                if(start<limit)result+=if(start==0&&limit==chunk.size)chunk else chunk.copyOfRange(start,limit)
                at+=chunk.size
            }
            return result
        }
    }
}
