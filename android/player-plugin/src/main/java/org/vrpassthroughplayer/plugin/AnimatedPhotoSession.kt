package org.vrpassthroughplayer.plugin

import android.graphics.Bitmap
import org.json.JSONObject
import java.io.Closeable
import java.io.File
import java.nio.ByteBuffer
import java.util.ArrayDeque
import java.util.concurrent.Executors
import java.util.concurrent.ExecutorService

/** A single decoder, two ready frames and one displayed frame. IO/decode never runs in poll(). */
internal class AnimatedPhotoSession(private val source: PhotoSource,
    private val backend: PhotoAnimationBackend=NativePhotoAnimationBackend,
    private val worker: ExecutorService=Executors.newSingleThreadExecutor {Thread(it,"PhotoAnimation")},
    private val ownsWorker: Boolean=true,
    private val clock: ()->Long={System.nanoTime()/1000}) : Closeable {
    private val lock=Any()
    private val ready=ArrayDeque<LongArray>()
    private var displayed: LongArray?=null
    private var decoder=0L // worker-owned, closed after any in-flight next() completes.
    @Volatile private var closed=false
    private var pumping=false
    private var eof=false
    private var failed=false
    private var paused=false
    private var pausedAt=0L
    private var deadline=0L
    private var plays=1L
    private var completed=0L
    private var ended=false
    init {source.retain();pump()}
    private fun now()=clock()
    private fun checkCurrent(){if(closed)throw InterruptedException()}
    private fun pump() {
        synchronized(lock) {
            if(closed||pumping||eof||failed||paused||ready.size>=2)return
            pumping=true
        }
        worker.execute {
            try {
                if(decoder==0L){checkCurrent();decoder=backend.open(source.file.path);require(decoder>0)
                    val info=backend.info(decoder) ?: error("PHOTO_DECODE_FAILED");plays=info[4]}
                while(true) {
                    synchronized(lock){if(closed||paused||ready.size>=2)return@execute}
                    var frame=backend.next(decoder,Runnable {checkCurrent()}) ?: error("PHOTO_DECODE_FAILED")
                    if(frame[0]==0L) {
                        completed++
                        if(plays!=0L && completed>=plays){synchronized(lock){eof=true};return@execute}
                        backend.reset(decoder)
                        frame=backend.next(decoder,Runnable {checkCurrent()}) ?: error("PHOTO_DECODE_FAILED")
                        require(frame[0]>0)
                    }
                    synchronized(lock){if(closed)backend.releaseFrame(frame[0]) else ready.addLast(frame)}
                }
            }catch(_: InterruptedException){}
            catch(_: Throwable){synchronized(lock){if(!closed)failed=true}}
            finally {synchronized(lock){pumping=false}}
        }
    }
    fun poll(): String {
        val json=synchronized(lock) {
            if(closed)return ""
            val time=now()
            if(displayed==null && ready.isNotEmpty()) {
                displayed=ready.removeFirst();deadline=time+displayed!![3].coerceAtLeast(1000)
                if(paused)pausedAt=time
            }
            if(!paused) while(displayed!=null && time>=deadline && ready.isNotEmpty()) {
                backend.releaseFrame(displayed!![0]);displayed=ready.removeFirst()
                deadline+=displayed!![3].coerceAtLeast(1000)
            }
            // If decoding cannot keep up, bound catch-up to the two ready frames.
            // Rebase after a long stall instead of spending every poll in catch-up.
            if(!paused && !eof && displayed!=null && time-deadline>250000)
                deadline=time+displayed!![3].coerceAtLeast(1000)
            if(!paused && eof&&ready.isEmpty()&&displayed!=null&&time>=deadline)ended=true
            JSONObject().put("token",displayed?.get(0)?:0).put("width",displayed?.get(1)?:0).put("height",displayed?.get(2)?:0)
                .put("paused",paused).put("ended",ended).put("failed",failed).toString()
        }
        pump();return json
    }
    fun pause(value: Boolean) {
        synchronized(lock){if(closed||paused==value)return
            val time=now();if(value)pausedAt=time else if(displayed!=null)deadline+=(time-pausedAt).coerceAtLeast(0)
            paused=value}
        if(!value)pump()
    }
    fun upload(token: Long,texture: Int,mipmaps: Boolean): Boolean = synchronized(lock) {
        !closed && displayed?.get(0)==token && backend.upload(token,texture,mipmaps)
    }
    fun pixels(token: Long): ByteArray = synchronized(lock) {
        if(closed||displayed?.get(0)!=token)ByteArray(0) else backend.pixels(token)?:ByteArray(0)
    }
    /** Called on an effect worker; snapshot bytes and dimensions belong to the same immutable frame. */
    fun snapshot(check: ()->Unit): File? {
        val captured=synchronized(lock){
            val frame=displayed
            val data=if(frame!=null)backend.pixels(frame[0]) else null
            if(frame!=null&&data!=null)Triple(frame[1].toInt(),frame[2].toInt(),data) else null
        }
        if(captured==null)return ExtendedPhoto.posterSnapshot(source.file,check)
        check();val bitmap=Bitmap.createBitmap(captured.first,captured.second,Bitmap.Config.ARGB_8888)
        var output: File?=null
        try {ExtendedPhoto.fill(bitmap,captured.third)
            val file=File.createTempFile("animation-effect-",".png",source.file.parentFile)
            output=file
            file.outputStream().use {require(bitmap.compress(Bitmap.CompressFormat.PNG,100,it))};check();return file
        }catch(failure: Throwable){output?.delete();throw failure}finally {bitmap.recycle()}
    }
    override fun close() {
        synchronized(lock){if(closed)return;closed=true
            ready.forEach {backend.releaseFrame(it[0])};ready.clear()
            displayed?.let {backend.releaseFrame(it[0])};displayed=null}
        worker.execute {try{if(decoder>0)backend.close(decoder)}finally {source.release()}}
        if(ownsWorker)worker.shutdown()
    }
}
