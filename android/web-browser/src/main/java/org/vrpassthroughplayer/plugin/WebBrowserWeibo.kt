package org.vrpassthroughplayer.plugin

import java.net.URI
import org.json.JSONObject

/** Direct feed players only. The DOM owner and the exact observed request must agree. */
object WebBrowserWeibo {
    fun document(value: String): Boolean = runCatching {
        val u = URI(value)
        u.scheme == "https" && u.host in setOf("weibo.com", "www.weibo.com") && u.port == -1 && u.rawUserInfo == null
    }.getOrDefault(false)

    fun page(value: String): Pair<String, String>? = runCatching {
        require(document(value))
        val u = URI(value)
        require(u.rawQuery == null && u.fragment == null)
        val fid = Regex("/tv/show/([0-9]+:(?:[0-9a-f]{32}|[0-9]{16,}))/?").matchEntire(u.path)?.groupValues?.get(1)
        if (fid != null) return fid to "https://weibo.com/tv/show/$fid"
        val post = Regex("/([0-9]+)/([A-Za-z0-9]{5,32})/?").matchEntire(u.path) ?: return null
        post.groupValues[2] to "https://weibo.com/${post.groupValues[1]}/${post.groupValues[2]}"
    }.getOrNull()

    fun metadata(item: JSONObject, currentPage: String): JSONObject? = runCatching {
        require(document(currentPage) && item.optString("frame") == currentPage && !item.optBoolean("protected") && !item.optBoolean("blob"))
        val data = item.getJSONObject("weibo")
        require(data.toString().length <= 24 * 1024)
        val page = page(data.getString("page")) ?: return null
        require(page.first == data.getString("id") && page.second == data.getString("page"))
        val source = item.getString("source")
        val uri = WebBrowserNetworkMedia.address(source) ?: return null
        require(uri.scheme == "https" && source == data.getString("source"))
        require(item.optInt("width") in 1..8192 && item.optInt("height") in 1..8192)
        val duration = item.getDouble("duration")
        require(duration.isFinite() && duration > 0 && duration <= 86400)
        val list = WebBrowserNetworkMedia.candidates(item)
        val matches = (0 until list.length()).map { list.getJSONObject(it) }.filter {
            it.optString("kind") == "file" && (it.optString("url") == source || it.optString("original_url") == source)
        }
        require(matches.map { it.getString("url") }.distinct().size == 1)
        data
    }.getOrNull()
}
