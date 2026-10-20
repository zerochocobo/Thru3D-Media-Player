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

/** Captures existing playback outputs. This class never resolves a media URI,
 * opens a network/audio reader, or calls the subtitle synthesis engine. */
internal class LiveClipCapture(private val context: ()->Context?,private val owner: (Int)->Long,
                               private val flushAudio: (Int)->Unit,private val result: (Int,String)->Unit) {
    private class Job(val request: JSONObject) {
        @Volatile var nativeId=0L
        @Volatile var stopped=false
        @Volatile var stopNs=0L
        @Volatile var endUs=0L
        var position=request.getLong("start_us")
        var ns=System.nanoTime()
        var playing=request.optBoolean("playing")
    }
    private val jobs=ConcurrentHashMap<Int,Job>()
    @Volatile private var closed=false
    fun prepare(id: Int,request: JSONObject){jobs[id]=Job(request)}
    fun clock(id: Int,position: Long,playing: Boolean) {
        val job=jobs[id] ?: return
        synchronized(job){job.position=position;job.ns=System.nanoTime();job.playing=playing}
        if(job.nativeId>0)LiveCaptureNative.clock(job.nativeId,position,playing)
    }
    fun stop(id: Int,end: Long): Boolean {
        val job=jobs[id] ?: return false
        if(job.stopped)return false
        job.endUs=end;job.stopNs=System.nanoTime();job.stopped=true
        if(job.nativeId>0)LiveCaptureNative.limit(job.nativeId,end,job.stopNs)
        return true
    }
    fun run(id: Int) {
        val job=jobs[id] ?: return
        var nativeId=0L;var prefix: File?=null;var pending: Uri?=null;var app: Context?=null
        fun publish(value: JSONObject){result(id,value.put("kind","clip").toString())}
        try {
            android.os.Process.setThreadPriority(android.os.Process.THREAD_PRIORITY_BACKGROUND)
            check(!closed&&!job.stopped){"Recording is empty"}
            app=context() ?: error("Capture unavailable")
            require(StatFs(app.cacheDir.path).availableBytes>128L*1024*1024){"Not enough storage"}
            val mode=CaptureFormat.clean(job.request.getJSONObject("mode"))
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
                check(!LiveCaptureNative.audioFailed){"Capture audio format unavailable"}
                state=JSONObject(LiveCaptureNative.status(nativeId))
                publish(state)
            }
            check(!closed){"Clip export cancelled"}
            // Join only the narrator's tiny heard-PCM flush on this worker, never the Godot thread.
            flushAudio(job.request.getInt("session_id"))
            check(!LiveCaptureNative.audioFailed){"Capture audio format unavailable"}
            LiveCaptureNative.recording=false
            if(job.stopped)LiveCaptureNative.stop(nativeId,job.endUs,job.stopNs)
            val deadline=System.nanoTime()+60_000_000_000L
            do {
                state=JSONObject(LiveCaptureNative.status(nativeId))
                check(state.optString("state")!="error"){state.optString("error","Capture save failed")}
                check(System.nanoTime()<deadline){"Capture save failed"}
                if(state.optString("state")!="ready")Thread.sleep(10)
            }while(state.optString("state")!="ready")
            check(state.optLong("audio_duration_us")>0){"Recording is empty"}
            publish(JSONObject().put("state","saving"))
            val directory="Movies/Thru3D"
            val name="recording_"+SimpleDateFormat("yyyyMMdd_HHmmss_SSS",Locale.ROOT).format(Date())+".mkv"
            val resolver=app.contentResolver
            pending=resolver.insert(MediaStore.Video.Media.getContentUri(MediaStore.VOLUME_EXTERNAL_PRIMARY),ContentValues().apply {
                put(MediaStore.MediaColumns.DISPLAY_NAME,name);put(MediaStore.MediaColumns.MIME_TYPE,"video/x-matroska")
                put(MediaStore.MediaColumns.RELATIVE_PATH,directory);put(MediaStore.MediaColumns.IS_PENDING,1)
            }) ?: error("Capture save failed")
            val saved=resolver.openFileDescriptor(pending,"rw")!!.use {fd->
                JSONObject(LiveCaptureNative.export(nativeId,"/proc/self/fd/${fd.fd}",mode.toString()))
            }
            check(!closed){"Clip export cancelled"}
            check(saved.optString("state")=="saved"){saved.optString("error","Capture save failed")}
            check(resolver.update(pending,ContentValues().apply{put(MediaStore.MediaColumns.IS_PENDING,0)},null,null)==1){"Capture save failed"}
            publish(saved.put("uri",pending.toString()).put("directory",directory).put("name",name).put("audio_capture","live"))
            pending=null
        }catch(failure: Throwable){publish(JSONObject().put("state","error").put("error",failure.message?.takeIf{it in errors} ?: "Capture save failed"))}
        finally {
            LiveCaptureNative.recording=false
            if(nativeId>0)runCatching{LiveCaptureNative.forget(nativeId)}
            pending?.let{runCatching{app?.contentResolver?.delete(it,null,null)}}
            prefix?.let{base->File(base.path+".mkv").delete();File(base.path+".wav").delete();File(base.path+".idx").delete();base.delete()}
            jobs.remove(id)
        }
    }
    fun close(){closed=true;LiveCaptureNative.recording=false;jobs.values.forEach{it.stopped=true;if(it.nativeId>0)runCatching{LiveCaptureNative.cancel(it.nativeId)}}}
    companion object {
        private val errors=setOf("Recording is empty","Recording is too short","Capture source unavailable","Capture unavailable",
            "Capture save failed","Clip export cancelled","Not enough storage","Keyframe unavailable for recording",
            "Capture writer could not keep up","Capture audio format unavailable","Capture audio clock unavailable","Capture clock stalled","Lossless container unavailable")
    }
}
