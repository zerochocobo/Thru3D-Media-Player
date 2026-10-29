package org.vrpassthroughplayer.plugin

import org.json.JSONObject
import java.net.URI
import java.net.URLDecoder
import java.util.Locale

/** Stable public identity. Signed CDN locations and request headers never enter Godot/history. */
internal data class WebVideoPage(val site: String, val id: String, val url: String) {
    companion object {
        fun parse(value: String): WebVideoPage {
            require(value.length in 1..8192) { "Invalid video page" }
            val text = value.trim()
            // Mobile share sheets often wrap the one link in a caption.
            val links = Regex("https?://[^\\s<>\\\"，。]+", RegexOption.IGNORE_CASE).findAll(text).map { it.value }.toList()
            val uri = URI(if (text.startsWith("https://") || text.startsWith("http://")) text else links.singleOrNull() ?: text)
            require(uri.scheme in setOf("https", "http") && uri.rawUserInfo == null && uri.port in setOf(-1, 80, 443)) { "Invalid video page" }
            val host = uri.host?.lowercase(Locale.ROOT) ?: error("Invalid video page")
            val query = uri.rawQuery.orEmpty().split('&').filter { it.isNotEmpty() }.associate {
                URLDecoder.decode(it.substringBefore('='), "UTF-8") to URLDecoder.decode(it.substringAfter('=', ""), "UTF-8")
            }
            if (host in setOf("youtube.com", "www.youtube.com", "m.youtube.com", "music.youtube.com", "youtu.be")) {
                val id = if (host == "youtu.be") uri.path.removePrefix("/") else when {
                    uri.path == "/watch" -> query["v"].orEmpty()
                    uri.path.startsWith("/shorts/") || uri.path.startsWith("/embed/") || uri.path.startsWith("/live/") -> uri.path.split('/').getOrElse(2) { "" }
                    else -> ""
                }
                require(id.matches(Regex("[A-Za-z0-9_-]{11}"))) { "Choose a YouTube video" }
                return WebVideoPage("youtube", id, "https://www.youtube.com/watch?v=$id")
            }
            if (host in setOf("bilibili.com", "www.bilibili.com", "m.bilibili.com")) {
                val match = Regex("/video/(BV[A-Za-z0-9]{10}|av[0-9]+)(?:/)?").matchEntire(uri.path)
                require(match != null) { "Choose a Bilibili video" }
                val id = match.groupValues[1]
                val part = query["p"]?.toIntOrNull() ?: 1
                require(part in 1..10000) { "Invalid video part" }
                return WebVideoPage("bilibili", "$id:$part", "https://www.bilibili.com/video/$id/" + if (part > 1) "?p=$part" else "")
            }
            fun page(site: String, id: String, url: String): WebVideoPage {
                require(id.isNotEmpty() && id.length <= 512) { "Choose a video" }
                return WebVideoPage(site, id, url)
            }
            val path = uri.path.orEmpty()
            WebVideoInternationalPages.parse(uri, query)?.let { return it }
            // Douyin's web player keeps sound outside the <video> file and its extractor needs a
            // cookie the site no longer sets: a handoff would be silent. Keep it in the browser.
            if (host in setOf("douyin.com", "www.douyin.com", "m.douyin.com", "www.iesdouyin.com", "iesdouyin.com", "v.douyin.com"))
                error("Continue playing on the website")
            if (host in setOf("weibo.com", "www.weibo.com", "m.weibo.cn", "video.weibo.com")) {
                val fid = Regex("/tv/show/([0-9]+:(?:[0-9a-f]{32}|[0-9]{16,}))/?").matchEntire(path)?.groupValues?.get(1)
                    ?: query["fid"]?.takeIf { host == "video.weibo.com" && path.trimEnd('/') == "/show" && it.matches(Regex("[0-9]+:(?:[0-9a-f]{32}|[0-9]{16,})")) }
                if (fid != null) return page("weibo", fid, "https://weibo.com/tv/show/$fid")
                val match = (if (host == "m.weibo.cn") Regex("/(?:status|detail)/([A-Za-z0-9]+)/?")
                    else Regex("/[0-9]+/([A-Za-z0-9]+)/?")).matchEntire(path) ?: error("Choose a Weibo video")
                val id = match.groupValues[1]
                return page("weibo", id, if (host == "m.weibo.cn") "https://m.weibo.cn/detail/$id" else "https://weibo.com${path.trimEnd('/')}")
            }
            if (host in setOf("www.iqiyi.com", "iqiyi.com", "m.iqiyi.com")) {
                val id = Regex("/([vw]_[A-Za-z0-9]+)\\.html").matchEntire(path)?.groupValues?.get(1) ?: error("Choose an iQIYI video")
                return page("iqiyi", id, "https://www.iqiyi.com/$id.html")
            }
            if (host in setOf("www.mgtv.com", "mgtv.com", "w.mgtv.com")) {
                Regex("/s/([0-9]+)\\.html").matchEntire(path)?.groupValues?.get(1)?.let { id ->
                    // Site links now redirect /b/<collection>/<id>.html to /s/<id>.html;
                    // the extractor needs only the video id in its /b/ form.
                    return page("mgtv", id, "https://www.mgtv.com/b/$id.html")
                }
                val id = Regex("/[bv]/(?:[A-Za-z0-9_-]+/)*([0-9]+)\\.html").matchEntire(path)?.groupValues?.get(1) ?: error("Choose an MGTV video")
                return page("mgtv", id, "https://www.mgtv.com$path")
            }
            if (host in setOf("v.qq.com", "m.v.qq.com")) {
                val id = Regex("/x/(?:page|cover/[A-Za-z0-9]+)/([A-Za-z0-9]+)\\.html").matchEntire(path)?.groupValues?.get(1)
                    ?: query["vid"]?.takeIf { it.matches(Regex("[A-Za-z0-9]{8,32}")) }
                    ?: error("Choose a Tencent video")
                val canonical = if (path.startsWith("/x/cover/") && path.endsWith("/$id.html")) path else "/x/page/$id.html"
                return page("tencent", id, "https://v.qq.com$canonical")
            }
            if (host in setOf("v.youku.com", "m.youku.com", "player.youku.com")) {
                val id = Regex("/(?:v_show/id_|video/id_|player\\.php/sid/)([A-Za-z0-9=]+)(?:\\.html|/v\\.swf)?").matchEntire(path)?.groupValues?.get(1)
                    ?: error("Choose a Youku video")
                return page("youku", id, "https://v.youku.com/v_show/id_$id.html")
            }
            if (host in setOf("vimeo.com", "www.vimeo.com", "player.vimeo.com")) {
                val match = Regex("/(?:video/)?([0-9]+)(?:/([a-f0-9]{10}))?/?").matchEntire(path) ?: error("Choose a Vimeo video")
                // An unlisted access hash is required to resolve but must not enter history.
                require(match.groupValues[2].isEmpty() && query["h"].isNullOrEmpty()) { "Open this video in the browser" }
                return page("vimeo", match.groupValues[1], "https://vimeo.com/${match.groupValues[1]}")
            }
            if (host in setOf("www.dailymotion.com", "dailymotion.com", "geo.dailymotion.com", "dai.ly")) {
                val id = (if (host == "dai.ly") path.trim('/') else if (host == "geo.dailymotion.com" && path == "/player.html") query["video"]
                    else Regex("/(?:embed/)?video/([A-Za-z0-9]+)(?:_[^/]*)?/?").matchEntire(path)?.groupValues?.get(1))
                    ?.takeIf { it.matches(Regex("[A-Za-z0-9]{4,32}")) } ?: error("Choose a Dailymotion video")
                return page("dailymotion", id, "https://www.dailymotion.com/video/$id")
            }
            if (host in setOf("tubitv.com", "www.tubitv.com")) {
                val match = Regex("/(?:[a-z]{2}-[a-z]{2}/)?(movies|tv-shows|video)/([0-9]+)(?:/[^/]*)?/?").matchEntire(path) ?: error("Choose a Tubi video")
                return page("tubi", match.groupValues[2], "https://tubitv.com/${match.groupValues[1]}/${match.groupValues[2]}")
            }
            if (host in setOf("www.twitch.tv", "twitch.tv", "clips.twitch.tv", "m.twitch.tv")) {
                val clip = query["clip"]?.takeIf { host == "clips.twitch.tv" && path == "/embed" && it.matches(Regex("[A-Za-z0-9_-]{4,128}")) }
                if (clip != null) return page("twitch", clip, "https://clips.twitch.tv/$clip")
                require(Regex("/(?:videos/[0-9]+|[A-Za-z0-9_-]+/clip/[A-Za-z0-9_-]+|[A-Za-z0-9_-]+)/?").matches(path))
                return page("twitch", path.trim('/'), "https://$host${path.trimEnd('/')}")
            }
            if (host in setOf("www.redbull.com", "redbull.com", "www.redbull.tv", "redbull.tv")) {
                require(path.length > 1 && !path.contains("..")) { "Choose a video page" }
                return page("redbull", path.trim('/'), "https://$host${uri.rawPath}")
            }
            if (host in setOf("astalavr.com", "www.astalavr.com")) {
                require(Regex("/videos?/[A-Za-z0-9_-]+(?:/[^/]+)?/?").matches(path) && !path.contains("..")) { "Choose a video page" }
                return page("web", path.trim('/'), "https://$host${uri.rawPath}")
            }
            error("This video site is not supported yet")
        }
    }
}

/** Credentials remain in memory; deliberately no generated data-class toString/copy. */
internal class WebVideoTrack(
    val formatId: String, val url: URI, headers: Map<String, String>, val extension: String,
    val videoCodec: String, val audioCodec: String, val width: Int, val height: Int, val fps: Double,
    val bitrate: Double = 0.0, val chunkBytes: Long = 0, val projectionHint: String = "", val transport: String = "file", val pageLayout: String = "", val sourcePreference: Double = 0.0,
    val browserHeaders: WebVideoRequestHeaders? = null,
) {
    val headers: Map<String, String> = java.util.Collections.unmodifiableMap(LinkedHashMap(headers))
    val hasVideo get() = videoCodec.isNotBlank() && videoCodec != "none"
    val hasAudio get() = audioCodec.isNotBlank() && audioCodec != "none"
    init {
        require(transport in setOf("file", "hls"))
        require(url.scheme in setOf("http", "https") && !url.host.isNullOrBlank() && url.rawUserInfo == null && url.fragment == null) { "Invalid media address" }
        require(formatId.length in 1..256 && extension in setOf("mp4", "m4a", "webm", "mkv", "mov")) { "Unsupported media format" }
        require(width in 0..16384 && height in 0..16384 && fps.isFinite() && fps in 0.0..240.0 && bitrate.isFinite()) { "Invalid media dimensions" }
        require(chunkBytes in 0..(64L * 1024 * 1024)) { "Invalid media range size" }
        require(headers.size <= 32 && headers.all { (k, v) ->
            k.matches(Regex("[A-Za-z0-9-]{1,128}")) && v.length <= 8192 && v.none { it < ' ' || it == '\u007f' } &&
                k.lowercase(Locale.ROOT) !in setOf("host", "range", "content-length", "connection", "transfer-encoding")
        }) { "Invalid media headers" }
    }
    override fun toString() = "WebVideoTrack(format=$formatId, ${width}x$height)"
}

internal class WebVideoDescriptor(val page: WebVideoPage, val title: String, val video: WebVideoTrack,
    val audio: WebVideoTrack?, val durationSeconds: Double, val resolvedAtMs: Long = System.currentTimeMillis(),
    val projection: JSONObject? = null, val silent: Boolean = false) {
    init {
        require(video.hasVideo && (video.hasAudio || audio?.hasAudio == true || silent)) { "Video or audio stream missing" }
        require(audio == null || !audio.hasVideo) { "Invalid separate audio track" }
        require(title.length <= 1024 && durationSeconds.isFinite() && durationSeconds >= 0) { "Invalid video metadata" }
    }
    fun publicJson(): JSONObject = JSONObject().put("uri", page.url).put("site", page.site).put("media_id", page.id)
        .put("title", title).put("duration", durationSeconds).put("width", video.width).put("height", video.height)
        .put("fps", video.fps).put("codec", video.videoCodec).put("separate_audio", audio != null).put("silent", silent)
        .put("projection", projection?.optString("kind") ?: "flat")
        .put("geometry", projection?.optInt("geometry") ?: 0).put("stereo_mode", projection?.optInt("stereo_mode") ?: 0)
    override fun toString() = "WebVideoDescriptor(${page.site}, ${video.width}x${video.height})"
}

/** Discovery and selection; file and HLS transports have separate lease implementations. */
internal object WebVideoFormats {
    private fun cdnPreference(track: WebVideoTrack): Int {
        val host = track.url.host.lowercase(Locale.ROOT)
        // Bilibili supplies UPOS backups for peer/CDN nodes that may ignore Range.
        return if (host.startsWith("upos-") && host.endsWith(".bilivideo.com")) 1 else 0
    }
    fun select(page: WebVideoPage, json: JSONObject, accepts: (WebVideoTrack) -> Boolean): WebVideoDescriptor {
        require(!json.optBoolean("is_live") && json.optString("live_status") !in setOf("is_live", "is_upcoming")) { "Live playback is not available yet" }
        require(!json.optBoolean("has_drm")) { "Protected video cannot be handed off" }
        val list = json.optJSONArray("formats") ?: error("Video formats unavailable")
        require(list.length() <= 4096) { "Too many video formats" }
        val common = json.optJSONObject("http_headers")
        val tracks = (0 until list.length()).mapNotNull { list.optJSONObject(it) }.mapNotNull { format ->
            runCatching { track(format, common) }.getOrNull()
        }
        val audio = tracks.filter { !it.hasVideo && it.hasAudio }.maxWithOrNull(compareBy<WebVideoTrack> { it.bitrate }.thenBy { cdnPreference(it) }.thenBy { it.formatId })
        // Instagram's progressive acodec=none comes from the site's explicit has_audio=false.
        // Do not infer silence just because a split-track site's audio disappeared.
        val silent = page.site == "instagram" && list.length() > 0 &&
            (0 until list.length()).all { list.optJSONObject(it)?.optString("acodec") == "none" } &&
            tracks.any { it.hasVideo && it.transport == "file" && it.formatId.all(Char::isDigit) }
        val video = tracks.filter { it.hasVideo && accepts(it) && (it.hasAudio || audio != null || silent) }
            .maxWithOrNull(compareBy<WebVideoTrack> { it.projectionHint.isNotEmpty() }.thenBy { it.height.toLong() * it.width }.thenBy { it.fps }.thenBy { it.bitrate }.thenBy { cdnPreference(it) }.thenBy { it.sourcePreference })
            ?: error("No compatible video stream")
        return WebVideoDescriptor(page, json.optString("title", page.id).take(1024), video, if (video.hasAudio) null else audio,
            json.optDouble("duration", 0.0).let { if (it.isFinite() && it > 0) it else 0.0 }, silent = silent)
    }
    private fun track(f: JSONObject, common: JSONObject?): WebVideoTrack {
        val hls = f.optString("protocol") in setOf("m3u8", "m3u8_native")
        require(!f.optBoolean("has_drm") && (hls || f.optString("protocol") in setOf("http", "https")))
        // Android JSONObject coerces the explicit NULL sentinel to the string "null".
        // yt-dlp emits dynamic_range:null for audio; dropping it discards all split video.
        require((if (f.isNull("dynamic_range")) "sdr" else f.optString("dynamic_range").lowercase(Locale.ROOT)) in setOf("", "sdr"))
        require(hls || (f.isNull("fragments") && f.isNull("manifest_url")))
        val headers = LinkedHashMap<String, String>()
        // Format-specific headers override defaults, case insensitively.
        for (source in listOfNotNull(common, f.optJSONObject("http_headers"))) for (key in source.keys())
            headers[key.lowercase(Locale.ROOT)] = source.getString(key)
        return WebVideoTrack(f.getString("format_id"), URI(f.getString("url")), headers, f.optString("ext"),
            if (f.isNull("vcodec")) "unknown" else f.optString("vcodec", "unknown").lowercase(Locale.ROOT),
            if (f.isNull("acodec")) "unknown" else f.optString("acodec", "unknown").lowercase(Locale.ROOT), f.optInt("width"), f.optInt("height"),
            f.optDouble("fps", 0.0), f.optDouble("tbr", f.optDouble("abr", 0.0)),
            f.optJSONObject("downloader_options")?.optLong("http_chunk_size", 0) ?: 0,
            f.optString("format_note").lowercase(Locale.ROOT).let { note ->
                when { Regex("\\bmesh\\b").containsMatchIn(note) -> "mesh"; "equirectangular" in note -> "equirectangular"; else -> "" }
            }, if (hls) "hls" else "file", f.optString("web_layout"), f.optDouble("quality", 0.0).takeIf { it.isFinite() } ?: 0.0,
            WebVideoRequestHeaders.parse(f))
    }
}
