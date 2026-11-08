package org.vrpassthroughplayer.plugin

import java.net.URI
import org.json.JSONObject

/** Current rendered clip plus its exact observed MP4; no API replay or signature generation. */
object WebBrowserStreamable {
    private const val ENABLED=true // Actual detail clip: touch, native audio/seek and retained return verified.
    fun document(value: String): Boolean=runCatching {
        val u=URI(value)
        value.length<=8192 && u.scheme=="https" && u.host in setOf("streamable.com","www.streamable.com") &&
            u.port in setOf(-1,443) && u.rawUserInfo==null && u.rawFragment==null
    }.getOrDefault(false)
    fun page(value: String): String?=runCatching {
        require(document(value));Regex("/([A-Za-z0-9]{3,32})/?").matchEntire(URI(value).rawPath.orEmpty())?.groupValues?.get(1)
    }.getOrNull()
    fun observing(value: String)=ENABLED && document(value)
    fun enabled(value: String)=ENABLED && page(value)!=null
    fun metadata(item: JSONObject,currentPage: String): JSONObject?=runCatching {
        val id=page(currentPage) ?: return null
        require(item.optString("frame")==currentPage && !item.optBoolean("protected") && !item.optBoolean("blob"))
        val data=item.getJSONObject("streamable")
        require(data.toString().length<=24*1024 && data.getString("id")==id && data.getString("page")==currentPage)
        require(data.getString("revision").matches(Regex("[a-f0-9]{1,8}")))
        val source=item.getString("source");val uri=WebBrowserNetworkMedia.address(source)
        require(source==data.getString("source") && source==item.getString("streamable_source") &&
            uri?.scheme=="https" && uri.path.substringAfterLast('/')=="$id.mp4")
        val width=item.getInt("width");val height=item.getInt("height");val duration=item.getDouble("duration")
        require(width in 1..16384 && height in 1..16384 && width==data.getInt("width") && height==data.getInt("height"))
        require(duration.isFinite() && duration>0 && duration<=86400 && kotlin.math.abs(duration-data.getDouble("duration"))<=.001)
        val expected=data.getDouble("expected_duration")
        require(expected.isFinite() && expected>0 && expected<=86400 && kotlin.math.abs(duration-expected)<=.5)
        val requests=WebBrowserNetworkMedia.candidates(item)
        require((0 until requests.length()).any {val r=requests.getJSONObject(it);r.optString("kind")=="file" && r.optString("url")==source})
        data
    }.getOrNull()
}
