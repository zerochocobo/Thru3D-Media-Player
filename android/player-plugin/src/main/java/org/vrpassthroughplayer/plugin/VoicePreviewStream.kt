package org.vrpassthroughplayer.plugin

import java.util.concurrent.ArrayBlockingQueue
import java.util.concurrent.TimeUnit
import java.util.concurrent.atomic.AtomicReference

/** Bounded producer/consumer: native generation never retains a complete float utterance. */
internal class VoicePreviewStream(private val active: ()->Boolean,private val output: Output,private val startSamples: Int=START_SAMPLES,
                                  queueBlocks: Int=QUEUE_BLOCKS) : AutoCloseable {
    init {require(startSamples in 2..START_SAMPLES&&startSamples%2==0&&queueBlocks in 1..64)}
    interface Output : AutoCloseable {
        fun start()
        fun write(pcm: FloatArray)
        fun finish(samples: Int)
    }
    companion object {const val BLOCK_LIMIT=96_000;const val QUEUE_BLOCKS=4;const val START_SAMPLES=38_400}
    private val queue=ArrayBlockingQueue<FloatArray>(queueBlocks)
    private val failure=AtomicReference<Throwable?>()
    @Volatile private var ended=false
    @Volatile private var stopped=false
    @Volatile var started=false;private set
    @Volatile var samples=0;private set
    private val worker=Thread({consume()},"VoicePreviewOutput").also {it.start()}
    private fun checkActive(){failure.get()?.let {throw it};check(active()&&!stopped){"voice_cancelled"}}
    fun append(pcm: FloatArray) {
        require(pcm.isNotEmpty()&&pcm.size%2==0&&pcm.size<=BLOCK_LIMIT)
        checkActive();while(!queue.offer(pcm,40,TimeUnit.MILLISECONDS))checkActive()
        checkActive()
    }
    fun complete(){ended=true;worker.join(35_000);check(!worker.isAlive){"voice_playback_timeout"};checkActive()}
    private fun consume() {
        try {
            val lead=ArrayList<FloatArray>();var buffered=0
            while(!stopped&&active()) {
                val block=queue.poll(40,TimeUnit.MILLISECONDS)
                if(block==null){if(ended)break;continue}
                if(!started){lead+=block;buffered+=block.size
                    if(buffered<startSamples&&!ended)continue
                    checkActive();output.start();started=true
                    lead.forEach {output.write(it);samples+=it.size};lead.clear()
                } else {output.write(block);samples+=block.size}
            }
            if(!stopped&&active()) {
                if(!started&&lead.isNotEmpty()){output.start();started=true;lead.forEach {output.write(it);samples+=it.size}}
                if(started)output.finish(samples)
            }
        } catch(error: Throwable){failure.set(error)}
        finally {output.close();queue.clear()}
    }
    override fun close(){stopped=true;ended=true;output.close();worker.interrupt();worker.join(3000);check(!worker.isAlive){"voice_output_shutdown"}}
}
