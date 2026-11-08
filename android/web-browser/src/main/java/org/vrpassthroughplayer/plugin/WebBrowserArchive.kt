package org.vrpassthroughplayer.plugin

import java.net.URI
import org.json.JSONObject

/** The current public item and its exact observed download chain, never a guessed CDN. */
object WebBrowserArchive {
    private const val ENABLED=true // Real current download: touch, native audio/seek and retained return verified.
    fun document(value: String): Boolean=runCatching {
        val u=URI(value)
        value.length<=8192 && u.scheme=="https" && u.host in setOf("archive.org","www.archive.org") &&
            u.port in setOf(-1,443) && u.rawUserInfo==null && u.rawFragment==null
    }.getOrDefault(false)
    fun page(value: String): String?=runCatching {
        require(document(value));Regex("/details/([A-Za-z0-9_.-]{1,100})/?").matchEntire(URI(value).rawPath.orEmpty())?.groupValues?.get(1)?.takeUnless {it in setOf(".","..")}
    }.getOrNull()
    fun observing(value: String)=ENABLED && document(value)
    fun enabled(value: String)=ENABLED && page(value)!=null
    fun metadata(item: JSONObject,currentPage: String): JSONObject?=runCatching {
        val id=page(currentPage) ?: return null
        require(item.optString("frame")==currentPage && !item.optBoolean("protected") && !item.optBoolean("blob"))
        val data=item.getJSONObject("archive")
        require(data.toString().length<=24*1024 && data.getString("id")==id && data.getString("page")==currentPage)
        require(data.getString("revision").matches(Regex("[a-f0-9]{1,8}")))
        val source=item.getString("source");require(document(source))
        require(source==data.getString("source") && source==item.getString("archive_source"))
        val parts=URI(source).rawPath.split('/')
        require(parts.size==4 && parts[1]=="download" && parts[2]==id && Regex(".+\\.(mp4|webm)",RegexOption.IGNORE_CASE).matches(parts[3]))
        val file=data.getString("file");require(WebBrowserNetworkMedia.address(file)?.scheme=="https")
        val width=item.getInt("width");val height=item.getInt("height");val duration=item.getDouble("duration")
        require(width in 1..16384 && height in 1..16384 && width==data.getInt("width") && height==data.getInt("height"))
        require(duration.isFinite() && duration>0 && duration<=86400 && kotlin.math.abs(duration-data.getDouble("duration"))<=.001)
        val requests=WebBrowserNetworkMedia.candidates(item)
        require((0 until requests.length()).any {val r=requests.getJSONObject(it)
            r.optString("kind")=="file" && r.optString("url")==file && (file==source || r.optString("original_url")==source)})
        data
    }.getOrNull()
}
