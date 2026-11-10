package org.vrpassthroughplayer.plugin

import org.json.JSONArray
import org.json.JSONObject

/** Exact declared progressive file, reusing the verified muxed-file probe and transport. */
internal object WebVideoNaverCapture {
    fun page(document: String,media: JSONObject?): WebVideoPage?=runCatching {
        require(media!=null && media.optBoolean("naver_enabled") && media.optString("capture_identity").isNotEmpty())
        val data=WebBrowserNaver.metadata(media,document) ?: return null
        WebVideoPage("naver",data.getString("id"),data.getString("page"))
    }.getOrNull()
    fun candidate(page: WebVideoPage,media: JSONObject): JSONObject?=runCatching {
        require(page.site=="naver" && WebVideoNaverCapture.page(media.optString("frame"),media)==page && media.optBoolean("naver_ready"))
        val source=media.getJSONObject("naver").getString("source")
        val timeline=WebBrowserNaver.timeline(media,media.getString("frame"))
        if(timeline!=null){
            val requests=WebBrowserNetworkMedia.candidates(media,true)
            val selected=(0 until requests.length()).map{requests.getJSONObject(it)}.filter{it.optString("kind")=="segment" && it.optString("url") in timeline.refs}
            require(selected.isNotEmpty())
            return JSONObject(media.toString()).put("source", "").put("network",JSONArray(selected))
        }
        val list=WebBrowserNetworkMedia.candidates(media)
        val selected=(0 until list.length()).map { list.getJSONObject(it) }.filter { it.optString("kind")=="file" && it.optString("url")==source }.distinctBy { it.getString("url") }
        require(selected.size==1)
        JSONObject(media.toString()).put("source",source).put("network",JSONArray(selected))
    }.getOrNull()
    fun resolve(page: WebVideoPage,media: JSONObject,network: WebVideoNetworkCapture): JSONObject? {
        val bound=candidate(page,media) ?: return null
        val plan=WebBrowserNaver.timeline(media,media.getString("frame"))
        val info=(if(plan!=null)network.resolveDeclaredNaverTimeline(page,bound,plan) else network.resolve(page,bound)) ?: return null
        val formats=info.optJSONArray("formats") ?: return null
        if(formats.length()!=1)return null
        val file=formats.getJSONObject(0)
        if(file.optString("url")!=(plan?.base?.toString() ?: bound.getString("source")) || file.optString("vcodec") in setOf("","none","unknown") ||
            file.optString("acodec") in setOf("","none","unknown") || file.optInt("width")!=media.optInt("width") || file.optInt("height")!=media.optInt("height"))return null
        return info
    }
    fun keeps(page: WebVideoPage,initial: JSONObject,latest: JSONObject,track: WebVideoTrack): Boolean {
        val bound=candidate(page,latest) ?: return false
        val before=initial.optJSONObject("naver") ?: return false
        val after=latest.getJSONObject("naver")
        return after.optString("id")==before.optString("id") && after.optString("revision")==before.optString("revision") &&
            after.optString("current_source")==before.optString("current_source") && after.getString("source")==track.url.toString() &&
            bound.optInt("width")==track.width && bound.optInt("height")==track.height
    }
}
