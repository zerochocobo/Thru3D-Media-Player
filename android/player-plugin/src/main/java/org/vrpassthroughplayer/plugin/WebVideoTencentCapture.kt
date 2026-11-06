package org.vrpassthroughplayer.plugin

import java.net.URI
import org.json.JSONArray
import org.json.JSONObject

/** Reuses captured whole-file/HLS transport after current Tencent main-player binding. */
internal object WebVideoTencentCapture {
    fun page(document: String,media: JSONObject?): WebVideoPage? = runCatching {
        require(media != null && media.optBoolean("tencent_enabled") && media.optString("capture_identity").isNotEmpty())
        val data = WebBrowserTencent.metadata(media,document) ?: return null
        WebVideoPage.parse(data.getString("page")).also { require(it.site == "tencent") }
    }.getOrNull()

    fun candidate(page: WebVideoPage,media: JSONObject): JSONObject? = runCatching {
        require(page.site == "tencent" && WebVideoTencentCapture.page(media.optString("frame"),media) == page && media.optBoolean("tencent_ready"))
        val data = media.getJSONObject("tencent")
        val list = WebBrowserNetworkMedia.candidates(media,includeSegments=true)
        val refs = if (data.optString("playlist").isNotEmpty()) WebBrowserTencent.references(data) ?: return null else null
        val selected = (0 until list.length()).map { list.getJSONObject(it) }.filter {
            if (refs != null) it.optString("url") in refs || it.optString("original_url") in refs
            else it.optString("kind") == "file" && (it.optString("url") == media.optString("source") || it.optString("original_url") == media.optString("source"))
        }.distinctBy { it.getString("url") }
        require(selected.isNotEmpty())
        JSONObject(media.toString()).put("network",JSONArray(selected))
    }.getOrNull()

    fun resolve(page: WebVideoPage,media: JSONObject,network: WebVideoNetworkCapture): JSONObject? {
        val bound = candidate(page,media) ?: return null
        val data = bound.getJSONObject("tencent")
        val body = data.optString("playlist")
        val info = if (body.isEmpty()) network.resolveCurrent(page,bound)
            else network.resolveObservedHls(page,bound,URI(data.getString("manifest_url")),body)
        val formats = info?.optJSONArray("formats") ?: return null
        if (formats.length() != 1) return null
        val track = formats.getJSONObject(0)
        if (track.optInt("width") != media.optInt("width") || track.optInt("height") != media.optInt("height") ||
            track.optString("vcodec") in setOf("", "none", "unknown") || track.optString("acodec") in setOf("", "none", "unknown")) return null
        return info
    }
}
