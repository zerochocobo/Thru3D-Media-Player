package org.vrpassthroughplayer.plugin

import org.json.JSONArray
import org.json.JSONObject

/** Reuses the verified Weibo whole-file transport, with Reddit's current clip identity. */
internal object WebVideoRedditCapture {
    fun page(document: String, media: JSONObject?): WebVideoPage? = runCatching {
        require(media != null && media.optBoolean("reddit_enabled") && media.optString("capture_identity").isNotEmpty())
        val data = WebBrowserReddit.metadata(media, document) ?: return null
        WebVideoPage.parse(data.getString("page"))
    }.getOrNull()

    fun candidate(page: WebVideoPage, media: JSONObject): JSONObject? = runCatching {
        require(page.site == "reddit" && WebVideoRedditCapture.page(media.optString("frame"), media) == page && media.optBoolean("reddit_ready"))
        val source = media.getString("source")
        val requests = WebBrowserNetworkMedia.candidates(media)
        val selected = (0 until requests.length()).map { requests.getJSONObject(it) }.filter {
            it.optString("kind") == "file" && it.optString("url") == source
        }.distinctBy { it.getString("url") }
        require(selected.size == 1)
        JSONObject(media.toString()).put("network", JSONArray(selected))
    }.getOrNull()

    fun resolve(page: WebVideoPage, media: JSONObject, network: WebVideoNetworkCapture): JSONObject? {
        val bound = candidate(page, media) ?: return null
        val gif=bound.getJSONObject("reddit").optString("binding")=="rendered_gif"
        val info = (if(gif)network.resolveObservedRedditGifFile(page,bound) else network.resolve(page, bound)) ?: return null
        val formats = info.optJSONArray("formats") ?: return null
        if (formats.length() != 1) return null
        val file = formats.getJSONObject(0)
        val silent=gif && info.optBoolean("browser_reddit_gif") && info.optBoolean("browser_explicit_silent")
        if (file.optString("url") != bound.getString("source") || file.optString("vcodec") in setOf("", "none", "unknown") ||
            file.optString("acodec") in setOf("", "unknown") || (file.optString("acodec")=="none" && !silent) ||
            file.optInt("width") != media.optInt("width") || file.optInt("height") != media.optInt("height")) return null
        return info
    }

    fun keeps(page: WebVideoPage, initial: JSONObject, latest: JSONObject, track: WebVideoTrack): Boolean {
        val bound = candidate(page, latest) ?: return false
        return bound.getString("source") == initial.optString("source") && bound.getString("source") == track.url.toString() &&
            bound.getJSONObject("reddit").optString("binding")==initial.getJSONObject("reddit").optString("binding") &&
            bound.getJSONObject("reddit").optBoolean("declared_gif")==initial.getJSONObject("reddit").optBoolean("declared_gif") &&
            bound.getJSONObject("reddit").optString("revision") == initial.getJSONObject("reddit").optString("revision") &&
            bound.optInt("width") == track.width && bound.optInt("height") == track.height
    }
}
