package org.vrpassthroughplayer.plugin

import android.content.Context
import org.json.JSONArray
import org.json.JSONObject
import java.io.File
import java.io.InputStream
import java.net.HttpURLConnection
import java.net.URI
import java.util.concurrent.Executors
import java.util.concurrent.atomic.AtomicBoolean
import java.util.concurrent.atomic.AtomicInteger

/** Owned local fixture behind the production cloud/loopback/FFmpeg path. The
 * origin permits one live body, including a paused playback consumer. No cloud
 * account, external server, user media, saved settings or audio output. */
internal object ListeningNetworkProbe {
    private val worker=Executors.newSingleThreadExecutor {Thread(it,"ListeningNetworkProbe")}
    private val running=AtomicBoolean()
    fun request(context: Context, request: String): Int {
        if(!running.compareAndSet(false,true))return -1
        worker.execute {
            val report=JSONObject().put("request",request)
            try {
                val file=File(context.filesDir,"fixtures/listening_runtime_ja.mkv")
                require(file.length() in 1..20_000_000)
                val bytes=file.readBytes()
                val manifest=context.assets.open("moonshine/model.json").bufferedReader().use {JSONObject(it.readText())}
                    .getJSONObject("models").getJSONObject("ja")
                val models=File(context.filesDir,"listening/ja")
                NarrationModels.ensure(models,manifest.getJSONObject("files"),{context.assets.open(manifest.getString("directory")+"/"+it)},{true},{})
                val results=JSONArray()
                for(shared in listOf(false,true)) {
                    val active=AtomicInteger();val peak=AtomicInteger();val rejected=AtomicInteger();val requests=AtomicInteger()
                    fun connection(uri: URI) = object : HttpURLConnection(uri.toURL()) {
                        private var acquired=false
                        @Volatile private var done=false
                        private var start=0
                        override fun connect() {}
                        override fun usingProxy()=false
                        @Synchronized override fun disconnect(){done=true;if(acquired){acquired=false;active.decrementAndGet()}}
                        override fun getResponseCode(): Int {
                            requests.incrementAndGet()
                            start=getRequestProperty("Range").substringAfter("bytes=").substringBefore('-').toInt()
                            val count=active.incrementAndGet()
                            if(count>1){active.decrementAndGet();rejected.incrementAndGet();return 403}
                            acquired=true;peak.accumulateAndGet(count,::maxOf);return 206
                        }
                        override fun getHeaderField(name: String): String? = when(name){
                            "Content-Range" -> "bytes $start-${bytes.lastIndex}/${bytes.size}"
                            "Content-Length" -> "${bytes.size-start}"
                            "X-Thru3D-Upstream-Reason" -> if(!acquired)"cdn_connections_limited" else null
                            else -> null
                        }
                        override fun getContentType()="application/octet-stream"
                        override fun getInputStream()=object : InputStream(){
                            private var at=start
                            override fun read(): Int {check(!done);return if(at<bytes.size)bytes[at++].toInt() and 255 else -1}
                            override fun read(buffer: ByteArray,off: Int,len: Int): Int {
                                check(!done);if(at>=bytes.size)return -1
                                val count=minOf(len,bytes.size-at);bytes.copyInto(buffer,off,at,at+count);at+=count;return count
                            }
                            override fun close(){disconnect()}
                        }
                    }
                    val result=JSONObject().put("shared",shared)
                    val source=CloudStreamSource(bytes.size.toLong(),{CloudLink("https://fixture.invalid/media"){emptyMap()}},::connection)
                    LocalStreamServer().use { server ->
                        val url=server.publish(source,"listening_probe.mkv")
                        source.open().use { playback ->
                            val first=ByteArray(1024);check(playback.read(0,first,first.size)>0)
                            check(active.get()==1)
                            if(shared)server.shareReadAhead(url)
                            val engine=ListeningNative.create(models.path,"ja")
                            check(engine>0)
                            try {
                                try {
                                    ListeningNative.open(engine,url,1,"",0.0,false,-1)
                                    check(shared){"Negative control unexpectedly opened"}
                                    var through=0.0;var cues=0
                                    repeat(15){
                                        val step=JSONObject(ListeningNative.step(engine))
                                        through=step.getDouble("through");cues+=step.getJSONArray("cues").length()
                                        // The pre-existing playback consumer still gets exact original bytes.
                                        val data=ByteArray(1024);val at=(it*4096).toLong()
                                        val n=playback.read(at,data,data.size)
                                        check(bytes.copyOfRange(at.toInt(),at.toInt()+n).contentEquals(data.copyOf(n)))
                                    }
                                    check(through>=12&&cues>0&&rejected.get()==0)
                                    result.put("through",through).put("cue_events",cues).put("state","ready")
                                } catch(error: IllegalStateException){
                                    if(shared||rejected.get()==0)throw error
                                    result.put("state","expected_connection_limit")
                                }
                            } finally {ListeningNative.destroy(engine)}
                        }
                        result.put("cache",source.readAheadStats()?.let {JSONObject(it)})
                    }
                    check(active.get()==0)
                    result.put("peak_connections",peak.get()).put("rejected",rejected.get()).put("requests",requests.get()).put("connections_after_close",active.get())
                    results.put(result)
                }
                report.put("cases",results).put("passed",true)
            }catch(error: Throwable){report.put("passed",false).put("error",error.javaClass.simpleName)}
            finally {
                val directory=File(context.filesDir,"diagnostics").apply {mkdirs()}
                File(directory,"listening_network_$request.json").writeText(report.toString(2))
                running.set(false)
            }
        }
        return 1
    }
}
