package org.vrpassthroughplayer.plugin

import java.net.URI
import org.json.JSONObject

/** Rendered native Reddit post, exact packaged file and this document's observed request. */
object WebBrowserReddit {
    fun document(value: String): Boolean=runCatching {
        val u=URI(value)
        value.length<=8192 && u.scheme=="https" && u.host in setOf("reddit.com","www.reddit.com") &&
            u.port in setOf(-1,443) && u.rawUserInfo==null && u.rawFragment==null
    }.getOrDefault(false)
    fun page(value: String): String?=runCatching {
        require(document(value))
        Regex("/r/[A-Za-z0-9_]{2,32}/comments/([a-z0-9]{3,10})(?:/[A-Za-z0-9_-]{1,200})?/?").matchEntire(URI(value).rawPath.orEmpty())?.groupValues?.get(1)
    }.getOrNull()
    private fun feed(value: String)=document(value) && Regex("/(?:r/[A-Za-z0-9_]{2,32}/(?:hot|new|top|rising|best)?/?)?").matches(URI(value).rawPath.orEmpty())
    fun observing(value: String)=document(value)
    fun enabled(value: String)=page(value)!=null || runCatching { feed(value) }.getOrDefault(false)
    fun metadata(item: JSONObject,currentPage: String): JSONObject?=runCatching {
        require(enabled(currentPage) && item.optString("frame")==currentPage && !item.optBoolean("protected") && !item.optBoolean("blob"))
        val data=item.getJSONObject("reddit");val id=data.getString("id")
        require(data.toString().length<=24*1024 && page(data.getString("page"))==id && data.getString("document")==currentPage)
        val binding=data.getString("binding")
        require(page(currentPage)?.let { it==id }!=false && binding in setOf("rendered_post","rendered_gif") && data.getString("active_id")==id)
        require(if(binding=="rendered_gif")data.opt("declared_gif")==true else !data.optBoolean("declared_gif"))
        require(data.getString("revision").matches(Regex("[a-f0-9]{1,8}")))
        val source=item.getString("source");val uri=WebBrowserNetworkMedia.address(source)
        require(source==data.getString("source") && source==item.getString("reddit_source") && uri?.scheme=="https")
        val width=item.getInt("width");val height=item.getInt("height");val duration=item.getDouble("duration")
        require(width in 1..16384 && height in 1..16384 && width==data.getInt("width") && height==data.getInt("height"))
        require(duration.isFinite() && duration>0 && duration<=86400 && kotlin.math.abs(duration-data.getDouble("duration"))<=.001)
        val expected=data.getDouble("expected_duration")
        require(expected.isFinite() && expected>0 && expected<=86400 && kotlin.math.abs(duration-expected)<=maxOf(2.0,expected*.01))
        if(binding=="rendered_gif")require(kotlin.math.abs(duration-expected)<=.001)
        val requests=WebBrowserNetworkMedia.candidates(item)
        require((0 until requests.length()).any {val r=requests.getJSONObject(it);r.optString("kind")=="file" && r.optString("url")==source})
        data
    }.getOrNull()
}
