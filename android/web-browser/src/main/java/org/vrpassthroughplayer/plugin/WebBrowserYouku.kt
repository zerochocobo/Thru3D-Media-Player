package org.vrpassthroughplayer.plugin

import java.net.URI
import java.util.Locale
import org.json.JSONObject

/** UPS declaration plus the selected document's actual HLS request. No API replay. */
object WebBrowserYouku {
    // Real Gecko159 button/HLS audio-video/seek/retained-document return verified locally.
    private const val ENABLED = true
    fun enabled(value: String) = ENABLED && page(value)!=null
    fun page(value: String): String? = runCatching {
        require(value.length<=8192)
        val u=URI(value)
        require(u.scheme=="https" && u.rawUserInfo==null && u.rawFragment==null && u.port in setOf(-1,443) && u.host?.lowercase(Locale.ROOT)=="v.youku.com")
        Regex("/v_show/id_(X[A-Za-z0-9=]{1,127})\\.html").matchEntire(u.rawPath.orEmpty())?.groupValues?.get(1)
    }.getOrNull()
    internal fun sameManifest(declared: String,observed: String): Boolean = runCatching {
        val a=WebBrowserNetworkMedia.address(declared) ?: return false
        val b=WebBrowserNetworkMedia.address(observed) ?: return false
        fun authority(u: URI): String = u.host.lowercase(Locale.ROOT)+if(u.port<0 || u.port==(if(u.scheme=="https")443 else 80)) "" else ":${u.port}"
        (a.scheme==b.scheme || a.scheme=="http" && b.scheme=="https") && authority(a)==authority(b) && a.rawPath==b.rawPath && a.rawQuery==b.rawQuery
    }.getOrDefault(false)
    fun metadata(item: JSONObject,currentPage: String): JSONObject? = runCatching {
        val id=page(currentPage) ?: return null
        require(item.optString("frame")==currentPage && !item.optBoolean("protected") && item.optBoolean("blob"))
        val data=item.getJSONObject("youku")
        require(data.toString().length<=128*1024 && data.getString("id")==id && data.getString("page")==currentPage && data.getString("declared_drm")=="default")
        require(data.getString("revision").matches(Regex("[a-f0-9]{1,8}")))
        val width=item.getInt("width");val height=item.getInt("height");val duration=item.getDouble("duration")
        require(width in 1..16384 && height in 1..16384 && data.getInt("width")==width && data.getInt("height")==height)
        val bound=data.getDouble("duration");val expected=data.getDouble("expected_duration")
        require(duration.isFinite() && duration>0 && duration<=172800 && bound.isFinite() && expected.isFinite() && expected>0 && expected<=172800 &&
            kotlin.math.abs(duration-bound)<=.001 && kotlin.math.abs(duration-expected)<=2.0)
        val declarations=data.getJSONArray("declarations")
        require(declarations.length() in 1..8)
        val declared=(0 until declarations.length()).map { index ->
            val d=declarations.getJSONObject(index)
            require(d.getInt("width")==width && d.getInt("height")==height)
            val seconds=d.getDouble("duration")
            require(seconds.isFinite() && seconds>0 && kotlin.math.abs(seconds-duration)<=2.0 && kotlin.math.abs(seconds-expected)<=2.0)
            d.getString("url").also { require(WebBrowserNetworkMedia.address(it)!=null) }
        }
        val urls=data.getJSONArray("manifests");require(urls.length()==1)
        val actual=urls.getString(0);require(WebBrowserNetworkMedia.address(actual)!=null)
        val network=WebBrowserNetworkMedia.candidates(item)
        val matched=(0 until network.length()).map { network.getJSONObject(it) }.filter { r ->
            r.optString("kind")=="hls" && r.optString("url")==actual && declared.any { sameManifest(it,actual)||sameManifest(it,r.optString("original_url")) }
        }.distinctBy { it.getString("url") }
        require(matched.size==1)
        data
    }.getOrNull()
}
