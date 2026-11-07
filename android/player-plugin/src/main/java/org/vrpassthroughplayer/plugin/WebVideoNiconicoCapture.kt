package org.vrpassthroughplayer.plugin

import org.json.JSONArray
import org.json.JSONObject
import java.net.URI

/** The selected watch graph uses the existing standard HLS/AES-128 transport. */
internal object WebVideoNiconicoCapture {
    fun page(document: String,media: JSONObject?): WebVideoPage? = runCatching {
        require(media!=null && media.optBoolean("niconico_enabled") && media.optString("capture_identity").isNotEmpty())
        val data=WebBrowserNiconico.metadata(media,document) ?: return null
        WebVideoPage.parse("https://www.nicovideo.jp/watch/${data.getString("id")}")
    }.getOrNull()
    fun candidate(page: WebVideoPage,media: JSONObject): JSONObject? = runCatching {
        require(page.site=="niconico" && WebVideoNiconicoCapture.page(media.optString("frame"),media)==page && media.optBoolean("niconico_ready"))
        val data=media.getJSONObject("niconico")
        val allowed=mutableSetOf(data.getString("root"),data.getString("video"),data.getString("audio"))
        val resources=data.getJSONArray("resources");for(i in 0 until resources.length())allowed.add(resources.getString(i))
        val observed=WebBrowserNetworkMedia.candidates(media,includeSegments=true)
        val selected=(0 until observed.length()).map { observed.getJSONObject(it) }.filter { it.getString("url") in allowed }.distinctBy { it.getString("url") }
        require(selected.size==allowed.size)
        JSONObject(media.toString()).put("source","").put("network",JSONArray(selected))
    }.getOrNull()
    fun resolve(page: WebVideoPage,media: JSONObject,network: WebVideoNetworkCapture): JSONObject? {
        val bound=candidate(page,media) ?: return null
        val metadata=bound.getJSONObject("niconico")
        val info=network.resolveCurrentHls(page,bound,URI(metadata.getString("root")) to metadata.getString("master_playlist")) ?: return null
        val formats=info.optJSONArray("formats") ?: return null
        if(formats.length()!=2)return null
        val tracks=(0 until formats.length()).map { formats.getJSONObject(it) }
        val video=tracks.singleOrNull { it.optString("vcodec") !in setOf("","none","unknown") } ?: return null
        val audio=tracks.singleOrNull { it.optString("vcodec")=="none" && it.optString("acodec") !in setOf("","none","unknown") } ?: return null
        val data=bound.getJSONObject("niconico")
        if(video.optInt("width")!=media.optInt("width") || video.optInt("height")!=media.optInt("height") ||
            video.optString("url")!=data.getString("video") || audio.optString("url")!=data.getString("audio") || video.optString("acodec")!="none")return null
        return info
    }
    fun keeps(page: WebVideoPage,initial: JSONObject,latest: JSONObject,track: WebVideoTrack): Boolean {
        val current=candidate(page,latest) ?: return false
        val data=current.getJSONObject("niconico")
        return current.optString("niconico_source")==initial.optString("niconico_source") && data.optString("revision")==initial.getJSONObject("niconico").optString("revision") &&
            current.optInt("width")==track.width && current.optInt("height")==track.height && data.optString("video")==track.url.toString()
    }
}
