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
}
