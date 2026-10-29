package org.vrpassthroughplayer.plugin

import org.json.JSONArray
import org.json.JSONObject
import java.net.URI

/** Browser credentials are either scoped cookies or an exact observed request. */
internal class WebVideoRequestHeaders(private val observed: Map<String, Map<String, String>>, private val cookies: JSONArray) {
    fun forUrl(target: URI, fallback: Map<String, String>): Map<String, String> {
        val result = fallback.filterKeys { it.lowercase() in setOf("user-agent", "referer", "origin", "accept", "accept-language") }.toMutableMap()
        WebVideoBrowserCapture.cookieHeader(cookies, target)?.let { result["cookie"] = it }
        observed[target.toString()]?.forEach { (key, value) -> result[key.lowercase()] = value }
        return result
    }
    companion object {
        fun parse(format: JSONObject): WebVideoRequestHeaders? {
            val data = format.optJSONObject("browser_headers") ?: return null
            require(data.length() <= 24 && data.toString().length <= 192 * 1024)
            val observed = data.keys().asSequence().associateWith { key ->
                require(WebBrowserNetworkMedia.address(key) != null)
                val headers = data.getJSONObject(key); require(headers.length() <= 24)
                headers.keys().asSequence().associate { name ->
                    val value = headers.getString(name)
                    require(name.matches(Regex("[A-Za-z0-9-]{1,128}")) && value.length <= 8192 && value.none { it < ' ' || it == '\u007f' })
                    name.lowercase() to value
                }
            }
            val cookies = format.optJSONArray("browser_cookies") ?: JSONArray()
            require(cookies.length() <= 256 && cookies.toString().length <= 65536)
            return WebVideoRequestHeaders(observed, cookies)
        }
    }
}
