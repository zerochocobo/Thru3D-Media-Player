package org.vrpassthroughplayer.plugin

import org.json.JSONArray
import org.json.JSONObject

/** The clicked feed card's whole muxed file, with its own observed request credentials. */
internal object WebVideoWeiboCapture {
    fun page(document: String, media: JSONObject?): WebVideoPage? = runCatching {
        require(media != null && media.optBoolean("weibo_enabled") && media.optString("capture_identity").isNotEmpty())
        val data = WebBrowserWeibo.metadata(media, document) ?: return null
        WebVideoPage.parse(data.getString("page")).also { require(it.site == "weibo") }
    }.getOrNull()

    fun candidate(page: WebVideoPage, media: JSONObject): JSONObject? = runCatching {
        require(page.site == "weibo" && WebVideoWeiboCapture.page(media.optString("frame"),media) == page && media.optBoolean("weibo_ready"))
        val source = media.getString("source")
        val requests = WebBrowserNetworkMedia.candidates(media)
        val selected = (0 until requests.length()).map { requests.getJSONObject(it) }.filter {
            it.optString("kind") == "file" && (it.optString("url") == source || it.optString("original_url") == source)
        }.distinctBy { it.getString("url") }
        require(selected.size == 1)
        JSONObject(media.toString()).put("network",JSONArray(selected))
    }.getOrNull()

    fun resolve(page: WebVideoPage, media: JSONObject, network: WebVideoNetworkCapture): JSONObject? {
        val bound = candidate(page,media) ?: return null
        val info = network.resolve(page,bound) ?: return null
        val formats = info.optJSONArray("formats") ?: return null
        if (formats.length() != 1) return null
        val file = formats.getJSONObject(0)
        if (file.optString("url") != bound.getJSONArray("network").getJSONObject(0).getString("url") ||
            file.optString("vcodec") in setOf("", "none", "unknown") || file.optString("acodec") in setOf("", "none", "unknown") ||
            file.optInt("width") != media.optInt("width") || file.optInt("height") != media.optInt("height")) return null
        return info
    }
}
