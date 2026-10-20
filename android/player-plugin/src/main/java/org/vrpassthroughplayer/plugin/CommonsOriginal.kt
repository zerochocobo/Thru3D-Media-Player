package org.vrpassthroughplayer.plugin

import org.json.JSONObject
import java.net.HttpURLConnection
import java.net.URI
import java.net.URL
import java.net.URLEncoder
import java.io.ByteArrayOutputStream
import java.util.concurrent.Executors
import java.util.concurrent.atomic.AtomicInteger

/** Public MediaWiki imageinfo resolves the original, independently of Media Viewer's thumbnail DOM. */
internal class CommonsOriginal {
    private val worker=Executors.newSingleThreadExecutor { Thread(it,"CommonsOriginal") }
    private val epoch=AtomicInteger()
    @Volatile private var connection: HttpURLConnection?=null
    @Volatile private var closed=false
    fun cancel() { epoch.incrementAndGet(); connection?.disconnect() }
    @Synchronized fun resolve(page: String, result: (Image?, String?) -> Unit) {
        if(closed) return
        cancel(); val token=epoch.get()
        val title=title(page) ?: return
        worker.execute {
            var active: HttpURLConnection?=null
            try {
                if(closed || token!=epoch.get()) return@execute
                val query="https://commons.wikimedia.org/w/api.php?action=query&format=json&prop=imageinfo&iiprop=url%7Csize%7Cmime&titles="+URLEncoder.encode(title,"UTF-8")
                active=URL(query).openConnection() as HttpURLConnection; connection=active
                active.connectTimeout=15000; active.readTimeout=15000; active.instanceFollowRedirects=false
                active.setRequestProperty("User-Agent","Thru3D-PanoramaBrowser/1.0")
                require(active.responseCode==200)
                val body=active.inputStream.use { input ->
                    val bytes=ByteArrayOutputStream(); val buffer=ByteArray(16384)
                    while(true) {
                        if(closed || token!=epoch.get()) throw InterruptedException()
                        val n=input.read(buffer); if(n<0) break
                        require(bytes.size()+n<=1024*1024); bytes.write(buffer,0,n)
                    }
                    bytes.toByteArray()
                }
                val image=parse(JSONObject(String(body,Charsets.UTF_8)))
                if(!closed && token==epoch.get()) result(image,null)
            } catch (error: Throwable) {
                if(!closed && token==epoch.get()) result(null,error.message?.takeIf { it in setOf("Choose an 8K or larger original","Choose a supported image original","Image too large") } ?: "Image download failed")
            } finally { active?.disconnect(); if(token==epoch.get()) connection=null }
        }
    }
    @Synchronized fun close() { closed=true; cancel(); worker.shutdownNow() }
    data class Image(val url: String,val width: Int,val height: Int)
    companion object {
        fun title(page: String): String? = runCatching {
            if(!PanoramaWebPolicy.allowed(page)) return null
            val uri=URI(page)
            if(uri.host.lowercase() !in setOf("commons.wikimedia.org","commons.m.wikimedia.org")) return null
            val path=uri.fragment?.takeIf { it.startsWith("/media/File:") }?.removePrefix("/media/")
                ?: uri.path.takeIf { it.startsWith("/wiki/File:") }?.removePrefix("/wiki/")
            path?.takeIf { it.length<=2048 && it.startsWith("File:") }
        }.getOrNull()
        fun parse(root: JSONObject): Image {
            val pages=root.getJSONObject("query").getJSONObject("pages")
            val page=pages.getJSONObject(pages.keys().next())
            val image=page.getJSONArray("imageinfo").getJSONObject(0)
            require(PanoramaWebPolicy.mime(image.getString("mime")) in PanoramaWebPolicy.imageTypes) { "Choose a supported image original" }
            val width=image.getInt("width"); val height=image.getInt("height")
            require(PanoramaWebPolicy.highResolution(width,height)) { "Choose an 8K or larger original" }
            require(image.optLong("size",0)<=PhotoBridge.MAX_BYTES) { "Image too large" }
            val url=image.getString("url"); require(PanoramaWebPolicy.allowed(url))
            return Image(url,width,height)
        }
    }
}
