package org.vrpassthroughplayer.plugin

import java.util.ArrayDeque
import java.util.concurrent.Executors
import java.util.concurrent.atomic.AtomicLong
import kotlin.math.roundToInt

/** Page-scoped PCM16, never persisted. The same buffer streams during synthesis and replays warm. */
internal class ComicSpeechPrefetch(private val session: ComicNarrationSession,
    private val codes: (String)->IntArray,private val changed: ()->Unit,
    private val byteLimit: Int=16*1024*1024) : AutoCloseable {
    data class Request(val key: String,val text: String,val language: String,val voice: String)
    class Buffer(val request: Request) {
        private val monitor=java.lang.Object()
        private val chunks=ArrayList<ShortArray>()
        @Volatile var complete=false;private set
        @Volatile var failed=false;private set
        @Volatile var bytes=0;private set
        @Volatile var readers=0;private set
        fun append(pcm: FloatArray) = synchronized(monitor) {
            check(!failed&&!complete);require(pcm.size%2==0&&pcm.all {it.isFinite()})
            chunks+=ShortArray(pcm.size){(pcm[it].coerceIn(-1f,1f)*32767).roundToInt().toShort()};bytes+=pcm.size*2;monitor.notifyAll()
        }
        fun finish()=synchronized(monitor){check(!failed);complete=true;monitor.notifyAll()}
        fun fail()=synchronized(monitor){failed=true;monitor.notifyAll()}
        fun read(active: ()->Boolean,consume: (FloatArray)->Unit) {
            synchronized(monitor){readers++}
            try {var index=0
                while(true){
                    val chunk=synchronized(monitor){
                        while(index>=chunks.size&&!complete&&!failed&&active())monitor.wait(40)
                        check(active()&&!failed){"voice_cancelled"}
                        if(index>=chunks.size)null else chunks[index++]
                    } ?: break
                    check(active());consume(FloatArray(chunk.size){chunk[it]/32768f})
                }
            } finally {synchronized(monitor){readers--}}
        }
    }
    private val lock=Any()
    private val worker=Executors.newSingleThreadExecutor {Thread(it,"ComicPrepare")}
    private val epoch=AtomicLong()
    private val serial=AtomicLong()
    private val buffers=LinkedHashMap<String,Buffer>(16,.75f,true)
    private val queue=ArrayDeque<Buffer>()
    private var running: Buffer?=null
    private var draining=false
    @Volatile private var closed=false
    @Volatile var lastFailure="";private set
    fun warm(){val token=epoch.get();worker.execute {runCatching {session.warm { !closed&&epoch.get()==token }}}}
    fun prepare(request: Request,priority: Boolean): Buffer=synchronized(lock){
        check(!closed)
        val previous=buffers[request.key]
        if(previous!=null&&previous.request==request&&!previous.failed){
            if(priority&&queue.remove(previous)){interruptOther(previous);queue.addFirst(previous)}
            return previous
        }
        previous?.fail();if(previous!=null)queue.remove(previous)
        val buffer=Buffer(request);buffers[request.key]=buffer
        if(priority){interruptOther(buffer);queue.addFirst(buffer)}else queue.addLast(buffer)
        if(!draining){draining=true;worker.execute {drain()}}
        buffer
    }
    private fun interruptOther(next: Buffer){
        val current=running ?: return
        // Every priority caller has already cancelled the old playback. Its reader
        // can take one polling interval to detach; that must not delay the new target.
        if(current===next)return
        serial.incrementAndGet();session.cancel();current.fail();buffers.remove(current.request.key)
    }
    private fun reserve(buffer: Buffer,bytes: Int)=synchronized(lock){
        check(buffers[buffer.request.key]===buffer&&!buffer.failed)
        require(buffer.bytes+bytes<=8*1024*1024){"comic_audio_limit"}
        while(buffers.values.sumOf {it.bytes}+bytes>byteLimit){
            val victim=buffers.values.firstOrNull {it!==buffer&&it.complete&&it.readers==0} ?: error("comic_audio_budget")
            buffers.remove(victim.request.key)
        }
    }
    private fun drain(){
        while(true){
            val buffer: Buffer;val token: Long;val generation: Long
            synchronized(lock){
                if(closed||queue.isEmpty()){draining=false;running=null;return}
                buffer=queue.removeFirst();running=buffer;token=serial.incrementAndGet();generation=epoch.get()
            }
            fun active()=!closed&&epoch.get()==generation&&serial.get()==token&&!buffer.failed
            try {
                val r=buffer.request
                session.generate(r.text,r.language,r.voice,{codes(r.voice)},token,::active){pcm->
                    check(active());reserve(buffer,pcm.size*2);buffer.append(pcm)
                }
                check(active());buffer.finish()
            } catch(error: Throwable){if(active())lastFailure=error.javaClass.simpleName+":"+error.message.orEmpty().take(120);buffer.fail()}
            synchronized(lock){if(running===buffer)running=null;if(buffer.failed&&buffers[buffer.request.key]===buffer)buffers.remove(buffer.request.key)}
            changed()
        }
    }
    fun snapshot(): Pair<Int,Int> = synchronized(lock){buffers.values.count {it.complete&&!it.failed} to buffers.values.sumOf {it.bytes}}
    fun ready(key: String)=synchronized(lock){buffers[key]?.let {it.complete&&!it.failed} ?: false}
    fun readyCount(keys: Collection<String>)=synchronized(lock){keys.count {buffers[it]?.let {b->b.complete&&!b.failed}==true}}
    /** Page turns stop unfinished synthesis but retain reusable, voice-keyed PCM. */
    fun retainCompleted(){
        synchronized(lock){
            epoch.incrementAndGet();serial.incrementAndGet();session.cancel()
            buffers.values.filter {!it.complete||it.failed}.forEach {it.fail()}
            buffers.entries.removeAll {it.value.failed};queue.clear()
        }
        changed()
    }
    fun clear(release: Boolean=false){
        synchronized(lock){epoch.incrementAndGet();serial.incrementAndGet();session.cancel();buffers.values.forEach {it.fail()};buffers.clear();queue.clear();lastFailure=""}
        if(release)worker.execute {if(synchronized(lock){queue.isEmpty()&&running==null})session.close()}
        changed()
    }
    override fun close(){synchronized(lock){if(closed)return;closed=true};clear();worker.execute {session.close()};worker.shutdown()}
}
