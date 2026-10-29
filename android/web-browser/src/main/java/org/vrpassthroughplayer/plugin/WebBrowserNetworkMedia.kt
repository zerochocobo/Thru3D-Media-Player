package org.vrpassthroughplayer.plugin

import org.json.JSONArray
import org.json.JSONObject
import java.net.URI
import java.util.Locale

/** Bounded private bridge data. Only availability/epoch, never URLs or headers, is public. */
object WebBrowserNetworkMedia {
    fun address(value: String): URI? = runCatching {
        require(value.length in 1..16384)
        URI(value).also { require(it.scheme in setOf("http", "https") && !it.host.isNullOrEmpty() && it.rawUserInfo == null && it.fragment == null) }
    }.getOrNull()

    fun candidates(item: JSONObject): JSONArray {
        val result = JSONArray()
        if (item.optBoolean("protected")) return result
        val list = item.optJSONArray("network") ?: return result
        if (list.length() > 24 || list.toString().length > 192 * 1024) return result
        for (i in 0 until list.length()) {
            val source = list.optJSONObject(i) ?: continue
            val uri = address(source.optString("url")) ?: continue
            val kind = source.optString("kind")
            if (kind !in setOf("file", "hls", "dash")) continue
            val input = source.optJSONObject("headers") ?: JSONObject()
            if (input.length() > 24 || input.toString().length > 32768) continue
            val headers = JSONObject()
            for (key in input.keys()) {
                val name = key.lowercase(Locale.ROOT); val value = input.optString(key)
                if (!Regex("(?:user-agent|referer|origin|cookie|authorization|accept|accept-language|x-[a-z0-9-]{1,100})").matches(name) ||
                    value.length > 8192 || value.any { it < ' ' || it == '\u007f' }) continue
                headers.put(name, value)
            }
            result.put(JSONObject().put("url", uri.toString()).put("kind", kind).put("headers", headers)
                .put("original_url", address(source.optString("original_url"))?.toString() ?: uri.toString())
                .put("cookies", source.optJSONArray("cookies")?.takeIf { it.length() <= 128 && it.toString().length <= 24576 } ?: JSONArray())
                .put("mime", source.optString("mime").take(128)))
        }
        return result
    }
}
