package org.vrpassthroughplayer.plugin

import org.json.JSONArray
import org.json.JSONObject
import java.net.URI

/** An already-playing HTML5 resource, captured inside the user's browser session. */
internal object WebVideoBrowserCapture {
    fun formats(media: JSONObject, cookies: JSONArray = JSONArray()): JSONObject? = runCatching {
        require(!media.optBoolean("protected"))
        val uri = URI(media.getString("source"))
        require(uri.scheme in setOf("https", "http") && !uri.host.isNullOrEmpty() && uri.rawUserInfo == null && uri.fragment == null)
        require(!uri.path.endsWith(".mpd", true)) // Blob/MSE and DRM stay in the browser.
        val frame = URI(media.getString("frame"))
        require(frame.scheme in setOf("https", "http") && frame.rawUserInfo == null)
        val hls = uri.path.endsWith(".m3u8", true)
        val headers = JSONObject().put("Referer", frame.toString())
        cookieHeader(cookies, uri)?.let { headers.put("Cookie", it) }
        media.optString("agent").takeIf { it.length in 1..2048 && it.none { c -> c < ' ' } }?.let { headers.put("User-Agent", it) }
        val format = JSONObject().put("format_id", "browser").put("url", uri.toString())
            .put("protocol", if (hls) "m3u8_native" else uri.scheme).put("ext", if (uri.path.endsWith(".webm", true)) "webm" else "mp4")
            .put("vcodec", "unknown").put("acodec", "unknown")
            .put("width", media.optInt("width")).put("height", media.optInt("height"))
            .put("web_layout", media.optString("layout").take(64))
            .put("http_headers", headers)
        JSONObject().put("title", media.optString("title")).put("duration", media.optDouble("duration", 0.0))
            .put("formats", JSONArray().put(format))
    }.getOrNull()

    internal fun cookieHeader(cookies: JSONArray, uri: URI): String? {
        require(cookies.length() <= 256)
        val host = uri.host.lowercase(java.util.Locale.ROOT)
        val path = uri.path.ifEmpty { "/" }
        val matched = ArrayList<Pair<Int, String>>()
        for (i in 0 until cookies.length()) {
            val c = cookies.optJSONObject(i) ?: continue
            val domain = c.optString("domain").trimStart('.').lowercase(java.util.Locale.ROOT)
            if (domain.isEmpty() || !(host == domain || (!c.optBoolean("hostOnly") && host.endsWith(".$domain")))) continue
            if (c.optBoolean("secure") && uri.scheme != "https") continue
            if (c.has("expirationDate") && !c.isNull("expirationDate")) {
                val expires = c.optDouble("expirationDate", 0.0)
                if (!expires.isFinite() || expires <= System.currentTimeMillis() / 1000.0) continue
            }
            val cookiePath = c.optString("path", "/")
            if (!cookiePath.startsWith('/') || !(path == cookiePath || path.startsWith(cookiePath) && (cookiePath.endsWith('/') || path.getOrNull(cookiePath.length) == '/'))) continue
            val name = c.optString("name"); val value = c.optString("value")
            if (!Regex("[!#$%&'*+.^_`|~0-9a-zA-Z-]{1,256}").matches(name) || value.length > 8192 || value.any { it < ' ' || it > '~' || it == ';' }) continue
            matched.add(cookiePath.length to "$name=$value")
        }
        val header = matched.sortedByDescending { it.first }.joinToString("; ") { it.second }
        require(header.length <= 8192)
        return header.takeIf(String::isNotEmpty)
    }
}
