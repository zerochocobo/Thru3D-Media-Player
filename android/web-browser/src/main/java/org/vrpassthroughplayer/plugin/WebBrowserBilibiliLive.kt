package org.vrpassthroughplayer.plugin

import java.net.URI
import org.json.JSONArray
import org.json.JSONObject

/** Current public room and the exact private playlist observed in its top-level document. */
object WebBrowserBilibiliLive {
    private val roomPath = Regex("/([1-9][0-9]{0,19})/?")
    private val cdn = Regex("(?:[A-Za-z0-9-]+\\.)*bilivideo\\.(?:com|cn)")
    private val delegatedCdn = Regex("(?:[A-Za-z0-9-]+\\.)+smtcdns\\.net")
    private val streamName = Regex("[A-Za-z0-9_-]{1,128}")

    private fun playlist(value: String): URI? = WebBrowserNetworkMedia.address(value)?.takeIf {
        it.scheme == "https" && it.port in setOf(-1, 443) && it.rawPath.endsWith(".m3u8", ignoreCase = true)
    }

    fun room(page: String): String? {
        if (page.length !in 1..8192) return null
        val uri = runCatching { URI(page) }.getOrNull() ?: return null
        if (uri.scheme != "https" || uri.host != "live.bilibili.com" || uri.port !in setOf(-1, 443) ||
            uri.rawUserInfo != null) return null
        return roomPath.matchEntire(uri.rawPath.orEmpty())?.groupValues?.get(1)
    }

    fun metadata(item: JSONObject, page: String, requests: JSONArray = WebBrowserNetworkMedia.candidates(item)): JSONObject? {
        val id = room(page) ?: return null
        if (item.optString("frame") != page || item.optBoolean("protected") || !item.optBoolean("blob") ||
            !item.optBoolean("bilibili_ready") || item.optDouble("duration", -1.0) != 0.0 ||
            item.optInt("width") !in 1..8192 || item.optInt("height") !in 1..8192 ||
            !item.optString("bilibili_source").let { it.length in 32..512 && it.startsWith("blob:https://live.bilibili.com/") }) return null
        val data = item.optJSONObject("bilibili_live") ?: return null
        val quality = data.optInt("quality")
        val revision = data.optInt("revision")
        if (data.optString("page") != page || data.optString("room") != id || quality !in 1..100000 ||
            revision <= 0 || data.optDouble("quality") != quality.toDouble() ||
            data.optDouble("revision") != revision.toDouble()) return null
        val address = playlist(data.optString("url")) ?: return null
        val master = data.optString("master")
        if (master.isNotEmpty() && playlist(master)?.host?.matches(cdn) != true) return null
        if (!cdn.matches(address.host) && !(master.isNotEmpty() && delegatedCdn.matches(address.host))) return null
        val request = (0 until requests.length()).mapNotNull(requests::optJSONObject).singleOrNull {
            it.optString("kind") == "hls" && it.optString("url") == address.toString() &&
                (it.optJSONObject("headers")?.length() ?: 0) > 0
        } ?: return null
        if (System.currentTimeMillis() - request.optLong("at") !in 0L..1800000L) return null
        if (master.isNotEmpty() && (!request.optBoolean("live_leaf") ||
                (0 until requests.length()).mapNotNull(requests::optJSONObject).none {
                    it.optString("kind") == "hls" && it.optString("url") == master &&
                        it.optString("live_child") == address.toString() &&
                        System.currentTimeMillis() - it.optLong("at") in 0L..1800000L
                })) return null
        val stream = data.optString("stream")
        val switchAt = data.optLong("switch_at")
        if (data.has("stream") || data.has("switch_at")) {
            val qn = address.rawQuery.orEmpty().split('&').filter { it.substringBefore('=') == "qn" }
            if (master.isNotEmpty() || !request.optBoolean("live_leaf") || request.has("live_child") ||
                !streamName.matches(stream) || stream !in address.rawPath.split('/') ||
                qn != listOf("qn=$quality") || switchAt <= 0 || data.optDouble("switch_at") != switchAt.toDouble() ||
                request.optLong("at") < switchAt) return null
        }
        return JSONObject().put("page", page).put("room", id).put("quality", quality)
            .put("revision", revision).put("url", address.toString()).apply {
                if (master.isNotEmpty()) put("master", master)
                if (stream.isNotEmpty()) put("stream", stream).put("switch_at", switchAt)
            }
    }
}
