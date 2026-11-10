package org.vrpassthroughplayer.plugin

import java.net.URI
import org.json.JSONObject

/** Current watch access declaration, exact observed HLS graph and decoded owner. */
object WebBrowserNiconico {
    private const val ENABLED = true // Real Gecko button/HLS audio-video/seek/retained-return closure passed locally.
    fun enabled(value: String) = ENABLED && page(value)!=null
    fun observing(value: String) = ENABLED && runCatching {
        val u=URI(value)
        value.length<=8192 && u.scheme=="https" && u.host=="www.nicovideo.jp" && u.rawUserInfo==null && u.port in setOf(-1,443) && u.rawFragment==null
    }.getOrDefault(false)
    fun page(value: String): String? = runCatching {
        require(value.length<=8192)
        val u=URI(value)
        require(u.scheme=="https" && u.host=="www.nicovideo.jp" && u.rawUserInfo==null && u.rawFragment==null && u.port in setOf(-1,443))
        Regex("/watch/((?:sm|nm|so)[0-9]{1,20})/?").matchEntire(u.rawPath.orEmpty())?.groupValues?.get(1)
    }.getOrNull()
    fun metadata(item: JSONObject,currentPage: String): JSONObject? = runCatching {
        val id=page(currentPage) ?: return null
        require(item.optString("frame")==currentPage && item.optBoolean("blob") && !item.optBoolean("protected"))
        require(item.optString("niconico_source").startsWith("blob:https://www.nicovideo.jp/"))
        val data=item.getJSONObject("niconico")
        require(data.toString().length<=64*1024 && data.getString("id")==id && data.getString("page")==currentPage && data.getString("revision").matches(Regex("[a-f0-9]{1,8}")))
        val width=item.getInt("width");val height=item.getInt("height");val duration=item.getDouble("duration")
        require(width in 1..16384 && height in 1..16384 && width==data.getInt("width") && height==data.getInt("height"))
        require(duration.isFinite() && duration>0 && duration<=172800 && kotlin.math.abs(duration-data.getDouble("duration"))<=.001)
        for(name in listOf("expected_duration","audio_duration")) {
            val seconds=data.getDouble(name)
            require(seconds.isFinite() && seconds>0 && seconds<=172800 && kotlin.math.abs(seconds-duration)<=.5)
        }
        require(Regex("(?:avc[13]|hvc1|hev1|vp09|av01)\\..+",RegexOption.IGNORE_CASE).matches(data.getString("vcodec")))
        require(Regex("(?:mp4a\\..+|opus|ac-3|ec-3)",RegexOption.IGNORE_CASE).matches(data.getString("acodec")))
        val manifests=listOf("root","video","audio").map { data.getString(it).also { url -> require(WebBrowserNetworkMedia.address(url)?.scheme=="https") } }
        require(manifests.distinct().size==3)
        val playlist=data.getString("master_playlist")
        require(playlist.startsWith("#EXTM3U") && playlist.toByteArray(Charsets.UTF_8).size<=48*1024 && playlist.contains("#EXT-X-STREAM-INF:"))
        val resources=data.getJSONArray("resources");require(resources.length()<=8)
        val extras=(0 until resources.length()).map { resources.getString(it).also { url -> require(WebBrowserNetworkMedia.address(url)?.scheme=="https") } }
        require(extras.distinct().size==extras.size && extras.none { it in manifests })
        val network=WebBrowserNetworkMedia.candidates(item,includeSegments=true)
        for(url in manifests+extras) require((0 until network.length()).any {
            val c=network.getJSONObject(it);c.optString("url")==url && c.optString("kind")==if(url in manifests)"hls" else "segment"
        })
        data
    }.getOrNull()
}
