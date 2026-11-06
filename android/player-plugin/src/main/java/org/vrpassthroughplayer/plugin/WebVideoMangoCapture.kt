package org.vrpassthroughplayer.plugin

import org.json.JSONArray
import org.json.JSONObject

/** Declared and observed Mango HLS, using the existing container and loopback transport. */
internal object WebVideoMangoCapture {
    fun page(document: String,media: JSONObject?): WebVideoPage? = runCatching {
        require(media!=null && media.optBoolean("mango_enabled") && media.optString("capture_identity").isNotEmpty())
        val data=WebBrowserMango.metadata(media,document) ?: return null
        WebVideoPage.parse("https://www.mgtv.com/b/${data.getString("id")}.html")
    }.getOrNull()
    fun candidate(page: WebVideoPage,media: JSONObject): JSONObject? = runCatching {
        require(page.site=="mgtv" && WebVideoMangoCapture.page(media.optString("frame"),media)==page && media.optBoolean("mango_ready"))
        val urls=media.getJSONObject("mango").getJSONArray("manifests")
        val declared=(0 until urls.length()).map { urls.getString(it) }.toSet()
        val network=WebBrowserNetworkMedia.candidates(media)
        val selected=(0 until network.length()).map { network.getJSONObject(it) }.filter {
            it.optString("kind")=="hls" && (it.optString("url") in declared || it.optString("original_url") in declared)
        }.distinctBy { it.getString("url") }
        require(selected.size in 1..6)
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
        val data=current.getJSONObject("mango")
        if(current.optString("source")!=initial.optString("source") || data.optString("revision")!=initial.getJSONObject("mango").optString("revision") ||
            current.optInt("width")!=track.width || current.optInt("height")!=track.height)return false
        val network=current.getJSONArray("network")
        return (0 until network.length()).any { network.getJSONObject(it).optString("url")==track.url.toString() }
    }
}
