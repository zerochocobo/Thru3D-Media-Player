package org.vrpassthroughplayer.plugin

import org.json.JSONArray
import org.json.JSONObject
import kotlin.math.abs

/** A whole muxed file, or an explicitly bound pair of whole video/audio files.
 * Music soundtracks, previews, unrelated players and unobserved backups stay on the website. */
internal object WebVideoDouyinCapture {
    fun page(value: String): WebVideoPage? = WebBrowserDouyin.pageId(value)?.let {
        WebVideoPage("douyin", it, "https://www.douyin.com/video/$it")
    }

    fun candidate(page: WebVideoPage, media: JSONObject): JSONObject? = runCatching {
        require(page.site == "douyin" && media.optBoolean("douyin_enabled") && !media.optBoolean("protected"))
        val data = media.getJSONObject("douyin")
        require(data.toString().length <= 96 * 1024 && data.getString("id") == page.id)
        require(data.getString("page") == media.getString("frame") && WebVideoDouyinCapture.page(data.getString("page")) == page)
        val duration = data.getDouble("duration")
        require(duration.isFinite() && duration > 0 && duration <= 86400)
        require(abs(duration - media.getDouble("duration")) <= maxOf(.5, duration * .01))
        val width = media.getInt("width"); val height = media.getInt("height")
        require(width in 1..8192 && height in 1..8192)
        val tracks = data.getJSONArray("video"); require(tracks.length() in 1..33)
        val browserSource = media.getString("source")
        val observedFile = data.optString("observed_file")
        val source = if (media.optBoolean("blob")) {
            require(browserSource.isEmpty() && observedFile.isNotEmpty() && !data.optBoolean("observed_direct"))
            observedFile
        } else {
            require(observedFile.isEmpty() || observedFile == browserSource)
            browserSource
        }
        if (data.optBoolean("observed_direct")) require(WebBrowserDouyin.sourceId(source) == page.id)
        require((0 until tracks.length()).any { i ->
            val t = tracks.getJSONObject(i); val urls = t.getJSONArray("urls")
            require(urls.length() in 1..8)
            t.optInt("width") == width && t.optInt("height") == height &&
                (0 until urls.length()).any { WebBrowserDouyin.matches(urls.getString(it), source, page.id) }
        })
        val requests = WebBrowserNetworkMedia.candidates(media)
        val matches = (0 until requests.length()).map { requests.getJSONObject(it) }
            .filter { it.optString("kind") == "file" && it.optString("url") == source }
        require(matches.size == 1)
        val audioSource = data.optString("observed_audio")
        val selected = matches.toMutableList()
        if (audioSource.isNotEmpty()) {
            require(media.optBoolean("blob") && audioSource != source)
            val audioTracks = data.getJSONArray("audio"); require(audioTracks.length() in 1..8)
            require((0 until audioTracks.length()).any { i ->
                val urls = audioTracks.getJSONObject(i).getJSONArray("urls"); require(urls.length() in 1..8)
                (0 until urls.length()).any { WebBrowserDouyin.matches(urls.getString(it), audioSource, page.id) }
            })
            val observed = (0 until requests.length()).map { requests.getJSONObject(it) }
                .filter { it.optString("kind") == "file" && it.optString("url") == audioSource }
            require(observed.size == 1); selected.add(observed.single())
        }
        JSONObject(media.toString()).put("source", source).put("network", JSONArray(selected)).put("duration", duration)
    }.getOrNull()

    fun resolve(page: WebVideoPage, media: JSONObject, network: WebVideoNetworkCapture): JSONObject? {
        val bound = candidate(page, media) ?: return null
        val audioSource = bound.getJSONObject("douyin").optString("observed_audio")
        val info = (if (audioSource.isEmpty()) network.resolve(page, bound) else
            network.resolveBoundPair(page, bound, java.net.URI(bound.getString("source")), java.net.URI(audioSource))) ?: return null
        val formats = info.optJSONArray("formats") ?: return null
        if (formats.length() != if (audioSource.isEmpty()) 1 else 2) return null
        val file = (0 until formats.length()).map { formats.getJSONObject(it) }.singleOrNull {
            it.optString("url") == bound.optString("source") && it.optString("vcodec") !in setOf("", "none", "unknown")
        } ?: return null
        // Real container inspection must confirm both tracks. Never label unknown audio as AAC.
        if (file.optString("vcodec") in setOf("", "none", "unknown") ||
            audioSource.isEmpty() && file.optString("acodec") in setOf("", "none", "unknown") ||
            file.optInt("width") != media.optInt("width") || file.optInt("height") != media.optInt("height")) return null
        if (audioSource.isNotEmpty() && (0 until formats.length()).none { i ->
            val audio = formats.getJSONObject(i)
            audio.optString("url") == audioSource && audio.optString("vcodec") == "none" && audio.optString("acodec") !in setOf("", "none", "unknown")
        }) return null
        return info
    }
}
