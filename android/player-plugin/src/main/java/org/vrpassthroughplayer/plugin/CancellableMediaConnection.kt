package org.vrpassthroughplayer.plugin

import okhttp3.Call
import okhttp3.ConnectionPool
import okhttp3.OkHttpClient
import okhttp3.Protocol
import okhttp3.Request
import okhttp3.Response
import java.io.IOException
import java.io.InputStream
import java.net.HttpURLConnection
import java.net.URI
import java.net.URL
import java.util.concurrent.TimeUnit
import java.util.concurrent.locks.ReentrantLock
import kotlin.concurrent.withLock

/** Media-only URLConnection facade whose disconnect cancels the socket read.
 * HTTP redirects, provider retries, validation and headers remain in CloudStreamSource. */
internal class CancellableMediaConnection private constructor(url: URL) : HttpURLConnection(url) {
    private val headers=linkedMapOf<String,String>()
    private var call: Call?=null
    private var response: Response?=null
    @Volatile private var cancelled=false
    private val bodyLock=ReentrantLock()
    @Synchronized override fun setRequestProperty(name: String,value: String) {
        check(!connected);headers[name]=value
    }
    @Synchronized override fun getRequestProperty(name: String): String? = headers[name]
    private fun result(): Response {
        val pending=synchronized(this) {
            if(cancelled)throw IOException("Request cancelled")
            response?.let { return it }
            check(call==null) {"Concurrent media response read"}
            val request=Request.Builder().url(url).apply {headers.forEach { (name,value)->header(name,value) }}.build()
            client.newBuilder().connectTimeout(connectTimeout.toLong(),TimeUnit.MILLISECONDS)
                .readTimeout(readTimeout.toLong(),TimeUnit.MILLISECONDS).build().newCall(request).also {call=it;connected=true}
        }
        val incoming=pending.execute()
        synchronized(this) {
            if(cancelled){incoming.close();throw IOException("Request cancelled")}
            response=incoming
        }
        return incoming
    }
    override fun connect() { result() }
    override fun getResponseCode()=result().code
    override fun getHeaderField(name: String): String?=result().header(name)
    override fun getContentType(): String?=result().header("Content-Type")
    override fun getInputStream(): InputStream {
        val stream=result().body?.byteStream() ?: throw IOException("Missing media body")
        return object : InputStream() {
            override fun read(): Int=bodyLock.withLock {if(cancelled)throw IOException("Request cancelled");stream.read()}
            override fun read(bytes: ByteArray,offset: Int,length: Int): Int=bodyLock.withLock {
                if(cancelled)throw IOException("Request cancelled")
                stream.read(bytes,offset,length)
            }
            override fun close()=disconnect()
        }
    }
    override fun getErrorStream(): InputStream?=synchronized(this){response?.body?.byteStream()}
    override fun usingProxy()=false
    override fun disconnect() {
        val active=synchronized(this){cancelled=true;Pair(call,response)}
        // Cancel before closing the body: InputStream.close alone can wait on
        // another thread's blocking read on some URLConnection implementations.
        active.first?.cancel()
        // Socket cancellation wakes the read before body cleanup takes this
        // per-response lock. Never concurrently drain/close an Okio read.
        bodyLock.withLock { runCatching { active.second?.close() } }
    }
    companion object {
        private val client=OkHttpClient.Builder().followRedirects(false).followSslRedirects(false)
            .retryOnConnectionFailure(false).protocols(listOf(Protocol.HTTP_1_1))
            .connectionPool(ConnectionPool(0,1,TimeUnit.SECONDS)).build()
        fun open(uri: URI): HttpURLConnection=CancellableMediaConnection(uri.toURL())
    }
}
