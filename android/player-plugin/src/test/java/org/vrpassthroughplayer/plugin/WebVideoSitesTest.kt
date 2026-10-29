package org.vrpassthroughplayer.plugin

import org.json.JSONObject
import org.junit.Assert.*
import org.junit.Test

class WebVideoSitesTest {
    @Test fun serverPlaybackKeepsVersionAndCredentialsPrivate() {
        for ((base, id) in listOf("http://192.168.1.20:8096" to "21", "https://example.test/jellyfin" to "a123bc")) {
            val frame = "$base/web/index.html#!/videoosd?api_key=page-secret"
            val tokenName = if (base.contains("jellyfin")) "ApiKey" else "api_key"
            val media = JSONObject().put("server", true).put("frame", frame)
                .put("source", "$base/Videos/$id/master.m3u8?MediaSourceId=version_2&$tokenName=test-secret&StartTimeTicks=450000000&VideoCodec=h264")
            val page = WebVideoBrowserCapture.serverPage(frame, media)!!
            val result = WebVideoFormats.select(page, WebVideoBrowserCapture.formats(media)!!) { true }
            assertEquals("media_server", page.site)
            assertEquals("file", result.video.transport)
            assertTrue(result.video.url.path.endsWith("/Videos/$id/stream"))
            assertTrue(result.video.url.rawQuery.contains("Static=true&MediaSourceId=version_2"))
            assertFalse(result.video.url.rawQuery.contains("StartTimeTicks"))
            assertTrue(result.video.url.rawQuery.contains("$tokenName=test-secret"))
            assertFalse(result.publicJson().toString().contains("secret"))
            assertTrue(page.url.contains("MediaSourceId=version_2"))
            assertNull(WebVideoBrowserCapture.serverPage(frame, JSONObject(media.toString()).put("protected", true)))
            assertNull(WebVideoBrowserCapture.serverPage(frame, JSONObject(media.toString()).put("server", false)))
            for (source in listOf("http://another.test/Videos/$id/stream?api_key=x&MediaSourceId=y", "$base/Videos/$id/stream?MediaSourceId=y",
                "$base/Videos/$id/stream?api_key=x&MediaSourceId=y&LiveStreamId=live", "$base/Videos/$id/hls/1.ts?api_key=x&MediaSourceId=y")) {
                assertNull(WebVideoBrowserCapture.serverPage(frame, JSONObject(media.toString()).put("source", source)))
            }
        }
    }
    @Test fun mediaAccessFailureKeepsItsCauseDuringProjectionInspection() {
        for (status in listOf(401, 403)) {
            assertEquals("site_rejected", WebVideoResolver.failureCode(MediaServerFailure("denied", status), "projection"))
        }
        assertEquals("video_unavailable", WebVideoResolver.failureCode(MediaServerFailure("missing", 404), "projection"))
        assertEquals("network_failed", WebVideoResolver.failureCode(MediaServerFailure("transport", transportError = "SSLException"), "projection"))
        assertEquals("projection_unavailable", WebVideoResolver.failureCode(IllegalArgumentException("Invalid projection"), "projection"))
        assertEquals("no_supported_stream", WebVideoResolver.failureCode(IllegalArgumentException("No format"), "selection"))
    }

    @Test fun subscriptionPagesStayInTheWebsitePlayer() {
        for (url in listOf("https://www.netflix.com/watch/80057281", "https://www.disneyplus.com/video/example",
            "https://www.primevideo.com/detail/example", "https://play.max.com/video/watch/example",
            "https://www.hulu.com/watch/example", "https://www.paramountplus.com/shows/video/example/",
            "https://tv.apple.com/us/movie/example/umc.cmc.example")) {
            assertThrows(url, Exception::class.java) { WebVideoPage.parse(url) }
        }
    }
    @Test fun siteCodecAndSdrCaseDoNotDiscardPlayableFormats() {
        val item = JSONObject().put("format_id", "sample").put("url", "https://cdn.test/video.mp4")
            .put("protocol", "https").put("ext", "mp4").put("vcodec", "H264").put("acodec", "AAC").put("dynamic_range", "sdr")
        val info = JSONObject().put("formats", org.json.JSONArray().put(item))
        val page = WebVideoPage.parse("https://v.qq.com/x/page/q326831cny0.html")
        assertEquals("h264", WebVideoFormats.select(page, info) { true }.video.videoCodec)
        item.put("dynamic_range", "hdr10")
        assertThrows(Exception::class.java) { WebVideoFormats.select(page, info) { true } }
    }
    @Test fun declaredLayoutsDoNotConflateEquirectangularAndFisheye() {
        assertEquals(1, WebVideoPageProjection.parse("STEREO_180_LR")!!.getInt("geometry"))
        assertEquals(2, WebVideoPageProjection.parse("STEREO_180_LR")!!.getInt("stereo_mode"))
        assertEquals(1, WebVideoPageProjection.parse("STEREO_360_TB")!!.getInt("stereo_mode"))
        assertEquals(3, WebVideoPageProjection.parse("MONO_360")!!.getInt("geometry"))
        assertNull(WebVideoPageProjection.parse("STEREO_180_LR_SPHERICAL"))
        assertNull(WebVideoPageProjection.parse("FISHEYE"))
        val formats = org.json.JSONArray()
        for (quality in listOf(-2, -1, 0)) formats.put(JSONObject().put("format_id", "source$quality")
            .put("url", "https://cdn.test/video.mp4").put("ext", "mp4").put("protocol", "https")
            .put("quality", quality).put("web_layout", "STEREO_180_LR"))
        val result = WebVideoFormats.select(WebVideoPage.parse("https://www.youtube.com/watch?v=jNQXAC9IVRw"), JSONObject().put("formats", formats)) { true }
        assertEquals("source0", result.video.formatId)
        assertEquals("STEREO_180_LR", result.video.pageLayout)
        assertEquals(0, result.video.width)
    }
    @Test fun capturedCookiesRespectDomainHostPathAndSecureScope() {
        val cookies = org.json.JSONArray().put(JSONObject().put("domain", ".weibo.com").put("name", "session").put("value", "synthetic").put("path", "/video").put("secure", true))
        assertEquals("session=synthetic", WebVideoBrowserCapture.cookieHeader(cookies, java.net.URI("https://video.weibo.com/video/1")))
        for (url in listOf("http://video.weibo.com/video/1", "https://weibo.com/videography", "https://weibo.com.evil/video/1", "https://cdn.test/video/1"))
            assertNull(WebVideoBrowserCapture.cookieHeader(cookies, java.net.URI(url)))
        cookies.getJSONObject(0).put("hostOnly", true).put("domain", "weibo.com")
        assertNull(WebVideoBrowserCapture.cookieHeader(cookies, java.net.URI("https://video.weibo.com/video/1")))
    }
    @Test fun videoPagesKeepIdentityAndDropTracking() {
        val examples = mapOf(
            "https://m.weibo.cn/status/4189191225395228?token=private" to "https://m.weibo.cn/detail/4189191225395228",
            "https://weibo.com/7827771738/N4xlMvjhI?from=private" to "https://weibo.com/7827771738/N4xlMvjhI",
            "https://video.weibo.com/show?fid=1034%3A4967272104787984&token=private" to "https://weibo.com/tv/show/1034:4967272104787984",
            "https://m.iqiyi.com/v_19rrojlavg.html?token=private" to "https://www.iqiyi.com/v_19rrojlavg.html",
            "https://w.mgtv.com/b/427837/15588271.html?token=private" to "https://www.mgtv.com/b/427837/15588271.html",
            "https://www.mgtv.com/s/15588271.html?token=private" to "https://www.mgtv.com/b/15588271.html",
            "https://m.v.qq.com/x/cover/7ce5noezvafma27/a00269ix3l8.html?token=private" to "https://v.qq.com/x/cover/7ce5noezvafma27/a00269ix3l8.html",
            "https://v.youku.com/v_show/id_XOTUxMzg4NDMy.html?token=private" to "https://v.youku.com/v_show/id_XOTUxMzg4NDMy.html",
            "https://player.vimeo.com/video/76979871?autoplay=1" to "https://vimeo.com/76979871",
            "https://dai.ly/x123abc?token=private" to "https://www.dailymotion.com/video/x123abc",
            "https://tubitv.com/movies/123456/title?token=private" to "https://tubitv.com/movies/123456",
            "https://www.twitch.tv/videos/123456?token=private" to "https://www.twitch.tv/videos/123456"
        )
        examples.forEach { (input, expected) -> assertEquals(input, expected, WebVideoPage.parse(input).url) }
        for (bad in listOf("https://douyin.com.evil/video/6961737553342991651", "https://weibo.com/u/12345",
            "https://user:secret@weibo.com/1/2", "https://www.mgtv.com/", "https://vimeo.com/76979871?h=secret",
            "https://www.douyin.com/video/6961737553342991651", "https://v.douyin.com/AbCdEfG/", "https://www.iqiyi.com/a_album.html", "https://v.qq.com/x/cover/series.html"))
            assertThrows(bad, Exception::class.java) { WebVideoPage.parse(bad) }
    }

    @Test fun capturedMediaDoesNotExportCredentialsOrAcceptDrmAndBlob() {
        val captured = JSONObject().put("source", "https://cdn.test/movie.mp4?signature=private")
            .put("frame", "https://weibo.com/7827771738/N4xlMvjhI")
            .put("agent", "Synthetic browser").put("width", 1080).put("height", 1920).put("duration", 12.5)
        val info = WebVideoBrowserCapture.formats(captured)!!
        val result = WebVideoFormats.select(WebVideoPage.parse(captured.getString("frame")), info) { true }
        assertEquals("unknown", result.video.videoCodec)
        assertFalse(result.publicJson().toString().contains("signature"))
        assertEquals("Synthetic browser", result.video.headers["user-agent"])
        assertNull(WebVideoBrowserCapture.formats(JSONObject(captured.toString()).put("protected", true)))
        assertNull(WebVideoBrowserCapture.formats(JSONObject(captured.toString()).put("source", "blob:private")))
        assertNull(WebVideoBrowserCapture.formats(JSONObject(captured.toString()).put("source", "file:///private")))
    }
}
