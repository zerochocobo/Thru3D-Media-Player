package org.vrpassthroughplayer.plugin

import android.content.Context
import android.media.AudioAttributes
import android.media.AudioFormat
import android.media.AudioTrack
import org.json.JSONArray
import org.json.JSONObject
import java.io.File
import java.util.concurrent.ThreadPoolExecutor
import java.util.concurrent.ArrayBlockingQueue
import java.util.concurrent.TimeUnit
import java.util.concurrent.atomic.AtomicLong
import kotlin.math.max

/** Two-page, memory-only OCR/selection store. All image/model work stays off the VR thread. */
internal class ComicReaderController(private val context: ()->Context?,private val allowed: ()->Boolean,
    private val runtime: SharedNarrationEngine,private val audioChanged: ()->Unit) : AutoCloseable {
    private fun worker(name: String, capacity: Int)=ThreadPoolExecutor(1,1,0L,TimeUnit.MILLISECONDS,ArrayBlockingQueue<Runnable>(capacity),{Thread(it,name)},ThreadPoolExecutor.DiscardOldestPolicy())
    private val ocrWorker=worker("ComicOcr",2)
    private val speechWorker=worker("ComicSpeech",1)
    private val speech=ComicNarrationSession(runtime)
    private val lock=Any()
    private val focusLock=Any()
    private val ocrToken=AtomicLong()
    private val speechToken=AtomicLong()
    @Volatile private var closed=false
    @Volatile private var document=0L
    @Volatile private var handle=0L
    @Volatile private var audio: AudioTrack?=null
    @Volatile var wantsAudio=false;private set
    @Volatile private var audioAllowed=false
    private var revision=0L
    private val pages=HashMap<Int,JSONObject>()
    private val pageKeys=HashMap<Int,String>()
    private val pageCache=ComicPageCache()
    private var cacheHits=0
    private var aheadReady=0
    private val aheadAudioKeys=HashSet<String>()
    private val requested=HashSet<Int>()
    private var state="idle"
    private var speechState="idle"
    private var voice="Xiaoyu"
    private var language="auto"
    @Volatile private var speechEnabled=true
    private val routing=ComicSpeechRouting()
    private var hoverKey=""
    private var hoverAt=0L
    private var triggerAt=0L
    private var firstAudioMs=-1L
    private var hoverAudioMs=-1L
    private var warmHit=false
    @Volatile private var ocrVerifyMs=0L
    @Volatile private var ocrLoadMs=0L
    private val prefetch=ComicSpeechPrefetch(speech,{id->
        if(PersonalVoiceStore.isVoice(id))NarrationAssets.voices(context() ?: error("comic_unavailable")).load(id) else IntArray(0)
    },{synchronized(lock){revision++}})
    fun configure(selectedVoice: String,selectedLanguage: String): Boolean {
        if(closed||!allowed()||!validVoice(selectedVoice)||(selectedLanguage!="auto"&&selectedLanguage !in NarrationPolicy.languages))return false
        val changed=synchronized(lock){if(voice==selectedVoice&&language==selectedLanguage)false else {voice=selectedVoice;language=selectedLanguage;true}}
        if(changed){cancelSpeech();prefetch.clear();synchronized(lock){aheadAudioKeys.clear()};schedulePageAudio()}
        return true
    }
    private fun validVoice(id: String)=PersonalVoiceStore.isVoice(id)||id in NarrationPolicy.voices.values.flatten()
    fun translationMode(mode: String,language: String): Boolean = synchronized(lock){
        if(closed||!allowed()||(language.isNotEmpty()&&language !in NarrationPolicy.languages))return false
        if(routing.mode(mode,language)){
            cancelSpeech();prefetch.clear();aheadAudioKeys.clear();revision++;schedulePageAudio()
        }
        true
    }
    fun translations(epoch: Long,mode: String,json: String): Boolean = synchronized(lock){
        if(closed||!allowed()||epoch!=document)return false
        if(!runCatching {routing.update(epoch,mode,JSONArray(json))}.getOrDefault(false))return false
        revision++;schedulePageAudio();true
    }
    fun setSpeechEnabled(value: Boolean) {
        synchronized(lock){
            if(speechEnabled==value)return
            speechEnabled=value
            if(!value){prefetch.clear(true);aheadAudioKeys.clear();revision++}
        }
        if(value)schedulePageAudio() else cancelSpeech()
    }
    private fun selected(epoch: Long,page: Int,block: Int): ComicSpeechPrefetch.Request? = synchronized(lock){
        if(epoch!=document)return null
        val rows=pages[page]?.optJSONArray("blocks") ?: return null
        val row=(0 until rows.length()).map {rows.getJSONObject(it)}.singleOrNull {it.optInt("id",-1)==block&&it.optBoolean("eligible")} ?: return null
        val lang=ComicSpeechRouting.originalLanguage(language,row.getString("language"),row.getString("text"))
        val text=routing.resolve(page,block,row.getString("text"),lang) ?: return null
        ComicSpeechPrefetch.Request(ComicPageCache.speechKey(pageKeys[page] ?: return null,block,voice,text.language)+text.suffix,text.text,text.language,voice)
    }
    private fun schedulePageAudio()=synchronized(lock){
        if(closed||!allowed()||!speechEnabled||document==0L)return
        val requests=synchronized(lock){pages.toSortedMap().flatMap {(page,data)->val rows=data.optJSONArray("blocks") ?: JSONArray()
            (0 until rows.length()).mapNotNull {selected(document,page,rows.getJSONObject(it).optInt("id",-1))}}.take(8)}
        for(request in requests)prefetch.prepare(request,false)
    }
    fun prepare(epoch: Long,page: Int,block: Int): Boolean {
        if(closed||!allowed()||!speechEnabled)return false
        val request=selected(epoch,page,block) ?: return false
        synchronized(lock){hoverKey=request.key;hoverAt=System.nanoTime();firstAudioMs=-1;hoverAudioMs=-1;revision++}
        prefetch.prepare(request,true);return true
    }

    private fun speechStatus(value: String)=synchronized(lock){speechState=value;revision++}
    fun warm(){
        if(closed||!allowed())return
        val token=ocrToken.get()
        ocrWorker.execute {runCatching {ensureEngine { !closed&&allowed()&&ocrToken.get()==token }}}
        if(speechEnabled)prefetch.warm()
    }
    fun begin(epoch: Long): Boolean {
        if(closed||!allowed()||epoch<=0)return false
        cancelSpeech();ocrWorker.queue.clear()
        synchronized(lock){document=epoch;routing.page(epoch);pages.clear();pageKeys.clear();requested.clear();aheadReady=0;aheadAudioKeys.clear();val token=ocrToken.incrementAndGet();ComicOcrNative.cancel(handle,token);state="recognizing";revision++}
        val token=ocrToken.get()
        // Load/verify weights while Godot prepares the page pixels, not afterwards.
        ocrWorker.execute {runCatching {ensureEngine { !closed&&allowed()&&document==epoch&&ocrToken.get()==token }}}
        if(speechEnabled)prefetch.warm()
        return true
    }
    private fun ensureEngine(active: ()->Boolean){
        check(active())
        if(handle!=0L)return
        val app=context() ?: error("comic_unavailable")
        val manifest=app.assets.open("comic-ocr/model.json").bufferedReader().use {JSONObject(it.readText())}
        val directory=File(app.filesDir,manifest.getString("directory")).canonicalFile
        require(directory.path.startsWith(app.filesDir.canonicalPath+File.separator))
        val started=System.nanoTime()
        NarrationModels.ensure(directory,manifest.getJSONObject("files"),{app.assets.open(manifest.getString("directory")+"/"+it)},active,{_ ->})
        ocrVerifyMs=(System.nanoTime()-started)/1_000_000
        check(active());val loading=System.nanoTime();handle=ComicOcrNative.create(directory.path);check(handle>0){"comic_unavailable"}
        ocrLoadMs=(System.nanoTime()-loading)/1_000_000
    }
    fun page(epoch: Long,index: Int,width: Int,height: Int,rgb: ByteArray,ahead: Boolean=false): Boolean {
        if(closed||!allowed()||epoch!=document||index !in 0..1||width !in 16..1600||height !in 16..1600||rgb.size!=width*height*3)return false
        val token=synchronized(lock){if(epoch!=document||(!ahead&&!requested.add(index)))return false;ocrToken.get()}
        ocrWorker.execute {
            fun active()=!closed&&allowed()&&document==epoch&&ocrToken.get()==token
            if(!active())return@execute
            try {
                val key=ComicPageCache.key(width,height,rgb)
                val cached=pageCache.get(key)
                val result=if(cached!=null)JSONObject(cached) else {
                    ensureEngine(::active)
                    synchronized(lock){if(!active())return@execute;ComicOcrNative.cancel(handle,token)}
                    JSONObject(String(ComicOcrNative.analyze(handle,rgb,width,height,token,BuildConfig.DEBUG),Charsets.UTF_8))
                }
                synchronized(lock){
                    if(!active())return@execute
                    if(result.optString("state")=="ready")pageCache.put(key,result.toString())
                    if(ahead){
                        if(result.optString("state")=="ready")aheadReady++
                        // Current-page audio was queued first. Ahead work never requests audio focus.
                        val rows=result.optJSONArray("blocks") ?: JSONArray()
                        (0 until rows.length()).map {rows.getJSONObject(it)}.filter {speechEnabled&&!routing.translated&&it.optBoolean("eligible")}.take(4).forEach {row->
                            val lang=ComicSpeechRouting.originalLanguage(language,row.getString("language"),row.getString("text"))
                            val audioKey=ComicPageCache.speechKey(key,row.getInt("id"),voice,lang)
                            aheadAudioKeys.add(audioKey)
                            prefetch.prepare(ComicSpeechPrefetch.Request(audioKey,row.getString("text"),lang,voice),false)
                        }
                    } else {
                        if(cached!=null)cacheHits++
                        pageKeys[index]=key;pages[index]=result
                        state=if(result.optString("state")=="ready")"ready" else "unavailable"
                    }
                    revision++
                }
                if(active()&&!ahead)schedulePageAudio()
            } catch(_: Throwable){synchronized(lock){if(active()&&!ahead){pages[index]=JSONObject().put("state","error");state="unavailable";revision++}}}
        }
        return true
    }
    fun status(epoch: Long,known: Long): String=synchronized(lock){
        if(closed)return "{}"
        val cached=prefetch.snapshot()
        val keys=pages.flatMap {(page,data)->val rows=data.optJSONArray("blocks") ?: JSONArray();(0 until rows.length()).mapNotNull {selected(document,page,rows.getJSONObject(it).optInt("id",-1))?.key}}
        val j=JSONObject().put("ready_audio",prefetch.readyCount(keys)).put("audio_bytes",cached.second).put("first_audio_ms",firstAudioMs).put("hover_audio_ms",hoverAudioMs).put("warm_hit",warmHit).put("epoch",document).put("revision",revision).put("state",state).put("speech",speechState)
        if(BuildConfig.DEBUG)j.put("preparation_error",prefetch.lastFailure).put("tts_runtime",runtime.stats())
            .put("ocr_cache_hits",cacheHits).put("ocr_cache_pages",pageCache.size()).put("ahead_ready",aheadReady).put("ahead_audio_ready",prefetch.readyCount(aheadAudioKeys)).put("all_ready_audio",cached.first)
            .put("ocr_preparation_ms",JSONObject().put("verify",ocrVerifyMs).put("load",ocrLoadMs))
        if(epoch!=document)return j.toString()
        if(known!=revision){val array=JSONArray();pages.toSortedMap().forEach {(id,page)->
            // Native raw lines/verification strings are diagnostic only; do not send them every frame.
            array.put(JSONObject().put("page",id).put("page_size",page.optJSONArray("page_size"))
                .put("blocks",page.optJSONArray("blocks") ?: JSONArray()).put("state",page.optString("state"))
                .also {if(BuildConfig.DEBUG)it.put("timings_ms",page.optJSONObject("timings_ms"))})};j.put("pages",array)}
        j.toString()
    }
    fun read(epoch: Long,page: Int,block: Int,voice: String,volume: Double): Boolean {
        if(closed||!allowed()||!speechEnabled||!volume.isFinite()||volume<=0||volume>1||voice!=this.voice)return false
        val request=selected(epoch,page,block) ?: return false
        return play(request,volume,epoch)
    }
    fun preview(selectedVoice: String,selectedLanguage: String,volume: Double): Boolean {
        if(!configure(selectedVoice,selectedLanguage)||!volume.isFinite()||volume<=0||volume>1)return false
        val lang=if(selectedLanguage=="auto")"zh" else selectedLanguage
        val text=mapOf("zh" to "你好，现在开始朗读漫画。","en" to "Hello. Let's read this comic.","ja" to "こんにちは。漫画を読みましょう。").getValue(lang)
        return play(ComicSpeechPrefetch.Request("preview:$selectedVoice:$lang",text,lang,selectedVoice),volume,document)
    }
    private fun play(request: ComicSpeechPrefetch.Request,volume: Double,epoch: Long): Boolean {
        cancelSpeech();val token=speechToken.get()
        synchronized(lock){triggerAt=System.nanoTime();firstAudioMs=-1;hoverAudioMs=-1;warmHit=prefetch.ready(request.key);if(hoverKey!=request.key)hoverAt=triggerAt}
        val buffer=prefetch.prepare(request,true)
        speechWorker.execute {
            fun active()=!closed&&allowed()&&document==epoch&&speechToken.get()==token
            try {
                check(active());speechStatus("preparing")
                VoicePreviewStream(::active,output(token,volume,::active),9600).use {stream->buffer.read(::active){stream.append(it)};stream.complete()}
                if(active())speechStatus("idle")
            } catch(_: Throwable){if(active())speechStatus("error")}
        }
        return true
    }
    fun audioFocus(granted: Boolean){audioAllowed=granted;if(!granted)cancelSpeech()}
    fun cancelSpeech(){speechWorker.queue.clear();synchronized(focusLock){speechToken.incrementAndGet();wantsAudio=false;audioAllowed=false;audio?.let {runCatching {it.pause();it.flush()}}};speechStatus("idle");audioChanged()}
    fun suspend(){cancelSpeech();synchronized(lock){prefetch.clear()}}
    fun clear(){cancelSpeech();ocrWorker.queue.clear();synchronized(lock){document=0;routing.page(0);prefetch.retainCompleted();ocrToken.incrementAndGet();ComicOcrNative.cancel(handle,ocrToken.get());pages.clear();pageKeys.clear();requested.clear();state="idle";hoverKey="";hoverAt=0;firstAudioMs=-1;hoverAudioMs=-1;revision++}}
    fun release(){
        clear()
        pageCache.clear()
        // Serialize disposal after current inference/output; a new page may retain warm weights.
        ocrWorker.execute {if(document==0L){val old=handle;handle=0;ComicOcrNative.destroy(old)}}
        prefetch.clear(true)
    }
    private fun output(token: Long,gain: Double,active: ()->Boolean)=object:VoicePreviewStream.Output {
        private val outputLock=Any();private var track: AudioTrack?=null;private var stopped=false;private var first=true;private var submitted=0L;private var firstSignal=-1L;private var measured=false
        override fun start(){
            synchronized(focusLock){check(active());audioAllowed=false;wantsAudio=true};audioChanged()
            val deadline=System.nanoTime()+2_000_000_000L
            while(!audioAllowed){check(active()&&System.nanoTime()<deadline);Thread.sleep(10)}
            val value=AudioTrack.Builder().setAudioAttributes(AudioAttributes.Builder().setUsage(AudioAttributes.USAGE_MEDIA).setContentType(AudioAttributes.CONTENT_TYPE_SPEECH).build())
                .setAudioFormat(AudioFormat.Builder().setEncoding(AudioFormat.ENCODING_PCM_FLOAT).setSampleRate(48000).setChannelMask(AudioFormat.CHANNEL_OUT_STEREO).build())
                .setBufferSizeInBytes(max(76800,AudioTrack.getMinBufferSize(48000,AudioFormat.CHANNEL_OUT_STEREO,AudioFormat.ENCODING_PCM_FLOAT))).setTransferMode(AudioTrack.MODE_STREAM).build()
            synchronized(outputLock){if(stopped||!active()){value.release();error("voice_cancelled")};track=value;audio=value;value.setVolume(gain.toFloat())}
        }
        private fun measure(value: AudioTrack){
            if(measured||firstSignal<0||(value.playbackHeadPosition.toLong() and 0xffffffffL)<=firstSignal)return
            measured=true;val now=System.nanoTime()
            synchronized(lock){if(speechToken.get()==token){firstAudioMs=(now-triggerAt)/1_000_000;hoverAudioMs=(now-hoverAt)/1_000_000;speechState="speaking";revision++}}
        }
        override fun write(pcm: FloatArray){val value=track ?: error("voice_cancelled");var at=0
            if(firstSignal<0){val signal=pcm.indexOfFirst {kotlin.math.abs(it)>.001f};if(signal>=0)firstSignal=(submitted+signal)/2}
            submitted+=pcm.size
            while(at<pcm.size){check(active()&&audioAllowed);val n=value.write(pcm,at,minOf(4096,pcm.size-at),AudioTrack.WRITE_BLOCKING);check(n>0);at+=n
                if(first){check(active());first=false;value.play()};measure(value)}}
        override fun finish(samples: Int){val value=track ?: return;val deadline=System.nanoTime()+35_000_000_000L
            while((value.playbackHeadPosition.toLong() and 0xffffffffL)<samples/2){check(active()&&System.nanoTime()<deadline);measure(value);Thread.sleep(10)};measure(value)}
        override fun close(){synchronized(outputLock){if(stopped)return;stopped=true;track?.let {value->runCatching {value.pause();value.flush();value.release()};if(audio===value)audio=null};track=null}
            synchronized(focusLock){if(speechToken.get()==token)wantsAudio=false};audioChanged()}
    }
    override fun close(){if(closed)return;closed=true;clear();ocrWorker.execute {ComicOcrNative.destroy(handle);handle=0};ocrWorker.shutdown()
        prefetch.close();speechWorker.shutdown()}
}
