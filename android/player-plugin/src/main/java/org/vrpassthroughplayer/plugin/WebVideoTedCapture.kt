package org.vrpassthroughplayer.plugin

import java.net.URI
import org.json.JSONObject

internal object WebVideoTedCapture {
    fun page(document: String,media: JSONObject?): WebVideoPage? = runCatching {
        require(media!=null && media.optBoolean("ted_enabled") && media.optString("capture_identity").isNotEmpty())
        val data=WebBrowserTed.metadata(media,document) ?: return null
        WebVideoPage.parse(data.getString("page")).also {require(it.site=="ted" && it.id==data.getString("id"))}
    }.getOrNull()
    fun candidate(page: WebVideoPage,media: JSONObject): JSONObject? = runCatching {
        require(page.site=="ted" && WebVideoTedCapture.page(media.optString("frame"),media)==page && media.optBoolean("ted_ready"))
        // Keep the actually observed root/leaf/key requests. The native HLS graph
        // narrows them by this rendered root before fetching any child/master.
        JSONObject(media.toString()).put("source","")
    }.getOrNull()
    fun resolve(page: WebVideoPage,media: JSONObject,network: WebVideoNetworkCapture): JSONObject? {
        val bound=candidate(page,media) ?: return null
        val info=network.resolveRootedCurrentHls(page,bound,URI(bound.getJSONObject("ted").getString("root"))) ?: return null
        val formats=info.optJSONArray("formats") ?: return null
        val items=(0 until formats.length()).map{formats.getJSONObject(it)}
        val video=items.singleOrNull{it.optString("vcodec") !in setOf("","none","unknown")} ?: return null
        if(video.optInt("width")!=media.optInt("width") || video.optInt("height")!=media.optInt("height") ||
            items.none{it.optString("acodec") !in setOf("","none","unknown")})return null
        return info
    }
    fun keeps(page: WebVideoPage,initial: JSONObject,latest: JSONObject,track: WebVideoTrack): Boolean {
        val bound=candidate(page,latest) ?: return false
        val requests=WebBrowserNetworkMedia.candidates(bound)
        fun hlsUris(item: JSONObject): Set<String> {
            val list=WebBrowserNetworkMedia.candidates(item)
            return (0 until list.length()).map{list.getJSONObject(it)}.filter{it.optString("kind")=="hls"}.map{it.getString("url")}.toSet()
        }
        return bound.optString("ted_source")==initial.optString("ted_source") &&
            bound.getJSONObject("ted").optString("revision")==initial.getJSONObject("ted").optString("revision") &&
            bound.optInt("width")==track.width && bound.optInt("height")==track.height &&
            hlsUris(initial)==hlsUris(bound) &&
            (0 until requests.length()).any{requests.getJSONObject(it).optString("url")==track.url.toString()}
    }
}
