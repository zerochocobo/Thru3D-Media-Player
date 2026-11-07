package org.vrpassthroughplayer.plugin

import org.json.JSONArray
import org.json.JSONObject

/** Reuses Mango's exact representation checks and the production HLS transport. */
internal object WebVideoYoukuCapture {
    fun page(document: String,media: JSONObject?): WebVideoPage? = runCatching {
        require(media!=null && media.optBoolean("youku_enabled") && media.optString("capture_identity").isNotEmpty())
        val data=WebBrowserYouku.metadata(media,document) ?: return null
        WebVideoPage.parse("https://v.youku.com/v_show/id_${data.getString("id")}.html")
    }.getOrNull()
    fun candidate(page: WebVideoPage,media: JSONObject): JSONObject? = runCatching {
        require(page.site=="youku" && WebVideoYoukuCapture.page(media.optString("frame"),media)==page && media.optBoolean("youku_ready"))
        val actual=media.getJSONObject("youku").getJSONArray("manifests").getString(0)
        val network=WebBrowserNetworkMedia.candidates(media)
        val selected=(0 until network.length()).map { network.getJSONObject(it) }.filter { it.optString("kind")=="hls" && it.optString("url")==actual }.distinctBy { it.getString("url") }
        require(selected.size==1)
        JSONObject(media.toString()).put("network",JSONArray(selected))
    }.getOrNull()
    fun resolve(page: WebVideoPage,media: JSONObject,network: WebVideoNetworkCapture): JSONObject? {
        val bound=candidate(page,media) ?: return null
        val info=network.resolveCurrent(page,bound) ?: return null
        val formats=info.optJSONArray("formats") ?: return null
        if(formats.length()!=1)return null
        val track=formats.getJSONObject(0)
        if(track.optInt("width")!=media.optInt("width") || track.optInt("height")!=media.optInt("height") ||
            track.optString("vcodec") in setOf("","none","unknown") || track.optString("acodec") in setOf("","none","unknown"))return null
        return info
    }
    fun keeps(page: WebVideoPage,initial: JSONObject,latest: JSONObject,track: WebVideoTrack): Boolean {
        val current=candidate(page,latest) ?: return false
        val data=current.getJSONObject("youku")
        return current.optString("source")==initial.optString("source") && data.optString("revision")==initial.getJSONObject("youku").optString("revision") &&
            current.optInt("width")==track.width && current.optInt("height")==track.height && data.getJSONArray("manifests").getString(0)==track.url.toString()
    }
}
