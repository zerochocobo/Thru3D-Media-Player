package org.vrpassthroughplayer.plugin

import android.content.Context
import org.json.JSONObject
import java.io.File
import java.util.concurrent.atomic.AtomicLong

/** One TTS instance per player bridge. Leases share weights, never concurrent inference. */
internal class SharedNarrationEngine(private val backend: Backend) : AutoCloseable {
    interface Backend {
        fun preparationTimings(): JSONObject=JSONObject()
        fun create(active: ()->Boolean, progress: (String,Long,Long)->Unit): Long
        fun destroy(handle: Long)
        fun cancel(handle: Long, token: Long)
        fun register(handle: Long, voice: String, codes: IntArray)
        fun synthesize(handle: Long,text: String,voice: String,token: Long,frames: Int,precision: Boolean,sink: NarrationNative.Sink): String
    }
    private val gate=Any()
    private val owners=HashSet<Lease>()
    private val serial=AtomicLong()
    @Volatile private var handle=0L
    @Volatile private var closed=false
    private data class Running(val lease: Lease,val handle: Long,val token: Long)
    @Volatile private var running: Running?=null
    @Volatile private var created=0
    @Volatile private var destroyed=0
    @Volatile private var reused=0
    private var registered=""

    inner class Lease internal constructor() : AutoCloseable {
        @Volatile internal var released=false
        val handle get()=if(released)0L else this@SharedNarrationEngine.handle
        fun ensure(active: ()->Boolean,progress: (String,Long,Long)->Unit={_,_,_->})=synchronized(gate) {
            check(!released&&!closed&&this in owners);ensureLocked(active,progress)
        }
        fun cancel() {running?.takeIf {it.lease===this}?.let {runCatching {backend.cancel(it.handle,serial.incrementAndGet())}}}
        override fun close() {
            cancel()
            synchronized(gate){if(released)return;released=true;owners.remove(this);if(owners.isEmpty())destroyLocked()}
        }
    }
    fun acquire(active: ()->Boolean,progress: (String,Long,Long)->Unit={_,_,_->}): Lease=synchronized(gate) {
        check(!closed);val lease=Lease();owners+=lease
        try {ensureLocked(active,progress);lease}
        catch(error: Throwable){owners.remove(lease);lease.released=true;if(owners.isEmpty())destroyLocked();throw error}
    }
    private fun ensureLocked(active: ()->Boolean,progress: (String,Long,Long)->Unit) {
        check(active()){"voice_cancelled"}
        if(handle>0){reused++;progress("ready",0,0);return}
        val loaded=backend.create(active,progress);check(loaded>0)
        created++
        if(!active()||closed){backend.destroy(loaded);destroyed++;error("voice_cancelled")}
        handle=loaded;registered="";progress("ready",0,0)
    }
    fun synthesize(lease: Lease,text: String,voice: String,epoch: Long,frames: Int,precision: Boolean,
                   active: ()->Boolean,codes: ()->IntArray,sink: NarrationNative.Sink): String=synchronized(gate) {
        check(!closed&&!lease.released&&lease in owners&&handle>0&&active()){"voice_cancelled"}
        val current=handle;val token=serial.incrementAndGet()
        try {
            if(PersonalVoiceStore.isVoice(voice)) {
                // Saved and candidate UUIDs are immutable code identities. Keep
                // only the currently registered voice, as the native engine does.
                if(registered!=voice){backend.register(current,voice,codes());registered=voice}
            }
            check(active()&&!closed){"voice_cancelled"};backend.cancel(current,token);running=Running(lease,current,token)
            check(active()&&!closed){"voice_cancelled"}
            backend.synthesize(current,text,voice,token,frames,precision,object:NarrationNative.Sink {
                override fun onChunk(epochIgnored: Long,pcm: FloatArray)=active()&&!lease.released&&sink.onChunk(epoch,pcm)
            })
        } finally {running=null}
    }
    /** Encoder process and TTS cannot overlap, even while another source is being opened. */
    fun <T> encoding(active: ()->Boolean,block: ()->T): T=synchronized(gate) {
        check(!closed&&active()){"voice_cancelled"};destroyLocked();block()
    }
    private fun destroyLocked(){if(handle>0){val old=handle;handle=0;registered="";backend.destroy(old);destroyed++}}
    fun stats()=JSONObject().put("instances",if(handle>0)1 else 0).put("created",created).put("destroyed",destroyed).put("warm_reuses",reused).put("preparation_ms",backend.preparationTimings())
    override fun close(){closed=true;running?.let {runCatching {backend.cancel(it.handle,serial.incrementAndGet())}};synchronized(gate){destroyLocked();owners.forEach {it.released=true};owners.clear()}}

    companion object {
        fun native(context: ()->Context?)=SharedNarrationEngine(object:Backend {
            @Volatile private var verificationMs=0L
            @Volatile private var loadingMs=0L
            override fun preparationTimings()=JSONObject().put("verify",verificationMs).put("load",loadingMs)
            override fun create(active: ()->Boolean,progress: (String,Long,Long)->Unit): Long {
                val app=context() ?: error("voice_unavailable")
                val manifest=app.assets.open("narration/model.json").bufferedReader().use {JSONObject(it.readText())}
                val directory=File(app.filesDir,manifest.getString("directory")).canonicalFile
                require(directory.path.startsWith(app.filesDir.canonicalPath+File.separator))
                val files=manifest.getJSONObject("files");val total=files.keys().asSequence().sumOf {files.getJSONObject(it).getLong("bytes")};var bytes=0L
                progress("verifying",0,total)
                val started=System.nanoTime()
                NarrationModels.ensure(directory,files,{app.assets.open(manifest.getString("directory")+"/"+it)},active,{bytes+=it;progress("verifying",bytes,total)})
                verificationMs=(System.nanoTime()-started)/1_000_000
                check(active()){"voice_cancelled"};progress("loading",bytes,total)
                val loading=System.nanoTime()
                return NarrationNative.create(directory.path).also {loadingMs=(System.nanoTime()-loading)/1_000_000}
            }
            override fun destroy(handle: Long)=NarrationNative.destroy(handle)
            override fun cancel(handle: Long,token: Long)=NarrationNative.cancel(handle,token)
            override fun register(handle: Long,voice: String,codes: IntArray)=NarrationNative.registerVoice(handle,voice,codes)
            override fun synthesize(handle: Long,text: String,voice: String,token: Long,frames: Int,precision: Boolean,sink: NarrationNative.Sink)=
                NarrationNative.synthesizePrecisionConfigured(handle,text,voice,token,frames,0,precision,sink)
        })
    }
}
