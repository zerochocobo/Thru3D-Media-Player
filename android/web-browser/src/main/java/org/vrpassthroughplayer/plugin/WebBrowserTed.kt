package org.vrpassthroughplayer.plugin

import java.net.URI
import org.json.JSONObject

object WebBrowserTed {
    private const val ENABLED = true // Current talk verified with real button/native/audio/seek/retained return.
    fun document(value: String): Boolean = runCatching {
        val u=URI(value)
        value.length<=8192 && u.scheme=="https" && u.host in setOf("ted.com","www.ted.com") && u.rawUserInfo==null && u.port in setOf(-1,443) && u.rawFragment==null
    }.getOrDefault(false)
    fun observing(value: String) = ENABLED && document(value)
    fun enabled(value: String) = ENABLED && page(value)!=null
    fun page(value: String): String? = runCatching {
        require(document(value));Regex("/talks/([a-z0-9_-]{1,180})/?").matchEntire(URI(value).rawPath.orEmpty())?.groupValues?.get(1)
    }.getOrNull()
    fun metadata(item: JSONObject,currentPage: String): JSONObject? = runCatching {
        val slug=page(currentPage) ?: return null
        require(item.optString("frame")==currentPage && !item.optBoolean("protected") && item.optBoolean("blob"))
        val source=item.getString("ted_source")
        require(source.startsWith("blob:https://www.ted.com/") || source.startsWith("blob:https://ted.com/"))
        val data=item.getJSONObject("ted")
        require(data.toString().length<=24*1024 && data.getString("id")==slug && data.getString("page")==currentPage)
        require(data.getString("revision").matches(Regex("[a-f0-9]{1,8}")))
        for(key in listOf("talk_id","player_id"))require(data.getString(key).matches(Regex("[0-9]{1,20}")))
        val root=data.getString("root");val uri=WebBrowserNetworkMedia.address(root)
        require(uri?.scheme=="https" && uri.path.endsWith(".m3u8"))
        val width=item.getInt("width");val height=item.getInt("height");val duration=item.getDouble("duration")
        require(width in 1..8192 && height in 1..8192 && width==data.getInt("width") && height==data.getInt("height"))
        require(duration.isFinite() && duration>0 && duration<=86400 && kotlin.math.abs(duration-data.getDouble("duration"))<=.001)
        require(kotlin.math.floor(duration)==data.getDouble("expected_duration"))
        val requests=WebBrowserNetworkMedia.candidates(item)
        require((0 until requests.length()).any {val r=requests.getJSONObject(it);r.optString("kind")=="hls" && r.optString("url")==root})
        data
    }.getOrNull()
}
