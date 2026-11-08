package org.vrpassthroughplayer.plugin

import java.net.URI
import org.json.JSONObject

internal object WebVideoRedBullCapture {
    fun page(document: String,media: JSONObject?): WebVideoPage?=runCatching {
        require(media!=null && media.optBoolean("redbull_enabled") && media.optString("capture_identity").isNotEmpty())
        val data=WebBrowserRedBull.metadata(media,document) ?: return null
        WebVideoPage.parse(data.getString("page")).also{require(it.site=="redbull" && WebBrowserRedBull.page(it.url)==data.getString("id"))}
    }.getOrNull()
    fun candidate(page: WebVideoPage,media: JSONObject): JSONObject?=runCatching {
        require(page.site=="redbull" && WebVideoRedBullCapture.page(media.optString("frame"),media)==page && media.optBoolean("redbull_ready"))
        JSONObject(media.toString()).put("source","")
    }.getOrNull()
    fun resolve(page: WebVideoPage,media: JSONObject,network: WebVideoNetworkCapture): JSONObject? {
        val bound=candidate(page,media) ?: return null
        val info=network.resolveRootedCurrentHls(page,bound,URI(bound.getJSONObject("redbull").getString("root"))) ?: return null
        val formats=info.getJSONArray("formats");val items=(0 until formats.length()).map{formats.getJSONObject(it)}
        val video=items.singleOrNull{it.optString("vcodec") !in setOf("","none","unknown")} ?: return null
        if(video.optInt("width")!=media.optInt("width") || video.optInt("height")!=media.optInt("height") ||
            items.none{it.optString("acodec") !in setOf("","none","unknown")})return null
        return info
    }
    fun keeps(page: WebVideoPage,initial: JSONObject,latest: JSONObject,track: WebVideoTrack): Boolean {
        val bound=candidate(page,latest) ?: return false
        fun hls(item: JSONObject): Set<String> {
            val list=WebBrowserNetworkMedia.candidates(item,true)
            return (0 until list.length()).map{list.getJSONObject(it)}.filter{it.optString("kind")=="hls"}.map{it.getString("url")}.toSet()
        }
        return bound.optString("redbull_source")==initial.optString("redbull_source") &&
            bound.getJSONObject("redbull").optString("revision")==initial.getJSONObject("redbull").optString("revision") &&
            bound.optInt("width")==track.width && bound.optInt("height")==track.height && hls(initial)==hls(bound) && track.url.toString() in hls(bound)
    }
}
