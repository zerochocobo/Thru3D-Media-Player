package org.vrpassthroughplayer.plugin

import java.net.URI
import org.json.JSONObject

/** The rendered detail card and its active SDK file, not a bitrate/music guess. */
object WebBrowserTikTok {
    private const val ENABLED = true // Current detail clip verified with real button/native/seek/retained return.
    fun document(value: String): Boolean = runCatching {
        val u = URI(value)
        value.length <= 8192 && u.scheme == "https" && u.host in setOf("www.tiktok.com", "tiktok.com") &&
            u.rawUserInfo == null && u.port in setOf(-1, 443)
    }.getOrDefault(false)
    fun observing(value: String) = ENABLED && document(value)
    fun enabled(value: String) = ENABLED && page(value) != null
    fun page(value: String): String? = runCatching {
        require(document(value))
        val u = URI(value); require(u.rawFragment == null)
        Regex("/@[A-Za-z0-9_.]{1,64}/video/([1-9][0-9]{14,19})/?").matchEntire(u.rawPath.orEmpty())?.groupValues?.get(1)
    }.getOrNull()

    fun metadata(item: JSONObject, currentPage: String): JSONObject? = runCatching {
        val id = page(currentPage) ?: return null
        require(item.optString("frame") == currentPage && !item.optBoolean("protected"))
        val data = item.getJSONObject("tiktok")
        require(data.toString().length <= 24 * 1024 && data.getString("id") == id && data.getString("page") == currentPage)
        require(data.getString("revision").matches(Regex("[a-f0-9]{1,8}")))
        val observed = item.getString("tiktok_source")
        if (item.optBoolean("blob")) require(observed.startsWith("blob:https://www.tiktok.com/") || observed.startsWith("blob:https://tiktok.com/"))
        else require(observed == item.getString("source") && observed == data.getString("source"))
        val source = data.getString("source")
        require(WebBrowserNetworkMedia.address(source)?.scheme == "https")
        val width = item.getInt("width"); val height = item.getInt("height"); val duration = item.getDouble("duration")
        require(width in 1..8192 && height in 1..8192 && width == data.getInt("width") && height == data.getInt("height"))
        require(duration.isFinite() && duration > 0 && duration <= 86400 && kotlin.math.abs(duration - data.getDouble("duration")) <= .001)
        val expected = data.getDouble("expected_duration")
        require(expected.isFinite() && expected > 0 && expected <= 86400 && kotlin.math.floor(duration) == expected)
        val requests = WebBrowserNetworkMedia.candidates(item)
        require((0 until requests.length()).any { val r = requests.getJSONObject(it); r.optString("kind") == "file" && r.optString("url") == source })
        data
    }.getOrNull()
}
