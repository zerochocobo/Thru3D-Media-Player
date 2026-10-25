package org.vrpassthroughplayer.plugin

import android.content.Context
import android.graphics.Bitmap
import android.graphics.BitmapFactory
import android.net.Uri
import android.os.ParcelFileDescriptor
import java.io.ByteArrayOutputStream
import java.util.concurrent.ConcurrentHashMap
import java.util.concurrent.Executors
import java.util.concurrent.atomic.AtomicBoolean
import java.util.concurrent.atomic.AtomicInteger

/** Optional MKV artwork. Uses the existing source leases and never changes the player. */
internal class EmbeddedCover(private val context: () -> Context?, private val resolve: (String) -> String,
                             private val release: (String) -> Unit) : AutoCloseable {
    private class Job { val cancelled=AtomicBoolean(); @Volatile var result: ByteArray?=null }
    private val jobs=ConcurrentHashMap<Int,Job>()
    private val next=AtomicInteger()
    private val busy=AtomicBoolean()
    private val worker=Executors.newSingleThreadExecutor { Thread(it,"EmbeddedCover") }
    @Volatile private var closed=false

    fun request(uri: String): Int {
        if(closed||uri.isEmpty()||!OriginalClipNative.supported()||!busy.compareAndSet(false,true))return 0
        jobs.keys.sorted().dropLast(3).forEach { old -> if(jobs[old]?.result!=null)jobs.remove(old) }
        val id=next.incrementAndGet();val job=Job();jobs[id]=job
        OriginalClipNative.prepare(-id) // Screenshot/clip request ids are positive.
        worker.execute {
            var lease: String?=null;var descriptor: ParcelFileDescriptor?=null
            try {
                val app=context() ?: return@execute
                if(job.cancelled.get())return@execute
                lease=resolve(uri)
                val source=Uri.parse(lease)
                val path=when(source.scheme) {
                    "file" -> source.path ?: return@execute
                    "http","https" -> lease!!
                    else -> {
                        descriptor=app.contentResolver.openFileDescriptor(source,"r") ?: return@execute
                        "/proc/self/fd/${descriptor!!.fd}"
                    }
                }
                if(!job.cancelled.get())job.result=preview(OriginalClipNative.cover(-id,path,MpvTlsTrust.prepare(app)))
            } catch(_: Throwable) { /* A missing/unreadable cover falls back to the displayed frame. */ }
            finally {
                if(job.result==null)job.result=ByteArray(0)
                runCatching { descriptor?.close() };lease?.let { runCatching { release(it) } }
                OriginalClipNative.forget(-id);busy.set(false)
                if(job.cancelled.get())jobs.remove(id)
            }
        }
        return id
    }
    fun state(id: Int): String = jobs[id]?.let { if(it.result==null)"pending" else "ready" } ?: "missing"
    fun take(id: Int): ByteArray = jobs.remove(id)?.result ?: ByteArray(0)
    fun cancel(id: Int) { jobs.remove(id)?.let { it.cancelled.set(true);OriginalClipNative.cancel(-id) } }
    override fun close() {closed=true;jobs.keys.toList().forEach(::cancel);worker.shutdown()}

    private fun preview(bytes: ByteArray): ByteArray {
        if(bytes.isEmpty())return bytes
        val bounds=BitmapFactory.Options().apply { inJustDecodeBounds=true }
        BitmapFactory.decodeByteArray(bytes,0,bytes.size,bounds)
        if(bounds.outWidth<=0||bounds.outHeight<=0||bounds.outWidth.toLong()*bounds.outHeight>40L*1024*1024)return ByteArray(0)
        var sample=1
        while(maxOf(bounds.outWidth,bounds.outHeight)/sample>1024)sample*=2
        val bitmap=BitmapFactory.decodeByteArray(bytes,0,bytes.size,BitmapFactory.Options().apply { inSampleSize=sample }) ?: return ByteArray(0)
        return try {ByteArrayOutputStream().also { bitmap.compress(Bitmap.CompressFormat.PNG,100,it) }.toByteArray()}
        finally {bitmap.recycle()}
    }
}
