package org.vrpassthroughplayer.plugin

import org.json.JSONObject
import java.net.URI

/** No extractor, manifest discovery, container probe or quality reselection. mpv opens the observed file. */
internal object WebVideoDirectFile {
    fun descriptor(url: String, media: JSONObject): WebVideoDescriptor? {
        val file = WebBrowserDirectFile.resource(media) ?: return null
        val page = WebVideoNetworkCapture.page(url, media) ?: return null
        val uri = URI(file.getString("url"))
        val input = file.getJSONObject("headers")
        val observed = input.keys().asSequence().associateWith { input.getString(it) }
        val headers = WebVideoRequestHeaders(mapOf(uri.toString() to observed), file.getJSONArray("cookies"))
            .forUrl(uri, emptyMap())
        val extension = when (file.optString("mime").substringBefore(';').lowercase()) {
            "video/webm" -> "webm"
            "video/x-matroska" -> "mkv"
            "video/quicktime" -> "mov"
            else -> uri.path.substringAfterLast('.').lowercase().takeIf { it in setOf("webm", "mkv", "mov") } ?: "mp4"
        }
        // Unknown tracks are discovered by the normal player, including silent files.
        val track = WebVideoTrack("captured-file", uri, headers, extension, "unknown", "unknown",
            media.optInt("width"), media.optInt("height"), 0.0)
        return WebVideoDescriptor(page, media.optString("title").take(1024), track, null,
            media.optDouble("duration", 0.0).takeIf { it.isFinite() && it >= 0 } ?: 0.0)
    }
}
