package org.vrpassthroughplayer.plugin

import java.net.URI
import org.json.JSONObject

internal object WebVideoDailymotionCapture {
    fun page(document: String,media: JSONObject?): WebVideoPage?=runCatching {
        require(media!=null && media.optBoolean("dailymotion_enabled") && media.optString("capture_identity").isNotEmpty())
        val owner=media.getString("dailymotion_owner")
        require(WebBrowserDailymotion.page(owner)==WebBrowserDailymotion.page(document))
        val data=WebBrowserDailymotion.metadata(media,document) ?: return null
        WebVideoPage.parse(data.getString("page")).also{require(it.site=="dailymotion" && it.id==data.getString("id"))}
    }.getOrNull()
    fun candidate(page: WebVideoPage,media: JSONObject): JSONObject?=runCatching {
        require(page.site=="dailymotion" && WebVideoDailymotionCapture.page(page.url,media)==page && media.optBoolean("dailymotion_ready"))
        JSONObject(media.toString()).put("source","")
    }.getOrNull()
    fun resolve(page: WebVideoPage,media: JSONObject,network: WebVideoNetworkCapture): JSONObject? {
        val bound=candidate(page,media) ?: return null
        val data=bound.getJSONObject("dailymotion");val root=URI(data.getString("root"));val list=data.getJSONArray("manifests")
        val bodies=(0 until list.length()).associate{val entry=list.getJSONObject(it);val uri=URI(entry.getString("url"));uri to WebBrowserDailymotion.transportManifest(entry.getString("body"),uri)}
        val info=if(bodies[root]?.contains("#EXT-X-STREAM-INF:")==true)network.resolveRootedCurrentHls(page,bound,root,bodies)
            else network.resolveObservedHls(page,bound,root,bodies[root] ?: return null)
        if(info==null)return null
        val formats=info.getJSONArray("formats");val items=(0 until formats.length()).map{formats.getJSONObject(it)}
        val video=items.singleOrNull{it.optString("vcodec") !in setOf("","none","unknown")} ?: return null
        if(video.optInt("width")!=media.optInt("width") || video.optInt("height")!=media.optInt("height") || items.none{it.optString("acodec") !in setOf("","none","unknown")})return null
        return info
    }
    fun keeps(page: WebVideoPage,initial: JSONObject,latest: JSONObject,track: WebVideoTrack): Boolean {
        val bound=candidate(page,latest) ?: return false
        fun hls(item: JSONObject): Set<String> {
            val list=WebBrowserNetworkMedia.candidates(item,true)
            return (0 until list.length()).map{list.getJSONObject(it)}.filter{it.optString("kind")=="hls"}.map{it.getString("url")}.toSet()
        }
        return bound.optString("dailymotion_owner")==initial.optString("dailymotion_owner") && bound.optString("frame")==initial.optString("frame") &&
            bound.optString("dailymotion_source")==initial.optString("dailymotion_source") &&
            bound.getJSONObject("dailymotion").optString("revision")==initial.getJSONObject("dailymotion").optString("revision") &&
            bound.optInt("width")==track.width && bound.optInt("height")==track.height && hls(initial)==hls(bound) && track.url.toString() in hls(bound)
    }
}
