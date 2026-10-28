package org.vrpassthroughplayer.plugin

import org.json.JSONObject

/** Shared-model audition orchestration, with injectable output for lifecycle/streaming checks.
 * Generated speech reaches output only clause by clause, after each clause reached EOS:
 * a voice/text pair that never ends must not be heard as a runaway tail. */
internal class NarrationPreviewSession(private val runtime: SharedNarrationEngine,
                                      private val cache: ()->NarrationPreviewCache,private val drain: ()->Unit) : AutoCloseable {
    data class Generation(val segments: Int,val attempts: Int,val recovered: Int,val subdivided: Int)
    @Volatile private var lease: SharedNarrationEngine.Lease?=null
    fun cancel()=lease?.cancel()
    fun play(voice: String,language: String,text: String,codes: IntArray,saved: Boolean,model: String,
             active: ()->Boolean,output: ()->VoicePreviewStream.Output,phase: (String)->Unit,
             cacheInfo: (Boolean,Int)->Unit,cacheFailure: ()->Unit,
             rhythmInfo: (NarrationRhythm.Stats)->Unit={},levelInfo: (NarrationLevel.Stats)->Unit={},
             generationInfo: (Generation)->Unit={}) {
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
        phase("generating")
        val counts=IntArray(4);var count=0
        var writer=runCatching {store.writer(voice,language,key,saved)}.getOrElse {cacheFailure();null}
        // Lookahead lets the next clause generate while the previous one plays.
        val stream=VoicePreviewStream(active,output(),queueBlocks=LOOKAHEAD_BLOCKS)
        val level=NarrationLevel {check(active()){"voice_cancelled"};stream.append(it)}
        val rhythm=NarrationRhythm(text,language){level.append(it)}
        try {
            for(segment in segments(text,language))
                for(pcm in validated(current,segment,language,voice,codes,active,NarrationPreviewCache.MAX_SAMPLES-count,counts,true)){
                    count+=pcm.size
                    writer?.let {target->try {target.append(pcm)}catch(error: Exception){target.close();writer=null;cacheFailure()}}
                    rhythm.append(pcm)
                }
            check(active()){"voice_cancelled"}
            cacheInfo(false,count)
            writer?.let {target->runCatching {target.complete(active)}.onFailure {cacheFailure()}}
            rhythm.finish();level.finish();rhythmInfo(rhythm.stats);levelInfo(level.stats)
            stream.complete();check(active()){"voice_cancelled"}
            phase("ready")
        } finally {
            runCatching {generationInfo(Generation(counts[0],counts[1],counts[2],counts[3]))}
            rhythm.close();level.close();stream.close();writer?.close()
        }
    }
    /** Complete PCM of one clause, or an exception; never a partial or EOS-less clause. */
    private fun validated(lease: SharedNarrationEngine.Lease,text: String,language: String,voice: String,codes: IntArray,
                          active: ()->Boolean,room: Int,counts: IntArray,counted: Boolean): List<FloatArray> {
        if(counted)counts[0]++
        // A runaway clause is cut near its natural length instead of 20 seconds.
        val frames=NarrationPolicy.generationFrameBudget(text,language,0.0,48)
        for((index,attempt) in ATTEMPTS.withIndex()){
            counts[1]++;val chunks=ArrayList<FloatArray>();var size=0
            val result=JSONObject(runtime.synthesize(lease,text,voice,0,frames,attempt.first,active,{codes},object:NarrationNative.Sink {
                override fun onChunk(epoch: Long,pcm: FloatArray): Boolean {
                    check(active()){"voice_cancelled"};size+=pcm.size;check(size<=room){"voice_synthesis_failed"}
                    chunks+=pcm;return active()
                }
            },attempt.second))
            check(active()&&!result.optBoolean("cancelled")){"voice_cancelled"}
            if(result.optBoolean("eos")&&size>0){if(index>0)counts[2]++;return chunks}
        }
        // Merged clauses get one finer pass; each piece keeps the same bounded ladder.
        val pieces=clauses(text,language)
        check(pieces.size>1){"voice_synthesis_failed"}
        counts[3]++;val result=ArrayList<FloatArray>();var used=0
        for(piece in pieces)validated(lease,piece,language,voice,codes,active,room-used,counts,false).forEach {result+=it;used+=it.size}
        return result
    }
    override fun close(){lease?.close();lease=null}
    companion object {
        const val LOOKAHEAD_BLOCKS=32
        // The precision graph recovers most INT8 non-endings; a different
        // random stream covers the rest without changing the voice or text.
        private val ATTEMPTS=listOf(false to 0,true to 0,false to 17,true to 17)
        private const val TERMINATORS="。！？!?…؟"
        private fun units(text: String,language: String)=
            if(language in setOf("zh","ja"))text.count {it.isLetterOrDigit()} else Regex("[\\p{L}\\p{N}]+").findAll(text).count()
        private fun limit(language: String)=if(language in setOf("zh","ja"))12 else 10
        private fun clauseMark(c: Char,language: String)=c in "，、；：,:،"||(c==';'&&language!="el")
        private fun split(text: String,cut: (Int)->Boolean): List<String> {
            val result=ArrayList<String>();var start=0
            for(i in text.indices)if(cut(i)){result+=text.substring(start,i+1);start=i+1}
            result+=text.substring(start)
            return result.map {it.trim()}.filter {piece->piece.any {it.isLetterOrDigit()}}
        }
        // Keep the caller's characters; only a cut clause receives a sentence end.
        private fun spoken(text: String,language: String): String {
            val value=text.trim().trimEnd {clauseMark(it,language)}.trimEnd()
            if(value.last() in TERMINATORS||value.last()=='.'||(language=="el"&&value.last()==';'))return value
            return value+if(language in setOf("zh","ja"))"。" else "."
        }
        fun clauses(text: String,language: String)=split(text){i->clauseMark(text[i],language)}.map {spoken(it,language)}
        /** Sentences, with long ones regrouped at clause marks. Text is never dropped. */
        fun segments(text: String,language: String): List<String> {
            val sentences=split(text){i->
                val c=text[i];val next=text.getOrNull(i+1)
                val end=c in TERMINATORS||((c=='.'||(c==';'&&language=="el"))&&(next==null||next.isWhitespace()))
                end&&(next==null||next !in TERMINATORS)}
            val result=ArrayList<String>()
            for(sentence in sentences){
                if(units(sentence,language)<=limit(language)){result+=spoken(sentence,language);continue}
                var current=""
                for(piece in split(sentence){i->clauseMark(sentence[i],language)}){
                    if(current.isNotEmpty()&&units(current,language)+units(piece,language)>limit(language)){result+=spoken(current,language);current=piece}
                    else current=if(current.isEmpty())piece else "$current${if(language in setOf("zh","ja"))"" else " "}$piece"
                }
                if(current.isNotEmpty())result+=spoken(current,language)
            }
            return result.ifEmpty {listOf(text)}
        }
    }
}
