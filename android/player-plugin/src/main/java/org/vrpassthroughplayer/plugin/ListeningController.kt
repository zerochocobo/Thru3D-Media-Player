package org.vrpassthroughplayer.plugin

import android.content.Context
import android.os.Process
import android.util.Log
import org.json.JSONArray
import org.json.JSONObject
import java.io.File
import java.util.concurrent.Executors
import java.util.concurrent.TimeUnit

/** Single bounded ahead-reader. No microphone, PCM files, transcript log or TTS. */
internal class ListeningController(private val context: ()->Context?,private val source: ()->Source?,
                                   private val playbackChanged: ()->Unit,
                                   private val prepareAudio: (String)->Unit = {},
                                   private val audioFailure: (String)->PlaybackFailure? = {null},
                                   private val retainAudio: (String,LongArray)->Unit = {_,_->},
                                   private val input: (String)->ListeningInput? = {null}):AutoCloseable {
    data class Source(val handle: Long,val path: String,val ca: String,val allowed: Boolean,
                      val disc: Boolean,val playlist: Int,val audioDelay: Double,val directAudio: Boolean=false)
    private val lock=Any()
    private val clock=Executors.newSingleThreadScheduledExecutor {Thread(it,"ListeningClock")}
    private val worker=Executors.newSingleThreadExecutor {Thread(it,"ListeningAudio")}
    private var config=ListeningPolicy.Config()
    private var epoch=0L
    private var identity=""
    private var state="off"
    private var failure=false
    private var busy=false
    @Volatile private var closed=false
    // Preparation tracks readiness only; it never owns playback pause.
    @Volatile private var preparing=false
    @Volatile private var deadline=0L
    private var anchor=0.0
    private var through=0.0
    private var readMs=0.0
    private var inferenceMs=0.0
    @Volatile private var verifiedBytes=0L
    @Volatile private var modelBytes=0L
    @Volatile private var modelLoads=0L
    private var filteredUpdates=0L
    private var audioSpanCount=0
    private var audioGapMax=0L
    private var audioGapAverage=0L
    private var cacheHandle=0L
    private var sharedHandle=0L
    private var cacheSeconds=0.0
    @Volatile private var activeInput: ListeningInput?=null
    @Volatile private var phase="idle"
    private var position=0.0
    private var speed=1.0
    private var playing=false
    private var eof=false
    private var buffered=false
    // Recognized cues per video: covered media time is never transcribed twice.
    private var cueCache: ListeningCueCache?=null
    private var coverFrom=0.0
    private var duration=0.0
    private var modelIdentity=""
    @Volatile private var readerEpoch=-1L
    private var modelLanguage=""
    @Volatile private var engine=0L
    @Volatile private var report="{\"state\":\"off\"}"
    private val cues=linkedMapOf<String,ListeningPolicy.Cue>()
    init {clock.scheduleWithFixedDelay({runCatching {tick()}.onFailure {error->diagnose("clock",error);synchronized(lock){fail("listening_error")}}},0,100,TimeUnit.MILLISECONDS)}
    // Log only the stage and exception type, never media paths or recognized text.
    private fun diagnose(stage: String,error: Throwable){
        val reason=error.message.orEmpty().takeIf {it.matches(Regex("listening_[a-z_]+(?::-?[0-9]+)?"))}.orEmpty()
        Log.e("ListeningController","stage=$stage error=${error.javaClass.simpleName} reason=$reason")
    }
    fun configure(value: String): Boolean {
        val next=runCatching {ListeningPolicy.Config.parse(value)}.getOrNull() ?: return false
        synchronized(lock){if(closed)return false;if(config==next)return true
            config=next;invalidate();identity="";failure=false;phase=if(next.enabled)"models" else "idle";through=position;state=if(next.enabled)"preparing" else "off";publish()
            if(!next.enabled)worker.execute {if(synchronized(lock){!config.enabled&&!busy})unload()}
        }
        playbackChanged();return true
    }
    fun ready(stamp: Long){synchronized(lock){if(stamp==epoch&&buffered&&preparing){preparing=false;state="ready";publish();playbackChanged()}}}
    fun status(): String {
        val snapshot=JSONObject(report)
        val observed=snapshot.optLong("observed_ns")
        return snapshot.put("age",if(observed>0)(System.nanoTime()-observed)/1e9 else 0.0).toString()
    }
    fun transportChanged()=synchronized(lock){if(!closed&&config.enabled){invalidate();identity="";failure=false;state="preparing";publish();playbackChanged()}}
    private fun invalidate(){epoch++;cues.clear();buffered=false;eof=false;preparing=false;engine.takeIf {it>0}?.let {ListeningNative.cancel(it)}}
    private fun fail(reason: String){invalidate();failure=true;state=reason;publish();playbackChanged()}
    private fun publish(){report=JSONObject().put("epoch",epoch).put("state",state).put("buffered",buffered)
        .put("read_ms",readMs).put("inference_ms",inferenceMs).put("audio_spans",audioSpanCount)
        .put("phase",phase).put("model_progress",ListeningPolicy.percent(verifiedBytes.toDouble(),modelBytes.toDouble()))
        .put("model_loads",modelLoads).put("model_instance",engine)
        .put("buffer_progress",ListeningPolicy.percent(maxOf(0.0,through-position),ListeningPolicy.horizon(0.0,speed,config.lead)))
        .put("required_ahead",ListeningPolicy.horizon(0.0,speed,config.lead))
        .put("filtered_updates",filteredUpdates).put("io_bytes",activeInput?.bytesRead ?: 0L).put("io_reads",activeInput?.readCalls ?: 0L)
        .put("io_ms",(activeInput?.readNanos ?: 0L)/1e6)
        .put("source_io",JSONObject(activeInput?.snapshot?.invoke() ?: emptyMap<String,Long>()))
        .put("io_offset",activeInput?.offset ?: 0L).put("audio_gap_max",audioGapMax).put("audio_gap_average",audioGapAverage)
        .put("through",through).put("position",position).put("playing",playing).put("speed",speed).put("observed_ns",System.nanoTime())
        .put("cached_until",cueCache?.coveredEnd(position) ?: 0.0)
        .put("ahead",maxOf(0.0,through-position)).put("cues",JSONArray(cues.values.map {it.json()})).toString()}
    private fun tick()=synchronized(lock){
        if(closed)return@synchronized
        if(preparing&&System.nanoTime()>=deadline){preparing=false;state="catching_up";publish();playbackChanged()}
        val current=source()
        updateReadAhead(current)
        if(!config.enabled||current==null||!current.allowed){
            if(identity.isNotEmpty()){invalidate();identity="";state="off";publish();playbackChanged()}
            return@synchronized
        }
        if(failure)return@synchronized
        val outer=JSONObject(MpvSourceNative.narrationStatus(current.handle))
        val details=outer.optJSONObject("details") ?: return@synchronized
        val mediaOrigin=details.optString("demuxer_start_time").toDoubleOrNull()?.takeIf {it.isFinite()} ?: Double.NaN
        val clockValue=NarrationPolicy.playbackClock(details.put("user_audio_delay_seconds",current.audioDelay))
        val age=(System.nanoTime()-clockValue.observedNs)/1e9
        val seek=outer.optLong("seeks_started")
        if(seek!=outer.optLong("seeks_completed")||age !in 0.0..0.5){
            if(cues.isNotEmpty()){invalidate();identity="";state="preparing";publish();playbackChanged()}
            return@synchronized
        }
        speed=(details.optString("playback_speed").toDoubleOrNull() ?: 1.0).coerceIn(.25,3.0)
        playing=details.optString("paused")=="no"&&details.optString("paused_for_cache")!="yes"
        position=maxOf(0.0,clockValue.position-current.audioDelay+if(playing)age*speed else 0.0)
        duration=details.optString("duration_seconds").toDoubleOrNull()?.takeIf {it.isFinite()&&it>0} ?: 0.0
        val selected=details.optString("audio_track_id").toIntOrNull() ?: -1
        val tracks=details.optJSONArray("audio_tracks") ?: return@synchronized
        val metadata=(0 until tracks.length()).map {tracks.getJSONObject(it)}.find {it.optInt("id")==selected} ?: return@synchronized
        val track=metadata.optInt("stream_index",-1)
        if(track<0||metadata.optBoolean("external")){fail("unsupported_audio");return@synchronized}
        val key="${current.handle}:$selected:$track:$seek:${current.playlist}:${config.language}:${config.target}:${config.lead}"
        // Fast seeks can settle on an earlier keyframe after the optimistic
        // target clock was published. Do not miss that speech or wait for an
        // anchor horizon which the current-position work limit cannot reach.
        // Only once this epoch's reader is open: model loading may legitimately
        // take longer than the gap, and restarting it would never finish.
        if(identity!=key||position<anchor-.5||readerEpoch==epoch&&ListeningPolicy.behind(through,position)){
            // Already recognized media time shows at once after a seek back.
            invalidate();identity=key;anchor=maxOf(0.0,position-.25);through=maxOf(anchor,cueCache?.coveredEnd(anchor) ?: anchor)
            deadline=System.nanoTime()+45_000_000_000;preparing=true;state="preparing";playbackChanged()
        }
        if(preparing&&System.nanoTime()>=deadline){preparing=false;state="catching_up";playbackChanged()}
        cueCache?.cues(position-.25,minOf(through,position+65))?.forEach {cues[it.key]=it}
        val retained=ListeningPolicy.retain(cues.values,position);cues.clear();retained.forEach {cues[it.key]=it}
        // A seek may publish its settled position after the initial anchor.
        // Do not resume on a buffer which is already behind that position.
        buffered=eof||through>=ListeningPolicy.horizon(position,speed,config.lead)
        if(buffered&&preparing&&!config.translation){preparing=false;state="ready";playbackChanged()}
        if(!preparing)state=if(through<position+1&&!eof)"catching_up" else "ready"
        publish()
        if(busy||eof||through>=ListeningPolicy.workHorizon(anchor,position,preparing,speed,config.lead))return@synchronized
        val token=epoch;val requested=config;busy=true
        worker.execute {
            var stage="models"
            phase=stage
            try {
                Process.setThreadPriority(Process.THREAD_PRIORITY_BACKGROUND)
                if(engine==0L||modelLanguage!=requested.language){
                    unload();val app=context() ?: error("listening_unavailable")
                    val manifest=app.assets.open("moonshine/model.json").bufferedReader().use {JSONObject(it.readText())}
                        .getJSONObject("models").getJSONObject(requested.language)
                    val directory=File(app.filesDir,"listening/${requested.language}")
                    val files=manifest.getJSONObject("files");verifiedBytes=0;modelBytes=files.keys().asSequence().sumOf {files.getJSONObject(it).getLong("bytes")}
                    NarrationModels.ensure(directory,files,{app.assets.open(manifest.getString("directory")+"/"+it)},
                        {synchronized(lock){!closed&&epoch==token}}, {verifiedBytes+=it})
                    stage="model_load";phase=stage
                    engine=ListeningNative.create(directory.path,requested.language);check(engine>0);modelLoads++;modelLanguage=requested.language
                    modelIdentity=ListeningCueCache.modelIdentity(app.assets.open("moonshine/model.json").bufferedReader().use {JSONObject(it.readText())},requested.language)
                }
                if(!synchronized(lock){!closed&&token==epoch})return@execute
                stage="audio_open";phase=stage
                if(readerEpoch!=token){
                    loadCueCache(requested)
                    // Models may take seconds to initialize while the film keeps
                    // playing. Start from the latest clock, not that old position,
                    // and after any media time this video already has cues for.
                    val readingFrom=synchronized(lock){
                        anchor=maxOf(0.0,position-.25);through=maxOf(anchor,cueCache?.coveredEnd(anchor) ?: anchor);coverFrom=through;through}
                    if(synchronized(lock){token==epoch&&through>=ListeningPolicy.workHorizon(anchor,position,preparing,speed,config.lead)})return@execute
                    prepareAudio(current.path)
                    if(!synchronized(lock){
                        if(closed||token!=epoch)false else {
                            sharedHandle=current.handle;updateReadAhead(current)
                            ListeningNative.begin(engine);true
                        }
                    })return@execute
                    val directInput=if(current.directAudio)input(current.path) else null
                    activeInput=directInput
                    try {
                        ListeningNative.openWithClock(engine,current.path,track,current.ca,readingFrom,current.disc,current.playlist,mediaOrigin,current.directAudio,directInput)
                    } catch(error: Throwable){directInput?.close();throw error}
                    val spans=ListeningNative.audioSpans(engine);retainAudio(current.path,spans)
                    var totalGap=0L;audioGapMax=0L
                    for(i in 2 until spans.size step 2){val gap=spans[i]-spans[i-1];totalGap+=gap;audioGapMax=maxOf(audioGapMax,gap)}
                    audioGapAverage=if(spans.size>2)totalGap/(spans.size/2-1) else 0L
                    audioSpanCount=spans.size/2;readerEpoch=token
                }
                if(!synchronized(lock){!closed&&token==epoch})return@execute
                stage="recognition";phase=stage
                val result=JSONObject(ListeningNative.step(engine))
                synchronized(lock){if(!closed&&token==epoch){
                    val end=result.getDouble("through");require(end.isFinite()&&end>=through&&end<=through+1.01)
                    through=end;eof=result.optBoolean("eof")
                    readMs=result.optDouble("read_ms",0.0);inferenceMs=result.optDouble("inference_ms",0.0)
                    val rows=result.getJSONArray("cues")
                    for(i in 0 until minOf(rows.length(),128))ListeningPolicy.Cue.parse(rows.getJSONObject(i))?.let {cue->
                        if(!ListeningPolicy.accept(cue,requested.language))filteredUpdates++
                        else {
                            if(cue.end<=through+.01&&cue.start>=coverFrom-.01)cueCache?.add(cue)
                            if(cue.end>position&&cue.end<=through+.01&&cue.start>=anchor)cues[cue.key]=cue
                        }
                    }
                    // A line still being spoken completes in a later step; only
                    // settled time counts as covered.
                    cueCache?.cover(coverFrom,if(eof)through else through-ListeningCueCache.SETTLE_SECONDS)
                }}
            }catch(error: Throwable){
                val upstream=if(stage in setOf("audio_open","recognition")) runCatching {audioFailure(current.path)}.getOrNull() else null
                synchronized(lock){if(!closed&&token==epoch){diagnose(stage,error);fail(ListeningPolicy.failureState(stage,upstream))}}
            }
            finally {
                flushCueCache(false)
                synchronized(lock){busy=false};if(closed||!synchronized(lock){config.enabled})unload()
            }
        }
    }
    private fun unload(){
        flushCueCache(true);synchronized(lock){cueCache=null}
        val previous=engine;engine=0;readerEpoch=-1;modelLanguage="";if(previous>0)ListeningNative.destroy(previous);activeInput=null
    }
    /** Worker thread: file IO outside the lock. */
    private fun loadCueCache(requested: ListeningPolicy.Config){
        val (seconds,current)=synchronized(lock){duration to cueCache}
        if(requested.media.isEmpty()||seconds<=0||modelIdentity.isEmpty()){synchronized(lock){cueCache=null};return}
        val key=ListeningCueCache.key(requested.media,seconds,requested.language,modelIdentity)
        if(current?.key==key&&current.persistent==requested.persist)return
        flushCueCache(true)
        val directory=if(requested.persist)context()?.let {ListeningCueCache.directory(it.filesDir)} else null
        val loaded=ListeningCueCache.load(directory,key,requested.network)
        synchronized(lock){if(!closed)cueCache=loaded}
    }
    private fun flushCueCache(force: Boolean){
        val (cache,json)=synchronized(lock){cueCache.let {it to it?.snapshot(force)}}
        if(cache!=null&&json!=null)cache.write(json)
    }
    private fun updateReadAhead(current: Source?) {
        val handle=if(config.enabled&&!failure&&!closed&&current?.directAudio==true&&sharedHandle==current.handle)current.handle else 0L
        val seconds=if(handle>0)ListeningPolicy.horizon(0.0,speed,config.lead) else 0.0
        if(cacheHandle>0&&cacheHandle!=handle)runCatching {MpvSourceNative.setListeningCache(cacheHandle,0.0)}
        if(handle>0&&(handle!=cacheHandle||seconds!=cacheSeconds)){
            // A rejected command is not an applied policy. Retry against the
            // next valid source snapshot instead of silently retaining it.
            if(!runCatching {MpvSourceNative.setListeningCache(handle,seconds)}.getOrDefault(false))return
        }
        cacheHandle=handle;cacheSeconds=seconds
    }
    override fun close(){synchronized(lock){if(closed)return;closed=true;invalidate();updateReadAhead(null);state="off";publish()};clock.shutdownNow();worker.execute {unload()};worker.shutdown();playbackChanged()}
}
