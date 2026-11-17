package org.vrpassthroughplayer.plugin

import org.json.JSONObject
import java.net.URI
import kotlin.math.abs

/** Declaration/capability investigation only. Never authorizes a request or changes selection. */
internal object WebVideoBilibiliHevcDiagnostics {
    data class Candidate(val codec: String, val width: Int, val height: Int, val fps: Double, val observed: Boolean) {
        fun probe() = WebVideoTrack("capability-only", URI("https://capability.invalid/probe"), emptyMap(),
            "mp4", codec, "none", width, height, fps)
    }

    fun candidates(page: WebVideoPage, media: JSONObject): List<Candidate> = runCatching {
        // Reuse production binding before looking at alternate declarations. Raw URLs stay here.
        val bound = WebVideoBilibiliCapture.formats(page, media) ?: return emptyList()
        val video = bound.getJSONArray("formats").getJSONObject(0)
        val declared = media.getJSONObject("bilibili").getJSONArray("video")
        val tracks = (0 until declared.length()).map { declared.getJSONObject(it) }
        fun urls(track: JSONObject): Set<String> = track.getJSONArray("urls").let { list ->
            require(list.length() in 1..9)
            (0 until list.length()).map { list.getString(it) }.toSet()
        }
        val selected = tracks.first { video.getString("url") in urls(it) && it.getString("codec") == video.getString("vcodec") }
        // The current source is already HEVC; this report is for a different-codec alternative.
        if (selected.getString("codec").startsWith("hev1.") || selected.getString("codec").startsWith("hvc1.")) return emptyList()
        val network = WebBrowserNetworkMedia.candidates(media)
        val observed = (0 until network.length()).map { network.getJSONObject(it) }
            .filter { it.optString("kind") == "file" }.map { it.optString("url") }.toSet()
        tracks.mapNotNull { track ->
            val codec = track.getString("codec")
            val fps = track.optDouble("fps")
            if (!codec.matches(Regex("(?:hev1|hvc1)\\.[A-Za-z0-9.]{1,90}")) ||
                track.optInt("id") != selected.getInt("id") ||
                track.optInt("width") != video.getInt("width") || track.optInt("height") != video.getInt("height") ||
                !fps.isFinite() || fps <= 0 || fps > 240 || abs(fps - video.getDouble("fps")) > .01) null
            else Candidate(codec, video.getInt("width"), video.getInt("height"), fps, urls(track).any { it in observed })
        }.distinct().take(3)
    }.getOrDefault(emptyList())

    fun log(page: WebVideoPage, media: JSONObject, maxHeight: Int, id: Int) {
        val alternatives = candidates(page, media)
        CrashTrail.mark("web_beta.hevc", "id=$id same_quality=${alternatives.size} requested=${alternatives.count { it.observed }} probe_only=true")
        val capabilities = WebVideoCapabilities(maxHeight)
        alternatives.forEach { candidate ->
            val report = capabilities.inspect(candidate.probe())
            // 'supported' describes the same conservative capability predicate, not actual decode.
            CrashTrail.mark("web_beta.hevc", "id=$id supported=${report.accepted} reason=${report.reason}")
            report.details(id).forEach { CrashTrail.mark("web_beta.hevc_cap", it) }
        }
    }
}
