package org.vrpassthroughplayer.plugin

import org.json.JSONObject

/** Shared-model audition orchestration, with injectable output for lifecycle/streaming checks. */
internal class NarrationPreviewSession(private val runtime: SharedNarrationEngine,
                                      private val cache: ()->NarrationPreviewCache,private val drain: ()->Unit) : AutoCloseable {
    @Volatile private var lease: SharedNarrationEngine.Lease?=null
    fun cancel()=lease?.cancel()
    fun play(voice: String,language: String,text: String,codes: IntArray,saved: Boolean,model: String,
             active: ()->Boolean,output: ()->VoicePreviewStream.Output,phase: (String)->Unit,
             cacheInfo: (Boolean,Int)->Unit,cacheFailure: ()->Unit,
             rhythmInfo: (NarrationRhythm.Stats)->Unit={},levelInfo: (NarrationLevel.Stats)->Unit={}) {
        check(active()){"voice_cancelled"};val store=cache()
        val key=NarrationPreviewCache.key(voice,language,text,model,codes)
        val cached=store.find(voice,language,key,saved,active)
        if(cached!=null){cacheInfo(true,cached.samples)
            VoicePreviewStream(active,output()).use {stream->
                val level=NarrationLevel {check(active()){"voice_cancelled"};stream.append(it)}
                val rhythm=NarrationRhythm(text,language){level.append(it)}
                try {cached.read(active){rhythm.append(it)};rhythm.finish();level.finish();rhythmInfo(rhythm.stats);levelInfo(level.stats);stream.complete()}
                finally {rhythm.close();level.close()}}
            check(active()){"voice_cancelled"};phase("ready");return
        }
        phase("preparing");drain();check(active()){"voice_cancelled"}
        val progress: (String,Long,Long)->Unit={stage,_,_->
            check(active()){"voice_cancelled"}
            if(stage!="ready")phase(if(stage=="verifying")"model_verifying" else "model_loading")}
        val current=lease?.also {it.ensure(active,progress)} ?: runtime.acquire(active,progress).also {lease=it}
        for(attempt in 0..1) {
            phase("generating");var count=0
            var writer=runCatching {store.writer(voice,language,key,saved)}.getOrElse {cacheFailure();null}
            val stream=VoicePreviewStream(active,output())
            val level=NarrationLevel {check(active()){"voice_cancelled"};stream.append(it)}
            val rhythm=NarrationRhythm(text,language){level.append(it)}
            try {
                val result=JSONObject(runtime.synthesize(current,text,voice,0,250,attempt>0,active,{codes},object:NarrationNative.Sink {
                    override fun onChunk(epoch: Long,pcm: FloatArray): Boolean {
                        check(active()){"voice_cancelled"};require(count+pcm.size<=NarrationPreviewCache.MAX_SAMPLES);count+=pcm.size
                        writer?.let {target->try {target.append(pcm)}catch(error: Exception){target.close();writer=null;cacheFailure()}}
                        rhythm.append(pcm);return active()
                    }
                }))
                check(active()){"voice_cancelled"}
                val complete=result.optBoolean("eos")&&!result.optBoolean("cancelled")&&count>0
                // A recovery may restart only before any playback has started.
                if(!complete){
                    // Join output before deciding to retry: start() may have been
                    // racing with the final native result on the consumer thread.
                    stream.close()
                    if(attempt==0&&!stream.started)continue
                    error("voice_synthesis_failed")
                }
                cacheInfo(false,count)
                writer?.let {target->runCatching {target.complete(active)}.onFailure {cacheFailure()}}
                rhythm.finish();level.finish();rhythmInfo(rhythm.stats);levelInfo(level.stats)
                stream.complete();check(active()){"voice_cancelled"}
                phase("ready");return
            } finally {rhythm.close();level.close();stream.close();writer?.close()}
        }
        error("voice_synthesis_failed")
    }
    override fun close(){lease?.close();lease=null}
}
