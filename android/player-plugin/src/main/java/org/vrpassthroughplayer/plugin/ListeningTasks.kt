package org.vrpassthroughplayer.plugin

import android.app.ActivityManager
import android.content.Context
import android.net.Uri
import android.os.ParcelFileDescriptor
import android.os.PowerManager
import android.os.Process
import org.json.JSONArray
import org.json.JSONObject
import java.io.File
import java.nio.file.Files
import java.nio.file.StandardCopyOption
import java.util.concurrent.Executors
import java.util.concurrent.TimeUnit

/** App-scoped subtitle queue. One audio worker, independent of playback ownership.
 * Translation transport is shared by the Godot clients and feeds this result store. */
internal class ListeningTasks(private val context: ()->Context?,private val resolve: (String)->String,
    private val retain: (String)->String?,private val shared: (String)->String?,private val release: (String)->Unit,
    private val prepare: (String)->Unit,private val input: (String)->ListeningInput?,private val spans: (String,LongArray)->Unit):AutoCloseable {
    private class Job(val id: String,val spec: ListeningTaskSpec) {
        var state="queued";var manual=false;var reason="";var cache: ListeningCueCache?=null
        var speed=0.0;var phase="";var priority=false;var failures=0;var loading=false
    }
    private val lock=Any()
    private val jobs=linkedMapOf<String,Job>()
    private val worker=Executors.newSingleThreadExecutor{Thread(it,"SubtitleFilm")}
    private val io=Executors.newSingleThreadExecutor{Thread(it,"SubtitleStore")}
    private val clock=Executors.newSingleThreadScheduledExecutor{Thread(it,"SubtitleQueue")}
    @Volatile private var closed=false
    @Volatile private var active=true
    @Volatile private var foreground=JSONObject()
    @Volatile private var engine=0L
    @Volatile private var activeInput: ListeningInput?=null
    @Volatile private var cancelled=false
    private var running: Job?=null
    private var allPaused=false
    private var policy="playback"
    private var loaded=false
    private var revision=0L
    private val accountChanged: ()->Unit={synchronized(lock){jobs.values.filter{it.spec.network}.forEach{it.manual=true;it.reason="source_unavailable";if(it.state !in setOf("complete","cancelled"))it.state="paused"};cancelActive();changed()}}
    init {
        CloudAccountChanges.subscribe(accountChanged)
        io.execute{restore();synchronized(lock){loaded=true}}
        clock.scheduleWithFixedDelay({runCatching{tick()}.onFailure{android.util.Log.e("SubtitleQueue","clock ${it.javaClass.simpleName}")}},100,100,TimeUnit.MILLISECONDS)
    }
    private fun file()=context()?.let{File(it.filesDir,"listening-tasks.json")}
    private fun changed(){revision++;saveLater()}
    private fun saveLater(){if(closed)return;runCatching{io.execute{save()}}}
    private fun save(){
        val file=file() ?: return
        val rows=synchronized(lock){JSONArray(jobs.values.filter{it.spec.durable&&it.state!="cancelled"}.map{JSONObject().put("id",it.id).put("spec",it.spec.json())})}
        runCatching{
            val temporary=File(file.parentFile,file.name+".tmp")
            temporary.outputStream().use{it.write(JSONObject().put("schema",1).put("jobs",rows).toString().toByteArray());it.fd.sync()}
            Files.move(temporary.toPath(),file.toPath(),StandardCopyOption.REPLACE_EXISTING,StandardCopyOption.ATOMIC_MOVE)
        }.onFailure{synchronized(lock){jobs.values.filter{it.spec.durable}.forEach{it.reason="queue_write_error"};revision++}}
    }
    private fun restore(){
        val file=file() ?: return
        if(!file.isFile || file.length()>1024*1024)return
        runCatching{
            val json=JSONObject(file.readText());require(json.getInt("schema")==1)
            val rows=json.getJSONArray("jobs");require(rows.length()<=32)
            val restored=(0 until rows.length()).map{val row=rows.getJSONObject(it);val spec=ListeningTaskSpec.parse(row.getJSONObject("spec"));Job(row.getString("id"),spec).also{j->j.manual=true;j.state="paused"}}
            synchronized(lock){restored.filter{it.spec.durable}.forEach{jobs.putIfAbsent(it.id,it)};revision++}
        }
    }
    fun enqueue(spec: ListeningTaskSpec): Boolean=synchronized(lock){
        if(closed||!loaded)return@synchronized false
        val existing=jobs.values.firstOrNull{it.spec.media==spec.media&&it.spec.language==spec.language&&it.spec.target==spec.target&&it.spec.track==spec.track&&it.spec.playlist==spec.playlist&&it.spec.duration==spec.duration&&it.spec.model==spec.model}
        if(existing!=null){existing.manual=false;existing.reason="";if(existing.state!="complete")existing.state="queued";changed();return@synchronized true}
        if(jobs.size>=32)return@synchronized false
        val id=java.util.UUID.randomUUID().toString();jobs[id]=Job(id,spec);changed();true
    }
    fun command(j: JSONObject): Boolean=synchronized(lock){
        if(closed)return@synchronized false
        val op=j.optString("operation");val job=jobs[j.optString("id")]
        when(op){
            "context"->{
                foreground=JSONObject(j.toString());policy=j.optString("policy","playback")
                // Privacy policy changes only reduce an existing job's persistence.
                val memory=j.optString("memory","all")
                val remove=jobs.values.filter{(memory=="none"&&it.spec.persist)||(memory=="local"&&it.spec.network&&it.spec.persist)||(j.optBoolean("protected_locked")&&!it.spec.persist)}
                if(remove.contains(running))cancelActive()
                if(remove.isNotEmpty()){remove.forEach{jobs.remove(it.id);val cache=it.cache;cache?.invalidate();io.execute{cache?.revoke()}};changed()}
                running?.let{if(blocked(it).isNotEmpty())cancelActive();delegate(it)}
                return@synchronized true
            }
            "translation_error"->{if(job==null)return@synchronized false;job.state="error";job.reason="translation_error";if(running===job)cancelActive()}
            "pause_all"->{allPaused=true;cancelActive()}
            "resume_all"->{allPaused=false;jobs.values.filter{it.state!="complete"&&it.state!="cancelled"}.forEach{it.manual=false;it.reason="";it.cache?.retry();if(it.state!="listening")it.state="queued"}}
            "clear_done"->{jobs.entries.removeAll{it.value.state in setOf("complete","cancelled")}}
            "pause"->{if(job==null)return@synchronized false;job.manual=true;job.state="paused";if(running===job)cancelActive()}
            "resume","retry"->{if(job==null)return@synchronized false;job.manual=false;job.reason="";job.failures=0;job.cache?.retry();job.state="queued"}
            "cancel"->{if(job==null)return@synchronized false;job.manual=true;job.state="cancelled";if(running===job)cancelActive()}
            "first"->{if(job==null)return@synchronized false;val old=jobs.toMap();jobs.clear();jobs[job.id]=job;old.filterKeys{it!=job.id}.forEach{(id,value)->jobs[id]=value};if(running!==job)cancelActive()}
            "remove"->{if(job==null)return@synchronized false;if(running===job)cancelActive();jobs.remove(job.id)}
            else->return@synchronized false
        };changed();true
    }
    private fun delegated(job: Job)=ListeningTaskPolicy.delegated(job.spec,foreground)
    private fun blocked(job: Job)=ListeningTaskPolicy.blocked(job.spec,foreground,active,allPaused,job.manual,policy)
    private fun resourcePressure(): Boolean {
        val app=context() ?: return true
        val memory=ActivityManager.MemoryInfo();(app.getSystemService(Context.ACTIVITY_SERVICE) as ActivityManager).getMemoryInfo(memory)
        return memory.lowMemory || memory.availMem<256L*1024*1024 || (app.getSystemService(Context.POWER_SERVICE) as PowerManager).currentThermalStatus>=PowerManager.THERMAL_STATUS_SEVERE
    }
    private fun tick()=synchronized(lock){
        if(closed || !loaded)return@synchronized
        // Loading existing text does not need a media connection. In particular,
        // a queued film may translate its cached originals while another film plays.
        if(active&&!allPaused&&!foreground.optBoolean("protected_locked")&&!resourcePressure()&&jobs.values.none{it.loading}){
            jobs.values.firstOrNull{it.cache==null&&!it.manual&&it.state !in setOf("complete","cancelled","error")}?.let{job->
                job.loading=true
                io.execute{
                    try{cache(job)}catch(error:Exception){synchronized(lock){job.state="error";job.reason=if(error.message=="model_changed")"model_changed" else "cache_read_error"}}
                    finally{synchronized(lock){job.loading=false;revision++}}
                }
            }
        }
        if(running!=null){if(resourcePressure()){running?.reason="resources";cancelActive()};return@synchronized}
        ListeningWorkGate.delegatedMedia=""
        jobs.values.filter{!it.manual && it.state !in setOf("complete","cancelled","error") && it.cache?.analyzed(it.spec.duration)==true}.forEach{
            val cache=it.cache!!;it.state=if(cache.complete(it.spec.duration) && (it.spec.target.isEmpty() || cache.translated(it.spec.target)==cache.count()&&cache.translationsSaved()))"complete" else "translating"
        }
        val job=jobs.values.firstOrNull{it.state !in setOf("complete","cancelled","error") && !it.manual && blocked(it).isEmpty() && it.cache!=null && !it.loading && it.cache?.analyzed(it.spec.duration)!=true}
        if(job==null)return@synchronized
        if(resourcePressure()){if(job.reason!="resources"){job.reason="resources";revision++};return@synchronized}
        running=job;cancelled=false;job.state="listening";job.reason="";revision++
        delegate(job)
        worker.execute{run(job)}
    }
    private fun cache(job: Job): ListeningCueCache {
        job.cache?.takeIf{!it.revoked}?.let{return it}
        val app=context() ?: error("source_unavailable")
        val manifest=app.assets.open("moonshine/model.json").bufferedReader().use{JSONObject(it.readText())}
        val model=ListeningCueCache.modelIdentity(manifest,job.spec.language)
        if(job.spec.model.isNotEmpty()&&job.spec.model!=model)error("model_changed")
        val key=ListeningCueCache.key(job.spec.media,job.spec.duration,job.spec.language,model,job.spec.track,job.spec.playlist)
        return ListeningCueCache.obtain(if(job.spec.persist)ListeningCueCache.directory(app.filesDir) else null,key,job.spec.network).also{job.cache=it}
    }
    private fun shouldStop(job: Job)=cancelled || closed || synchronized(lock){jobs[job.id]!==job || job.state=="error" || blocked(job).isNotEmpty()}
    private fun delegate(job: Job){
        ListeningWorkGate.delegatedMedia=""
        if(delegated(job)&&!cancelled){
            ListeningWorkGate.delegatedLanguage=job.spec.language;ListeningWorkGate.delegatedTrack=job.spec.track
            ListeningWorkGate.delegatedPlaylist=job.spec.playlist;ListeningWorkGate.delegatedMedia=job.spec.media
        }
    }
    private fun run(job: Job){
        var resolved="";var descriptor: ParcelFileDescriptor?=null
        try {
            Process.setThreadPriority(Process.THREAD_PRIORITY_BACKGROUND)
            val app=context() ?: error("source_unavailable");val cache=cache(job)
            if(cache.analyzed(job.spec.duration)){finishJob(job);return}
            if(shouldStop(job))return
            job.phase="models"
            val bundle=app.assets.open("moonshine/model.json").bufferedReader().use{JSONObject(it.readText())}.getJSONObject("models").getJSONObject(job.spec.language)
            val directory=File(app.filesDir,"listening/${job.spec.language}")
            NarrationModels.ensure(directory,bundle.getJSONObject("files"),{app.assets.open(bundle.getString("directory")+"/"+it)},{!shouldStop(job)},{})
            if(shouldStop(job))return
            job.phase="model_load"
            engine=synchronized(ListeningWorkGate.lock){ListeningNative.create(directory.path,job.spec.language)};check(engine>0)
            if(shouldStop(job))return
            job.phase="audio_open"
            resolved=shared(job.spec.uri)?.let(retain) ?: resolve(job.spec.uri)
            val uri=Uri.parse(resolved)
            val path=when(uri.scheme){
                "file"->uri.path ?: error("source_unavailable")
                "content"->{descriptor=app.contentResolver.openFileDescriptor(uri,"r") ?: error("source_unavailable");"/proc/self/fd/${descriptor!!.fd}"}
                "http","https"->resolved
                else->error("source_unavailable")
            }
            prepare(resolved)
            val ca=MpvTlsTrust.prepare(app)
            var through=-100.0;var coverFrom=0.0;var readerFrom=0.0
            val began=System.nanoTime();val initial=cache.coveredSeconds(job.spec.duration)
            while(!shouldStop(job) && !cache.analyzed(job.spec.duration)){
                var need=cache.firstGap(job.spec.duration)
                if(need>=job.spec.duration)need=maxOf(0.0,job.spec.duration-1)
                if(delegated(job)){
                    val position=foreground.optDouble("position",0.0).coerceIn(0.0,job.spec.duration)
                    val ahead=(cache.coveredEnd(position) ?: position)-position
                    job.priority=ahead < if(job.priority)60.0 else foreground.optDouble("lead",12.0)+8.0
                    if(job.priority)need=cache.firstGap(job.spec.duration,position)
                }else job.priority=false
                if(ListeningTaskPolicy.reopen(need,through,coverFrom,readerFrom)){
                    coverFrom=need;readerFrom=maxOf(0.0,need-ListeningCueCache.SETTLE_SECONDS);through=readerFrom
                    activeInput?.close();activeInput=input(resolved)
                    ListeningNative.begin(engine)
                    synchronized(ListeningWorkGate.lock){ListeningNative.openWithClock(engine,path,job.spec.track,ca,readerFrom,job.spec.disc,job.spec.playlist,job.spec.origin,true,activeInput)}
                    spans(resolved,ListeningNative.audioSpans(engine))
                }
                if(shouldStop(job))break
                job.phase="recognition"
                val result=JSONObject(synchronized(ListeningWorkGate.lock){ListeningNative.step(engine)})
                if(shouldStop(job))break
                val end=result.getDouble("through");require(end.isFinite()&&end>=through&&end<=through+1.01);through=end
                val actualDuration=result.optDouble("duration",0.0)
                if(actualDuration>0 && kotlin.math.abs(actualDuration-job.spec.duration)>2.0)error("source_changed")
                if(cache.revoked)break
                val rows=result.getJSONArray("cues")
                for(i in 0 until rows.length())ListeningPolicy.Cue.parse(rows.getJSONObject(i))?.takeIf{it.end>coverFrom&&ListeningPolicy.accept(it,job.spec.language)}?.let(cache::add)
                cache.cover(coverFrom,minOf(job.spec.duration,result.getDouble("settled")))
                if(result.getBoolean("eof")){cache.finish(through,job.spec.duration,result.optDouble("audio_end",0.0).takeIf{it>0} ?: job.spec.duration);through=-100.0}
                if(!cache.flush(result.getBoolean("eof")))error(cache.error)
                if(cache.error.isNotEmpty())error(cache.error)
                job.speed=(cache.coveredSeconds(job.spec.duration)-initial)/((System.nanoTime()-began)/1e9).coerceAtLeast(.001)
                synchronized(lock){revision++}
            }
            if(!shouldStop(job)&&cache.analyzed(job.spec.duration))finishJob(job)
        }catch(error:Throwable){
            if(!shouldStop(job))synchronized(lock){job.state="error";job.reason=error.message?.takeIf{it in setOf("source_changed","source_incomplete","model_changed","cache_full","cache_write_error")} ?: "source_unavailable";revision++}
        }finally{
            val previous=engine;engine=0
            if(previous>0)runCatching{synchronized(ListeningWorkGate.lock){ListeningNative.destroy(previous)}}
            activeInput=null;runCatching{descriptor?.close()};if(resolved.isNotEmpty())runCatching{release(resolved)}
            if(job.cache?.revoked!=true)job.cache?.flush(true)
            synchronized(lock){
                if(job.state=="listening"){job.state=if(job.manual)"paused" else "queued";job.reason=blocked(job)}
                running=null;ListeningWorkGate.delegatedMedia="";changed()
            }
        }
    }
    private fun finishJob(job: Job){
        val cache=job.cache ?: return
        if(!cache.flush(true)){job.state="error";job.reason=cache.error;return}
        synchronized(lock){if(shouldStop(job))return;job.state=if(cache.complete(job.spec.duration)&&(job.spec.target.isEmpty() || cache.translated(job.spec.target)==cache.count()&&cache.translationsSaved()))"complete" else "translating";revision++}
    }
    /** Returns bounded finalized original lines; callers never enqueue the entire film at once. */
    fun translationWork(): String=synchronized(lock){
        if(!active || allPaused || closed || foreground.optBoolean("protected_locked"))return@synchronized "{}"
        for(job in jobs.values){
            if(job.manual || job.state in setOf("cancelled","complete","error") || job.spec.target.isEmpty())continue
            val cache=job.cache ?: continue
            val pending=cache.pending(job.spec.target)
            if(pending.isEmpty())continue
            return@synchronized JSONObject().put("id",job.id).put("cache_key",cache.key).put("cache_instance",cache.instance)
                .put("language",job.spec.language).put("target",job.spec.target).put("cues",cache.rows(pending,job.spec.target)).toString()
        };"{}"
    }
    fun translations(j: JSONObject): Boolean {
        val cache=ListeningCueCache.find(j.optString("cache_key"),j.optLong("cache_instance")) ?: return false
        val rows=j.optJSONArray("rows") ?: return false
        if(rows.length()>64)return false
        for(i in 0 until rows.length()){val row=rows.getJSONObject(i);cache.translate(row.getString("text"),j.getString("target"),row.getString("translation"))}
        io.execute{
            val saved=cache.flush(true)
            synchronized(lock){jobs.values.filter{it.cache===cache && !it.manual && it.state !in setOf("error","cancelled")}.forEach{job->
                if(!saved){job.state="error";job.reason=cache.error}
                else if(cache.complete(job.spec.duration) && cache.translated(job.spec.target)==cache.count() && cache.translationsSaved())job.state="complete"
            };revision++}
        };return true
    }
    fun status(): String=synchronized(lock){
        JSONObject().put("revision",revision).put("paused",allPaused).put("loaded",loaded).put("jobs",JSONArray(jobs.values.map{job->
            val cache=job.cache;val original=cache?.complete(job.spec.duration)==true
            JSONObject().put("id",job.id).put("media",job.spec.media).put("title",job.spec.title).put("language",job.spec.language).put("target",job.spec.target)
                .put("track",job.spec.track).put("playlist",job.spec.playlist).put("state",job.state).put("reason",if(job.state !in setOf("complete","cancelled","error")&&(!active||allPaused||job.manual))"paused" else if(job.state in setOf("queued","listening"))blocked(job).ifEmpty{job.reason} else job.reason)
                .put("phase",job.phase).put("progress",ListeningPolicy.percent(cache?.coveredSeconds(job.spec.duration) ?: 0.0,job.spec.duration).coerceAtMost(if(original)100 else 99))
                .put("original_complete",original).put("translated",cache?.translated(job.spec.target) ?: 0).put("total",cache?.count() ?: 0)
                .put("speed",job.speed).put("persistent",job.spec.persist)
                .put("current",ListeningTaskPolicy.same(job.spec,foreground)&&foreground.optInt("track",-1)==job.spec.track&&foreground.optInt("playlist",-1)==job.spec.playlist)
        })).toString()
    }
    private fun cancelActive(){cancelled=true;val value=engine;if(value>0)runCatching{ListeningNative.cancel(value)};val reader=activeInput;if(reader!=null)runCatching{io.execute{runCatching{reader.close()}}}}
    fun foreground(value: Boolean)=synchronized(lock){active=value;if(!value){allPaused=true;cancelActive()};revision++}
    fun clear(networkOnly: Boolean)=synchronized(lock){if(running?.let{!networkOnly||it.spec.network}==true)cancelActive();jobs.entries.removeAll{!networkOnly||it.value.spec.network};changed()}
    override fun close(){synchronized(lock){closed=true;cancelActive()};CloudAccountChanges.unsubscribe(accountChanged);clock.shutdownNow();worker.execute{io.execute{save()};io.shutdown()};worker.shutdown()}
}
