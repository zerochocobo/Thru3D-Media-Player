package org.vrpassthroughplayer.plugin

import java.net.URI
import java.net.URLDecoder
import java.nio.charset.StandardCharsets
import org.json.JSONObject

/** Public finite clips, bound to the exact current DOM file and observed request. */
object WebBrowserTwitch {
    private const val ENABLED = true // Public clip button/file audio-video/seek/retained-return passed locally.
    fun enabled(value: String) = ENABLED && page(value) != null
    fun page(value: String): String? = runCatching {
        require(value.length <= 8192)
        val u = URI(value)
        require(u.scheme == "https" && u.rawUserInfo == null && u.rawFragment == null && u.port in setOf(-1, 443))
        when (u.host) {
            "clips.twitch.tv" -> Regex("/([A-Za-z0-9_-]{1,200})/?").matchEntire(u.rawPath.orEmpty())?.groupValues?.get(1)
                ?.takeUnless { it in setOf("embed", "create", "manage") }
            "www.twitch.tv", "twitch.tv" -> Regex("/[A-Za-z0-9_]{1,25}/clip/([A-Za-z0-9_-]{1,200})/?").matchEntire(u.rawPath.orEmpty())?.groupValues?.get(1)
            else -> null
        }
    }.getOrNull()

    fun handoffPage(value: String): String {
        if (page(value) == null) return value
        val query = URI(value).rawQuery ?: return value
        val fields = query.split('&').toMutableList()
        val range = fields.indices.singleOrNull {
            URLDecoder.decode(fields[it].substringBefore('='), StandardCharsets.UTF_8.name()) == "range"
        } ?: return value
        if (fields[range] !in setOf("range=24hr", "range=7d", "range=30d", "range=all")) return value
        // This is the live document's handoff identity, not a network request URL.
        fields.removeAt(range)
        return value.substringBefore('?') + if (fields.isEmpty()) "" else "?" + fields.joinToString("&")
    }

    fun sameHandoffPage(left: String, right: String): Boolean = left == right || handoffPage(left) == handoffPage(right)

    fun metadata(item: JSONObject, currentPage: String): JSONObject? = runCatching {
        val id = page(currentPage) ?: return null
        val frame = item.optString("frame")
        require(sameHandoffPage(frame, currentPage) && !item.optBoolean("protected") && !item.optBoolean("blob"))
        val data = item.getJSONObject("twitch")
        require(data.toString().length <= 24 * 1024 && data.getString("id") == id && data.getString("page") == frame)
        require(data.getString("revision").matches(Regex("[a-f0-9]{1,8}")))
        val source = item.getString("source")
        require(source == data.getString("source") && WebBrowserNetworkMedia.address(source)?.let { it.scheme == "https" && it.path.endsWith(".mp4") } == true)
        val width = item.getInt("width"); val height = item.getInt("height"); val duration = item.getDouble("duration")
        require(width in 1..16384 && height in 1..16384 && width == data.getInt("width") && height == data.getInt("height"))
        require(duration.isFinite() && duration > 0 && duration <= 3600 && kotlin.math.abs(duration - data.getDouble("duration")) <= .001)
        val expected = data.getDouble("expected_duration")
        require(expected.isFinite() && expected > 0 && expected <= 3600 &&
            (kotlin.math.abs(duration - expected) <= .5 ||
                expected == kotlin.math.floor(expected) && kotlin.math.floor(duration) == expected))
        val requests = WebBrowserNetworkMedia.candidates(item)
        require((0 until requests.length()).any { val r = requests.getJSONObject(it); r.optString("kind") == "file" && r.optString("url") == source })
        data
    }.getOrNull()
}
