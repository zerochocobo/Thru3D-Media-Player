package org.vrpassthroughplayer.plugin

import android.content.ContentValues
import android.content.Context
import android.net.Uri
import android.os.StatFs
import android.provider.MediaStore
import org.json.JSONObject
import java.io.File
import java.text.SimpleDateFormat
import java.util.Date
import java.util.Locale
import java.util.concurrent.ConcurrentHashMap
import java.util.concurrent.atomic.AtomicInteger

/** Captures existing playback outputs. This class never resolves a media URI,
 * opens a network/audio reader, or calls the subtitle synthesis engine. */
internal class LiveClipCapture(private val context: ()->Context?,private val owner: (Int)->Long,
                               private val flushAudio: (Int)->Unit,private val retainPip: (Int)->File?,
                               private val releasePip: (Int)->Unit,private val result: (Int,String)->Unit) {
    private class Job(val request: JSONObject, val timeline: PipClipTimeline) {
        @Volatile var nativeId=0L
        @Volatile var stopped=false
        @Volatile var stopNs=0L
        @Volatile var endUs=0L
        val task=ClipExportTask()
        val progress=AtomicInteger()
        @Volatile var copying=false
        var copyLimit=99
        var position=request.getLong("start_us")
        var ns=System.nanoTime()
        var playing=request.optBoolean("playing")
        @Volatile var failure: String?=null
    }
    private val jobs=ConcurrentHashMap<Int,Job>()
    @Volatile private var closed=false
    fun prepare(id: Int,request: JSONObject){
        val job=Job(request,PipClipTimeline(request.getLong("start_us"),retainPip,releasePip));jobs[id]=job
        if(request.optJSONObject("mode")?.optInt("geometry", -1)!=0&&request.has("pip"))pip(id,request.getLong("start_us"),request.getJSONObject("pip").toString())
    }
    fun pip(id: Int,position: Long,recipe: String) {
        val job=jobs[id] ?: return
        synchronized(job) {
            if(job.stopped||job.failure!=null||job.request.optJSONObject("mode")?.optInt("geometry", -1)==0)return
            try {job.timeline.add(position,JSONObject(recipe))}
            catch(error: Exception){
                job.failure=error.message?.takeIf{it in errors} ?: "Picture in picture recording unavailable"
                if(PlaybackPrivacy.diagnostics)android.util.Log.w("Thru3DCapture",JSONObject().put("kind","pip_recipe")
                    .put("position_us",position).put("error",job.failure).put("exception",error.javaClass.simpleName)
                    .put("location",error.stackTrace.firstOrNull()?.toString()).toString())
            }
        }
    }
    fun clock(id: Int,position: Long,playing: Boolean) {
        val job=jobs[id] ?: return
        synchronized(job){job.position=position;job.ns=System.nanoTime();job.playing=playing}
        if(job.nativeId>0)LiveCaptureNative.clock(job.nativeId,position,playing)
    }
    fun stop(id: Int,end: Long): Boolean {
        val job=jobs[id] ?: return false
        if(job.stopped)return false
        synchronized(job){job.endUs=end;job.stopNs=System.nanoTime();job.stopped=true}
        if(job.nativeId>0)LiveCaptureNative.limit(job.nativeId,end,job.stopNs)
        return true
    }
    fun cancel(id: Int): Boolean {
        val job=jobs[id] ?: return false
        if(!job.stopped)return false
        return job.task.cancel { if(job.nativeId>0)LiveCaptureNative.cancel(job.nativeId) }
    }
    fun progress(id: Int): Int {
        val job=jobs[id] ?: return -1
        if(!job.stopped)return -1
        if(job.copying)advance(job,LiveCaptureNative.exportProgress(job.nativeId).coerceIn(0,100)*job.copyLimit/100)
        return job.progress.get()
    }
    private fun advance(job: Job,percent: Int) { job.progress.accumulateAndGet(percent.coerceIn(0,99),::maxOf) }
    fun run(id: Int) {
        val job=jobs[id] ?: return
        var nativeId=0L;var prefix: File?=null;var pending: Uri?=null;var app: Context?=null
        var terminal: JSONObject?=null
        fun publish(value: JSONObject){result(id,value.put("kind","clip").toString())}
        try {
            android.os.Process.setThreadPriority(android.os.Process.THREAD_PRIORITY_BACKGROUND)
            job.task.checkActive()
            check(!closed&&!job.stopped){"Recording is empty"}
            check(job.failure==null){job.failure!!}
            app=context() ?: error("Capture unavailable")
            require(StatFs(app.cacheDir.path).availableBytes>128L*1024*1024){"Not enough storage"}
            val mode=CaptureFormat.clean(job.request.getJSONObject("mode"), allowFlat = true)
            val key=owner(job.request.getInt("session_id"))
            check(key!=0L){"Capture source unavailable"}
            prefix=File.createTempFile("live-clip-","",app.cacheDir)
            val anchor=synchronized(job){Pair(job.position+if(job.playing)(System.nanoTime()-job.ns)/1000 else 0L,job.playing)}
            nativeId=LiveCaptureNative.start(key,prefix.path,anchor.first,anchor.second)
            check(nativeId>0){"Keyframe unavailable for recording"}
            job.nativeId=nativeId;LiveCaptureNative.audioFailed=false;LiveCaptureNative.recording=true
            var state=JSONObject(LiveCaptureNative.status(nativeId));publish(state)
            while(!job.stopped&&!closed&&state.optString("state")=="recording") {
                Thread.sleep(60)
                check(job.failure==null){job.failure!!}
                check(!LiveCaptureNative.audioFailed){"Capture audio format unavailable"}
                state=JSONObject(LiveCaptureNative.status(nativeId))
                publish(state)
            }
            check(!closed){"Clip export cancelled"}
            // Seal samples before exporting, including automatic native EOF/source-close completion.
            synchronized(job){job.stopped=true}
            publish(JSONObject().put("state","saving").put("progress",0))
            job.task.checkActive()
            check(job.failure==null){job.failure!!}
            // Join only the narrator's tiny heard-PCM flush on this worker, never the Godot thread.
            flushAudio(job.request.getInt("session_id"))
            job.task.checkActive()
            check(!LiveCaptureNative.audioFailed){"Capture audio format unavailable"}
            LiveCaptureNative.recording=false
            if(job.stopNs>0)LiveCaptureNative.stop(nativeId,job.endUs,job.stopNs)
            val deadline=System.nanoTime()+60_000_000_000L
            do {
                job.task.checkActive()
                state=JSONObject(LiveCaptureNative.status(nativeId))
                check(state.optString("state")!="error"){state.optString("error","Capture save failed")}
                check(System.nanoTime()<deadline){"Capture save failed"}
                if(state.optString("state")!="ready")Thread.sleep(10)
            }while(state.optString("state")!="ready")
            check(state.optLong("audio_duration_us")>0){"Recording is empty"}
            job.task.checkActive()
            val directory="Movies/Thru3D"
            val name="recording_"+SimpleDateFormat("yyyyMMdd_HHmmss_SSS",Locale.ROOT).format(Date())+".mkv"
            val resolver=app.contentResolver
            pending=resolver.insert(MediaStore.Video.Media.getContentUri(MediaStore.VOLUME_EXTERNAL_PRIMARY),ContentValues().apply {
                put(MediaStore.MediaColumns.DISPLAY_NAME,name);put(MediaStore.MediaColumns.MIME_TYPE,"video/x-matroska")
                put(MediaStore.MediaColumns.RELATIVE_PATH,directory);put(MediaStore.MediaColumns.IS_PENDING,1)
            }) ?: error("Capture save failed")
            val saved=resolver.openFileDescriptor(pending,"rw")!!.use {fd->
                val composed=job.timeline.composed
                job.copyLimit=if(composed)20 else 99
                job.copying=true
                if(composed) {
                    val local=File(prefix.path+".source.mkv")
                    val original=JSONObject(LiveCaptureNative.export(nativeId,local.path,mode.toString()))
                    job.copying=false
                    job.task.checkActive()
                    check(original.optString("state")=="saved"){original.optString("error","Capture save failed")}
                    advance(job,20)
                    PipClipEncoder.encode(local,File(prefix.path+".pip.mp4"),"/proc/self/fd/${fd.fd}",
                        original.getLong("start_us"),mode,job.timeline,original.getLong("end_us")-original.getLong("start_us"),
                        java.util.function.BooleanSupplier{closed||job.task.cancelled}) {percent->advance(job,20+percent.coerceIn(0,100)*79/100)}
                        .put("start_us",original.getLong("start_us")).put("end_us",original.getLong("end_us"))
                        .put("capture_metrics",original.optJSONObject("capture_metrics"))
                } else JSONObject(LiveCaptureNative.export(nativeId,"/proc/self/fd/${fd.fd}",mode.toString())).also {job.copying=false}
            }
            job.task.checkActive()
            check(!closed){"Clip export cancelled"}
            check(saved.optString("state")=="saved"){saved.optString("error","Capture save failed")}
            advance(job,99)
            val destination=checkNotNull(pending)
            job.task.commit {
                check(resolver.update(destination,ContentValues().apply{put(MediaStore.MediaColumns.IS_PENDING,0)},null,null)==1){"Capture save failed"}
                terminal=saved.put("uri",destination.toString()).put("directory",directory).put("name",name).put("audio_capture","live").put("progress",100)
                pending=null
            }
        }catch(failure: Throwable){
            val reason=failure.message?.takeIf{it in errors} ?: "Capture save failed"
            if(PlaybackPrivacy.diagnostics)android.util.Log.w("Thru3DCapture",JSONObject().put("kind","live_clip")
                .put("native_started",nativeId>0).put("error",reason).put("exception",failure.javaClass.simpleName).toString())
            terminal=JSONObject().put("state","error").put("error",reason)
        }
        finally {
            synchronized(job){job.stopped=true}
            job.copying=false
            LiveCaptureNative.recording=false
            var cleanupFailed=false
            if(nativeId>0&&runCatching{LiveCaptureNative.forget(nativeId)}.isFailure)cleanupFailed=true
            pending?.let{if(runCatching{app?.contentResolver?.delete(it,null,null)}.getOrNull()!=1)cleanupFailed=true}
            prefix?.let{base->listOf(".mkv",".wav",".idx",".source.mkv",".pip.mp4","").forEach{
                val file=File(base.path+it);if(file.exists()&&!file.delete())cleanupFailed=true
            }}
            if(runCatching{job.timeline.close()}.isFailure)cleanupFailed=true
            val cancelled=job.task.finish()
            jobs.remove(id)
            publish(if(cleanupFailed)JSONObject().put("state","error").put("error","Capture save failed")
                else if(cancelled)JSONObject().put("state","cancelled")
                else terminal ?: JSONObject().put("state","error").put("error","Capture save failed"))
        }
    }
    fun close(){closed=true;LiveCaptureNative.recording=false;jobs.values.forEach{job->job.stopped=true;job.task.cancel{if(job.nativeId>0)runCatching{LiveCaptureNative.cancel(job.nativeId)}}}}
    companion object {
        private val errors=setOf("Recording is empty","Recording is too short","Capture source unavailable","Capture unavailable",
            "Capture save failed","Clip export cancelled","Not enough storage","Keyframe unavailable for recording",
            "Capture writer could not keep up","Capture audio format unavailable","Capture audio clock unavailable","Capture clock stalled","Lossless container unavailable","Clip export failed","Clip timestamps unavailable",
            "Picture in picture capture unavailable","Picture in picture recording unavailable","Picture in picture recording limit reached","HDR picture in picture recording unavailable")
    }
}
