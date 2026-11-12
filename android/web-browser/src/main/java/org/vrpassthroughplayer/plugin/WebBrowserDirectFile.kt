package org.vrpassthroughplayer.plugin

import org.json.JSONObject
import java.util.Locale

/** A whole file observed for this exact DOM video, never a nearby preload or MSE segment. */
object WebBrowserDirectFile {
    fun resource(media: JSONObject, now: Long = System.currentTimeMillis()): JSONObject? {
        if (!media.optBoolean("direct_allowed") || !media.optBoolean("network_enabled") ||
            media.optBoolean("protected") || media.optBoolean("server") || media.optBoolean("blob") ||
            media.optInt("width") !in 0..16384 || media.optInt("height") !in 0..16384 || media.optLong("network_epoch") <= 0) return null
        val source = media.optString("source")
        if (WebBrowserNetworkMedia.address(source) == null) return null
        val observed = WebBrowserNetworkMedia.candidates(media)
        val matches = (0 until observed.length()).map { observed.getJSONObject(it) }.filter {
            val uri = WebBrowserNetworkMedia.address(it.optString("url")) ?: return@filter false
            val mime = it.optString("mime").substringBefore(';').trim().lowercase(Locale.ROOT)
            it.optString("kind") == "file" && (it.optString("url") == source || it.optString("original_url") == source) &&
                now - it.optLong("at") in 0..1_800_000L &&
                (mime in setOf("video/mp4", "video/webm", "video/x-matroska", "video/quicktime") ||
                    mime in setOf("", "application/octet-stream") && Regex("(?i)\\.(mp4|m4v|webm|mkv|mov)$").containsMatchIn(uri.path))
        }.distinctBy { it.optString("url") }
        return matches.singleOrNull()
    }

    /** Public snapshot only. Ambiguous players never select the largest advertisement. */
    fun selection(videos: List<JSONObject>): String {
        val full = videos.filter { it.optBoolean("fullscreen") }
        val playing = videos.filter { it.optBoolean("playing") }
        val selected = (if (full.isNotEmpty()) full else if (playing.isNotEmpty()) playing else videos).singleOrNull()
        return selected?.takeIf { it.optBoolean("direct_ready") && !it.optBoolean("protected") }?.optString("selection").orEmpty()
    }
}
