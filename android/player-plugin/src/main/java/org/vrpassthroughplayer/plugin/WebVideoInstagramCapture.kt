package org.vrpassthroughplayer.plugin

import java.net.URI
import org.json.JSONObject

internal object WebVideoInstagramCapture {
    fun page(document: String,media: JSONObject?): WebVideoPage?=runCatching {
        require(media!=null && media.optBoolean("instagram_enabled") && media.optString("capture_identity").isNotEmpty())
        val data=WebBrowserInstagram.metadata(media,document) ?: return null
        WebVideoPage.parse(data.getString("page")).also{require(it.site=="instagram" && it.id==data.getString("id"))}
    }.getOrNull()
    fun candidate(page: WebVideoPage,media: JSONObject): JSONObject?=runCatching {
        require(page.site=="instagram" && WebVideoInstagramCapture.page(media.optString("frame"),media)==page && media.optBoolean("instagram_ready"))
        JSONObject(media.toString()).put("source","")
    }.getOrNull()
    fun resolve(page: WebVideoPage,media: JSONObject,network: WebVideoNetworkCapture): JSONObject? {
        val bound=candidate(page,media) ?: return null;val data=bound.getJSONObject("instagram")
        val video=URI(data.getJSONObject("video").getString("url"))
        val audio=data.optJSONObject("audio")?.getString("url")?.let(::URI)
        return network.resolveDeclaredInstagramFiles(page,bound,video,audio,!data.getBoolean("has_audio"))
    }
    fun keeps(page: WebVideoPage,initial: JSONObject,latest: JSONObject,track: WebVideoTrack): Boolean {
        val bound=candidate(page,latest) ?: return false;val data=bound.getJSONObject("instagram")
        return bound.optString("instagram_source")==initial.optString("instagram_source") && data.optString("revision")==initial.getJSONObject("instagram").optString("revision") &&
            data.getJSONObject("video").getString("url")==track.url.toString() && bound.optInt("width")==track.width && bound.optInt("height")==track.height
    }
}
