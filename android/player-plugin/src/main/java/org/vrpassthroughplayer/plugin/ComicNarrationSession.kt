package org.vrpassthroughplayer.plugin

import org.json.JSONObject

/** Page-independent speech shares exactly the subtitle/clone runtime and PCM path.
 * Long bubbles are segmented without truncation. No OCR text or audio is cached on disk. */
internal class ComicNarrationSession(private val runtime: SharedNarrationEngine) : AutoCloseable {
    @Volatile private var lease: SharedNarrationEngine.Lease?=null
    fun cancel()=lease?.cancel()
    fun warm(active: ()->Boolean){lease?.ensure(active) ?: run {lease=runtime.acquire(active)}}
    fun play(text: String,language: String,voice: String,codes: ()->IntArray,epoch: Long,
             active: ()->Boolean,output: ()->VoicePreviewStream.Output) {
        VoicePreviewStream(active,output()).use {stream->
            generate(text,language,voice,codes,epoch,active){stream.append(it)}
            stream.complete()
        }
    }
    fun generate(text: String,language: String,voice: String,codes: ()->IntArray,epoch: Long,
                 active: ()->Boolean,emit: (FloatArray)->Unit) {
        require(language in NarrationPolicy.languages);check(active()){"voice_cancelled"};warm(active)
        val current=checkNotNull(lease);val chunks=speechSegments(text,language)
            for(chunk in chunks){
                check(active()){"voice_cancelled"}
                val level=NarrationLevel(initialFrames=8) {check(active()){"voice_cancelled"};emit(it)}
                val rhythm=NarrationRhythm(chunk,language,fastStart=true){level.append(it)}
                try {
                    var samples=0
                    val result=JSONObject(runtime.synthesize(current,chunk,voice,epoch,250,false,active,codes,object:NarrationNative.Sink {
                        override fun onChunk(epoch: Long,pcm: FloatArray): Boolean {
                            check(active()){"voice_cancelled"};samples+=pcm.size
                            check(samples<=2_880_000){"comic_segment_limit"};rhythm.append(pcm);return active()
                        }
                    }))
                    check(active()&&result.optBoolean("eos")&&!result.optBoolean("cancelled")&&samples>0){"voice_synthesis_failed"}
                    rhythm.finish();level.finish()
                } finally {rhythm.close();level.close()}
            }
    }
    override fun close(){lease?.close();lease=null}
    companion object {
        fun speechSegments(text: String,language: String): List<String> {
            require(text.isNotBlank()&&text.codePointCount(0,text.length)<=2000)
            if(language!="ja")return segments(text).map {spokenText(it,language)}
            // Morphology needs the whole utterance, before a fixed-size cut can
            // split a compound word or remove the kana that disambiguates it.
            val prepared=ComicJapaneseReading.prepare(spokenText(text,language))
            return splitSegments(prepared.text,prepared.wordEnds,true).map {spokenText(it,language)}
        }
        fun spokenText(text: String,language: String): String {
            val value=NarrationPolicy.speechText(text,language)
            // A kana-by-kana chant is one utterance. Keep every kana and its
            // pause, but give TTS commas internally rather than a new shouted
            // sentence for each glyph. Display/selection retain the OCR text.
            if(language!="ja"||!value.endsWith('!'))return value
            val kana=value.dropLast(1).split('!')
            if(kana.size<3||kana.any {it.length!=1||!(it[0] in '\u3041'..'\u3096'||it[0] in '\u30a1'..'\u30fa')})return value
            return kana.joinToString("、")+"!"
        }
        fun segments(text: String): List<String> {
            require(text.isNotBlank()&&text.codePointCount(0,text.length)<=2000)
            return splitSegments(text)
        }
        private fun splitSegments(text: String,wordEnds: Set<Int> = emptySet(),japanese: Boolean=false): List<String> {
            val result=ArrayList<String>();var start=0
            while(start<text.length){
                val remaining=text.codePointCount(start,text.length)
                if(remaining<=24){result+=text.substring(start);break}
                // Preserve short utterances as context, including spelled-out
                // Japanese names with an exclamation after every kana. Balance
                // the last two chunks instead of leaving a one-glyph tail.
                val limit=if(remaining<=30)remaining/2 else 24
                var at=start;var boundary=-1
                repeat(limit){i->
                    val cp=text.codePointAt(at);at+=Character.charCount(cp)
                    val punctuation=cp in listOf(0x3002,0xff01,0xff1f,0x21,0x3f,0xa)
                    val nextPunctuation=at<text.length&&text.codePointAt(at) in listOf(0x3002,0xff01,0xff1f,0x21,0x3f,0xa)
                    if(i>=11&&punctuation&&!nextPunctuation)boundary=at
                }
                var end=if(boundary>start)boundary else at
                if(boundary<=start&&japanese){
                    // Kana expansion changes word lengths: a balanced character
                    // cut can turn 一生 into "い。" / "っしょう". Reuse the
                    // morphology pass's output positions; no second tokenizer
                    // or neural synthesis call is needed.
                    val floor=text.offsetByCodePoints(start,minOf(8,limit))
                    end=wordEnds.filter {it in floor..at}.maxOrNull() ?: end
                    // Kana-only passages do not initialize the dictionary.
                    // Keep a small kana / prolonged vowel with its preceding
                    // mora even when no lexical boundary is available.
                    while(end>floor&&end<text.length&&text[end] in "ぁぃぅぇぉっゃゅょゎァィゥェォッャュョヮー")
                        end=text.offsetByCodePoints(end,-1)
                }
                result+=text.substring(start,end);start=end
            }
            return result.filter {it.isNotBlank()}
        }
    }
}
