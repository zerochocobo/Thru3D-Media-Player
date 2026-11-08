package org.vrpassthroughplayer.plugin

import org.json.JSONArray
import org.json.JSONObject

/** Reuses the verified Weibo whole-file transport, with Twitch's current clip identity. */
internal object WebVideoTwitchCapture {
    fun page(document: String, media: JSONObject?): WebVideoPage? = runCatching {
        require(media != null && media.optBoolean("twitch_enabled") && media.optString("capture_identity").isNotEmpty())
        val data = WebBrowserTwitch.metadata(media, document) ?: return null
        WebVideoPage.parse("https://clips.twitch.tv/${data.getString("id")}")
    }.getOrNull()

    fun candidate(page: WebVideoPage, media: JSONObject): JSONObject? = runCatching {
        require(page.site == "twitch" && WebVideoTwitchCapture.page(media.optString("frame"), media) == page && media.optBoolean("twitch_ready"))
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
        val info = network.resolve(page, bound) ?: return null
        val formats = info.optJSONArray("formats") ?: return null
        if (formats.length() != 1) return null
        val file = formats.getJSONObject(0)
        if (file.optString("url") != bound.getString("source") || file.optString("vcodec") in setOf("", "none", "unknown") ||
            file.optString("acodec") in setOf("", "none", "unknown") || file.optInt("width") != media.optInt("width") || file.optInt("height") != media.optInt("height")) return null
        return info
    }

    fun keeps(page: WebVideoPage, initial: JSONObject, latest: JSONObject, track: WebVideoTrack): Boolean {
        val bound = candidate(page, latest) ?: return false
        return bound.getString("source") == initial.optString("source") && bound.getString("source") == track.url.toString() &&
            bound.getJSONObject("twitch").optString("revision") == initial.getJSONObject("twitch").optString("revision") &&
            bound.optInt("width") == track.width && bound.optInt("height") == track.height
    }
}
