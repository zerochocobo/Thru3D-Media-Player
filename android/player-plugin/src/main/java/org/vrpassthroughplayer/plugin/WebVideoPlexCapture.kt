package org.vrpassthroughplayer.plugin

import java.net.URI
import org.json.JSONArray
import org.json.JSONObject

/** Convert the browser's selected local Plex version to its authenticated original. */
internal object WebVideoPlexCapture {
    fun formats(media: JSONObject, source: WebBrowserPlexMedia.Source,
        read: ((URI, Map<String, String>) -> Pair<URI, ByteArray>)?): JSONObject? {
        require(!media.optBoolean("protected"))
        var original = source.original
        var width = media.optInt("width"); var height = media.optInt("height")
        var duration = media.optDouble("duration", 0.0)
        var extension = original?.path?.substringAfterLast('.', "mp4")?.lowercase() ?: "mp4"
        if (original == null) {
            val metadata = source.metadata ?: return null
            val (final, bytes) = (read ?: return null)(metadata, source.headers + ("Accept" to "application/json"))
            require(final == metadata && bytes.size <= 2 * 1024 * 1024)
            val items = JSONObject(String(bytes, Charsets.UTF_8)).getJSONObject("MediaContainer").getJSONArray("Metadata")
            require(items.length() == 1)
            val item = items.getJSONObject(0)
            require(item.optString("ratingKey") == source.item && item.optString("type") in setOf("movie", "episode", "clip"))
            val versions = item.getJSONArray("Media")
            val version = if (source.mediaIndex < 0) { require(versions.length() == 1); 0 } else source.mediaIndex
            val selected = versions.getJSONObject(version)
            require(selected.optString("origin") !in setOf("livetv", "cloud") && !selected.optBoolean("drm"))
            // Joining multipart titles changes their timeline. Preserve the existing Plex
            // library rule: only an unambiguous single original can be handed off.
            val parts = selected.getJSONArray("Part")
            require(parts.length() == 1 && source.partIndex in -1..0)
            val part = parts.getJSONObject(0)
            require(part.optBoolean("exists", true) && part.optBoolean("accessible", true) && part.optString("license").isBlank())
            val key = part.getString("key")
            require(key.startsWith("/library/parts/"))
            val candidate = URI(source.base + key)
            val verified = WebBrowserPlexMedia.source(candidate.toString(), media.getString("frame"), source.headers)
                ?: error("Invalid Plex original")
            val file = verified.original ?: error("Plex original unavailable")
            require(candidate == file && part.optString("id") == verified.item)
            original = file
            width = selected.optInt("width"); height = selected.optInt("height")
            val millis = part.optLong("duration", selected.optLong("duration", item.optLong("duration")))
            require(millis > 0)
            val browserDuration = media.optDouble("duration", 0.0)
            if (browserDuration > 0) require(kotlin.math.abs(browserDuration + source.offset - millis / 1000.0) <= maxOf(2.0, millis / 100000.0))
            duration = millis / 1000.0
            extension = selected.optString("container", "mp4").lowercase()
        }
        val target = original
        val format = JSONObject().put("format_id", "plex-original").put("url", target.toString())
            .put("protocol", target.scheme).put("ext", extension.takeIf { it in setOf("mp4", "mkv", "mov", "webm") } ?: "mkv")
            .put("vcodec", "unknown").put("acodec", "unknown").put("width", width).put("height", height)
            .put("http_headers", JSONObject(source.headers))
        return JSONObject().put("title", media.optString("title", "Plex")).put("duration", duration)
            .put("formats", JSONArray().put(format))
    }
}
