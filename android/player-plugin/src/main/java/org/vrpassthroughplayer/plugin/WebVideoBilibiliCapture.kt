package org.vrpassthroughplayer.plugin

import org.json.JSONArray
import org.json.JSONObject
import java.net.URI
import kotlin.math.abs

/** Accept only a full UGC part or whole PGC episode and the pair actually requested by Gecko.
 * API URLs confer no authority to copy webpage cookies onto a CDN or a backup URL. */
internal object WebVideoBilibiliCapture {
    /** Resolve a season landing page to the episode selected by the page, never a playlist. */
    fun episodePage(page: WebVideoPage, media: JSONObject?): WebVideoPage? = runCatching {
        require(page.site == "bilibili" && page.id.matches(Regex("(?:ep|ss)[1-9][0-9]{0,19}:1")))
        require(media != null && !media.optBoolean("protected") && media.optBoolean("bilibili_enabled"))
        val data = media.getJSONObject("bilibili")
        require(data.optBoolean("pgc") && data.optBoolean("whole"))
        require(data.getString("page") == media.getString("frame") && WebVideoPage.parse(data.getString("page")) == page)
        require("${data.getString("id")}:1" == page.id)
        val ep = data.getString("ep"); val season = data.getString("season")
        require(ep.matches(Regex("[1-9][0-9]{0,19}")) && season.matches(Regex("[1-9][0-9]{0,19}")))
        require(page.id == (if (page.id.startsWith("ep")) "ep$ep:1" else "ss$season:1"))
        val duration = data.getDouble("duration")
        require(duration.isFinite() && duration > 0 && abs(duration - media.getDouble("duration")) <= maxOf(2.0, duration * .01))
        WebVideoPage.parse("https://www.bilibili.com/bangumi/play/ep$ep")
    }.getOrNull()

    /** Numeric diagnostics only: never expose URLs, headers, cookies or content identifiers. */
    fun diagnostics(media: JSONObject): JSONObject = runCatching {
        val data = media.optJSONObject("bilibili") ?: return JSONObject()
        val candidates = WebBrowserNetworkMedia.candidates(media)
        val all = (0 until candidates.length()).map { candidates.getJSONObject(it) }
        val declared = listOf("video", "audio").flatMap { key ->
            val tracks = data.optJSONArray(key) ?: JSONArray()
            (0 until tracks.length()).flatMap { i ->
                val urls = tracks.getJSONObject(i).getJSONArray("urls")
                (0 until urls.length()).map { urls.getString(it) }
            }
        }.toSet()
        val observed = all.filter { it.optString("kind") == "file" && it.optString("url") in declared }
        val result = JSONObject().put("observed", all.size).put("current_part_observed", observed.size)
            .put("api_quality", data.optInt("quality"))
        for (key in listOf("video", "audio")) {
            val tracks = data.optJSONArray(key) ?: JSONArray()
            var exact = 0; var path = 0; var dimensions = 0
            for (i in 0 until tracks.length()) {
                val track = tracks.getJSONObject(i)
                if (track.optInt("width") == media.optInt("width") && track.optInt("height") == media.optInt("height")) dimensions++
                val urls = track.getJSONArray("urls")
                val allowed = (0 until urls.length()).map { URI(urls.getString(it)) }
                for (request in observed) {
                    val uri = URI(request.getString("url"))
                    if (allowed.any { it.toString() == uri.toString() }) exact++
                    if (allowed.any { it.scheme == uri.scheme && it.rawAuthority == uri.rawAuthority && it.rawPath == uri.rawPath }) path++
                }
            }
            result.put(key, JSONObject().put("representations", tracks.length()).put("exact_matches", exact)
                .put("path_matches", path).put("dimension_matches", dimensions))
        }
        result
    }.getOrDefault(JSONObject())

    fun formats(page: WebVideoPage, media: JSONObject): JSONObject? = runCatching {
        require(page.site == "bilibili" && media.optBoolean("bilibili_enabled") && !media.optBoolean("protected"))
        val data = media.getJSONObject("bilibili")
        require(data.toString().length <= 96 * 1024)
        val sourcePage = WebVideoPage.parse(data.getString("page"))
        require(data.getString("page") == media.getString("frame"))
        require("${data.getString("id")}:${data.getInt("part")}" == sourcePage.id)
        if (sourcePage.id.startsWith("ep") || sourcePage.id.startsWith("ss")) require(episodePage(sourcePage, media) == page)
        else require(sourcePage == page && !data.optBoolean("pgc"))
        require(!data.has("avid") || data.optString("avid") == data.optString("aid"))
        val cid = data.getString("cid"); require(cid.matches(Regex("[1-9][0-9]{0,19}")))
        val duration = data.getDouble("duration")
        require(duration.isFinite() && duration > 0 && duration <= 86400)
        for (expected in listOf(data.getDouble("expected_duration"), media.getDouble("duration")))
            require(expected.isFinite() && expected > 0 && abs(duration - expected) <= maxOf(2.0, duration * .01))
        val quality = data.getInt("quality"); require(quality > 0 && quality !in setOf(125, 126))
        val candidates = WebBrowserNetworkMedia.candidates(media)
        val observed = (0 until candidates.length()).map { candidates.getJSONObject(it) }
            .filter { it.optString("kind") == "file" &&
                WebVideoNetworkCapture.group(URI(it.getString("url"))).let { group -> group == null || group == "bilibili:$cid" } }
        fun track(key: String, video: Boolean): JSONObject {
            val tracks = data.getJSONArray(key); require(tracks.length() in 1..64)
            val matches = (0 until tracks.length()).flatMap { index ->
                val t = tracks.getJSONObject(index)
                val urls = t.getJSONArray("urls"); require(urls.length() in 1..9)
                val allowed = (0 until urls.length()).map { urls.getString(it) }.toSet()
                observed.filter { it.getString("url") in allowed }.map { t to it }
            }
            // The most recently requested representation wins, not the highest advertised one.
            val (t, request) = matches.maxByOrNull { it.second.optLong("at") } ?: error("Track not observed")
            val uri = URI(request.getString("url"))
            require(uri.scheme == "https" && (uri.port == -1 || uri.port in 1..65535))
            val codec = t.getString("codec")
            require(codec.length <= 100 && (if (video) Regex("(avc1|hev1|hvc1|av01)\\..+") else Regex("mp4a\\..+")).matches(codec))
            val id = t.getInt("id"); require(id > 0 && (!video || id !in setOf(125, 126)))
            val width = t.getInt("width"); val height = t.getInt("height"); val fps = t.getDouble("fps")
            if (video) {
                require(width in 1..8192 && height in 1..8192 && fps.isFinite() && fps > 0 && fps <= 240)
                require(media.optInt("width") == width && media.optInt("height") == height)
            }
            val headers = request.getJSONObject("headers")
            return JSONObject().put("format_id", "bilibili-$cid-$id-$codec").put("url", uri.toString())
                .put("protocol", "https").put("ext", if (video) "mp4" else "m4a")
                .put("vcodec", if (video) codec else "none").put("acodec", if (video) "none" else codec)
                .put("width", if (video) width else 0).put("height", if (video) height else 0).put("fps", if (video) fps else 0)
                .put("http_headers", headers).put("browser_headers", JSONObject().put(uri.toString(), headers))
                .put("browser_cookies", request.optJSONArray("cookies") ?: JSONArray())
        }
        JSONObject().put("title", media.optString("title").take(1024)).put("duration", duration)
            .put("formats", JSONArray().put(track("video", true)).put(track("audio", false)))
    }.getOrNull()
}
