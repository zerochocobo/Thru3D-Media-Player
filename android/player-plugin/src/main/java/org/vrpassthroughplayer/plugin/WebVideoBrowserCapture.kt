package org.vrpassthroughplayer.plugin

import org.json.JSONArray
import org.json.JSONObject
import java.net.URI

/** An already-playing HTML5 resource, captured inside the user's browser session. */
internal object WebVideoBrowserCapture {
    /** Authenticated server originals follow the normal local/network decoder path. A web
     * transcode's dimensions do not describe its original file; website extraction caps
     * must not silently reject an 8K media-server source. Actual decode remains device-owned. */
    fun maximumHeight(media: JSONObject?, browserQuality: Boolean, diagnostics: Boolean): Int {
        if (media != null && serverPage(media.optString("frame"), media) != null) return 8192
        if (browserQuality) return maxOf(2160, minOf(media?.optInt("width") ?: 0, media?.optInt("height") ?: 0)).coerceAtMost(8192)
        return if (diagnostics && media?.optInt("diagnostic_max_height") == 2160) 2160 else 1080
    }
    fun serverPage(page: String, media: JSONObject): WebVideoPage? = runCatching {
        require(media.optBoolean("server") && !media.optBoolean("protected"))
        val frame = URI(page)
        val plex = WebBrowserPlexMedia.source(media.optString("source"), page, serverHeaders(media))
        if (plex != null) return WebVideoPage("media_server", plex.identity,
            "${frame.scheme}://${frame.rawAuthority}${frame.rawPath}#thru3d-plex=${plex.identity}")
        val source = URI(WebBrowserServerMedia.original(media.optString("source"), page) ?: return null)
        // A stable in-memory identity without the signed media URL or site credentials.
        val item = source.path.substringBeforeLast('/').substringAfterLast('/')
        val version = source.rawQuery.split('&').first { it.startsWith("MediaSourceId=") }
        WebVideoPage("media_server", item, "${frame.scheme}://${frame.rawAuthority}${frame.rawPath}#thru3d-video=$item&$version")
    }.getOrNull()
    fun serverHeaders(media: JSONObject): Map<String, String> = media.optJSONObject("server_headers")?.let { data ->
        data.keys().asSequence().take(4).associateWith { data.optString(it) }
    }.orEmpty()

    fun formats(media: JSONObject, cookies: JSONArray = JSONArray(),
        readServer: ((URI, Map<String, String>) -> Pair<URI, ByteArray>)? = null): JSONObject? = runCatching {
        require(!media.optBoolean("protected"))
        if (media.optBoolean("server")) WebBrowserPlexMedia.source(media.optString("source"), media.optString("frame"), serverHeaders(media))?.let {
            return WebVideoPlexCapture.formats(media, it, readServer)
        }
        val uri = URI(if (media.optBoolean("server")) WebBrowserServerMedia.original(media.getString("source"), media.getString("frame")) ?: return null
            else media.getString("source"))
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
