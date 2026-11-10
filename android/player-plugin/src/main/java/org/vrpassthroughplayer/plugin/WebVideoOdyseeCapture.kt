package org.vrpassthroughplayer.plugin

import java.net.URI
import org.json.JSONArray
import org.json.JSONObject

/** Current Odysee claim, using the existing whole-file or rooted HLS transport. */
internal object WebVideoOdyseeCapture {
    fun page(document: String, media: JSONObject?): WebVideoPage? = runCatching {
        require(media != null && media.optBoolean("odysee_enabled") && media.optString("capture_identity").isNotEmpty())
        val data = WebBrowserOdysee.metadata(media, document) ?: return null
        WebVideoPage.parse(data.getString("page"))
    }.getOrNull()

    fun candidate(page: WebVideoPage, media: JSONObject): JSONObject? = runCatching {
        require(page.site == "odysee" && WebVideoOdyseeCapture.page(media.optString("frame"), media) == page && media.optBoolean("odysee_ready"))
        if (media.getJSONObject("odysee").optString("binding") == "rendered_hls")
            return JSONObject(media.toString()).put("source", "")
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
        val hls = bound.getJSONObject("odysee").optString("binding") == "rendered_hls"
        val info = if (hls) network.resolveRootedCurrentHls(page, bound, URI(bound.getJSONObject("odysee").getString("root")))
            else network.resolve(page, bound)
        if (info == null) return null
        val formats = info.optJSONArray("formats") ?: return null
        if (hls) {
            val items = (0 until formats.length()).map { formats.getJSONObject(it) }
            val video = items.singleOrNull { it.optString("vcodec") !in setOf("", "none", "unknown") } ?: return null
            if (video.optInt("width") != media.optInt("width") || video.optInt("height") != media.optInt("height") ||
                items.none { it.optString("acodec") !in setOf("", "none", "unknown") }) return null
            return info
        }
        if (formats.length() != 1) return null
        val file = formats.getJSONObject(0)
        if (file.optString("url") != bound.getString("source") || file.optString("vcodec") in setOf("", "none", "unknown") ||
            file.optString("acodec") in setOf("", "none", "unknown") || file.optInt("width") != media.optInt("width") || file.optInt("height") != media.optInt("height")) return null
        return info
    }

    fun keeps(page: WebVideoPage, initial: JSONObject, latest: JSONObject, track: WebVideoTrack): Boolean {
        val bound = candidate(page, latest) ?: return false
        val data = bound.getJSONObject("odysee")
        val original = initial.getJSONObject("odysee")
        if (data.optString("binding") == "rendered_hls") {
            val requests = WebBrowserNetworkMedia.candidates(bound)
            return original.optString("binding") == "rendered_hls" && data.getString("root") == original.optString("root") &&
                data.getString("claim_id") == original.optString("claim_id") && bound.optString("odysee_source") == initial.optString("odysee_source") &&
                data.getString("revision") == original.optString("revision") && bound.optInt("width") == track.width && bound.optInt("height") == track.height &&
                (0 until requests.length()).any { val r = requests.getJSONObject(it); r.optString("kind") == "hls" && r.optString("url") == track.url.toString() }
        }
        return bound.getString("source") == initial.optString("source") && bound.getString("source") == track.url.toString() &&
            bound.getJSONObject("odysee").optString("revision") == initial.getJSONObject("odysee").optString("revision") &&
            bound.optInt("width") == track.width && bound.optInt("height") == track.height
    }
}
