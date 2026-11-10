package org.vrpassthroughplayer.plugin

import java.net.URI
import org.json.JSONObject

/** The currently rendered full Red Bull TV player, not its hero preview. */
object WebBrowserRedBull {
    private const val ENABLED=false // Open after real button/native/seek/retained-return closure.
    fun page(value: String): String?=runCatching {
        val uri=URI(value)
        require(value.length<=8192 && uri.scheme=="https" && uri.host in setOf("www.redbull.tv","redbull.tv") &&
            uri.rawUserInfo==null && uri.port in setOf(-1,443) && uri.rawFragment==null)
        Regex("/[a-z]{2}(?:-[A-Z]{2}|_[A-Z]{2,3})?/page/(?:page:)?(rrn:content:(?:films|videos|episodes):[a-f0-9]{8}-[a-f0-9]{4}-[a-f0-9]{4}-[a-f0-9]{4}-[a-f0-9]{12})(?:/[a-z0-9-]+)?/?")
            .matchEntire(uri.rawPath.orEmpty())?.groupValues?.get(1)
    }.getOrNull()
    fun document(value: String): Boolean=runCatching {
        val u=URI(value)
        value.length<=8192 && u.scheme=="https" && u.host in setOf("www.redbull.tv","redbull.tv") &&
            u.rawUserInfo==null && u.port in setOf(-1,443) && u.rawFragment==null
    }.getOrDefault(false)
    fun observing(value: String)=ENABLED && document(value)
    fun enabled(value: String)=ENABLED && page(value)!=null
    fun metadata(item: JSONObject,currentPage: String): JSONObject?=runCatching {
        val id=page(currentPage) ?: return null
        require(item.optString("frame")==currentPage && !item.optBoolean("protected") && item.optBoolean("blob"))
        require(item.getString("redbull_source").startsWith("blob:https://${URI(currentPage).host}/"))
        val data=item.getJSONObject("redbull")
        require(data.toString().length<=24*1024 && data.getString("id")==id && data.getString("page")==currentPage)
        require(data.getString("revision").matches(Regex("[a-f0-9]{1,8}")))
        val root=data.getString("root");require(WebBrowserNetworkMedia.address(root)?.scheme=="https")
        val width=item.getInt("width");val height=item.getInt("height");val duration=item.getDouble("duration");val expected=data.getDouble("expected_duration")
        require(width in 1..8192 && height in 1..8192 && width==data.getInt("width") && height==data.getInt("height"))
        require(duration.isFinite() && duration>0 && duration<=86400 && kotlin.math.abs(duration-data.getDouble("duration"))<=.001)
        require(expected.isFinite() && expected>0 && expected<=86400 && expected==kotlin.math.floor(expected) && kotlin.math.abs(duration-expected)<=1)
        val requests=WebBrowserNetworkMedia.candidates(item,true)
        require((0 until requests.length()).any{val r=requests.getJSONObject(it);r.optString("kind")=="hls" && r.optString("url")==root})
        data
    }.getOrNull()
}
