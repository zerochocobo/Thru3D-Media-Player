package org.vrpassthroughplayer.plugin

import org.json.JSONArray
import org.json.JSONObject
import org.junit.Assert.*
import org.junit.Test

class WebVideoBilibiliCaptureTest {
    @Test fun automaticQualityUsesObservedRepresentationAndAvidMustMatchPage() {
        val media = fixture(); val data = media.getJSONObject("bilibili")
        data.put("quality", 120).put("avid", "1").put("aid", "1")
        assertNotNull(WebVideoBilibiliCapture.formats(page, media))
        val diagnostic = WebVideoBilibiliCapture.diagnostics(media)
        assertEquals(1, diagnostic.getJSONObject("video").getInt("exact_matches"))
        assertFalse(diagnostic.toString().contains("synthetic"))
        data.put("aid", "2")
        assertNull(WebVideoBilibiliCapture.formats(page, media))
    }
    private val page = WebVideoPage.parse("https://www.bilibili.com/video/BV1234567890/")
    private fun url(id: Int, cid: String = "12345") = "https://upos-test.bilivideo.com/upgcxcode/$cid-$id.m4s?token=synthetic"
    private fun fixture(): JSONObject {
        fun track(id: Int, video: Boolean) = JSONObject().put("id", id).put("urls", JSONArray().put(url(id)))
            .put("codec", if (video) "avc1.640028" else "mp4a.40.2").put("width", if (video) 1920 else 0)
            .put("height", if (video) 1080 else 0).put("fps", if (video) 30 else 0)
        fun request(id: Int) = JSONObject().put("url", url(id)).put("kind", "file").put("at", 1000)
            .put("headers", JSONObject().put("referer", page.url).put("cookie", "exact=synthetic"))
        return JSONObject().put("bilibili_enabled", true).put("frame", page.url).put("duration", 120)
            .put("width", 1920).put("height", 1080).put("title", "Fixture")
            .put("network", JSONArray().put(request(80)).put(request(30280)))
            .put("bilibili", JSONObject().put("id", "BV1234567890").put("part", 1).put("cid", "12345")
                .put("page", page.url).put("duration", 120).put("expected_duration", 120).put("quality", 80)
                .put("video", JSONArray().put(track(80, true))).put("audio", JSONArray().put(track(30280, false))))
    }
    @Test fun fullPairUsesExistingSelectorWithoutExtractorAndCredentialsStayPrivate() {
        val media = fixture()
        val (_, descriptor) = WebVideoResolution.select(page, { WebVideoBilibiliCapture.formats(page, media) },
            { error("Extractor must not start") }, { true }, {})
        assertEquals(1080, descriptor.video.height); assertNotNull(descriptor.audio)
        assertEquals("exact=synthetic", descriptor.video.headers["cookie"])
        assertFalse(descriptor.publicJson().toString().contains("synthetic"))
        assertFalse(descriptor.toString().contains("token"))
        val headers = descriptor.video.browserHeaders!!
        assertFalse(headers.forUrl(java.net.URI("https://other.bilivideo.com/12345-80.m4s"), descriptor.video.headers).containsKey("cookie"))
    }
    @Test fun advertisedButUnrequestedBackupDoesNotQualify() {
        val media = fixture(); media.getJSONArray("network").remove(1)
        assertNull(WebVideoBilibiliCapture.formats(page, media))
    }
    @Test fun decoratedAudioFilenameUsesVerifiedCidDirectoryAndExactObservedUrl() {
        val media = fixture()
        val url = "https://upos-test.bilivideo.com/upgcxcode/45/23/12345/12345_nb3-1-30280.m4s?token=synthetic"
        media.getJSONObject("bilibili").getJSONArray("audio").getJSONObject(0).put("urls", JSONArray().put(url))
        media.getJSONArray("network").getJSONObject(1).put("url", url)
        assertNotNull(WebVideoBilibiliCapture.formats(page, media))
        assertNull(WebVideoNetworkCapture.group(java.net.URI(url.replace("/12345/", "/999/").replace("12345_nb3", "12345"))))
        media.getJSONArray("network").getJSONObject(1).put("url", url.replace("/12345/", "/999/"))
        assertNull(WebVideoBilibiliCapture.formats(page, media))
    }
    @Test fun partAndCidMustMatchBothPageAndObservedPair() {
        val media = fixture()
        assertNull(WebVideoBilibiliCapture.formats(WebVideoPage.parse(page.url + "?p=2"), media))
        media.getJSONObject("bilibili").put("cid", "99999")
        assertNull(WebVideoBilibiliCapture.formats(page, media))
    }
    @Test fun previewAndUnknownFullDurationCannotMasqueradeAsFullVideo() {
        for (expected in listOf(0, 300)) {
            val media = fixture(); media.getJSONObject("bilibili").put("expected_duration", expected)
            assertNull(WebVideoBilibiliCapture.formats(page, media))
        }
    }
    @Test fun dimensionsMustEqualCurrentWebpageRatherThanMerelyExceedingThem() {
        for (height in listOf(720, 2160)) {
            val media = fixture(); media.put("height", height)
            assertNull(WebVideoBilibiliCapture.formats(page, media))
        }
    }
    @Test fun encryptedDisabledAndCorruptPayloadsRemainInBrowser() {
        assertNull(WebVideoBilibiliCapture.formats(page, fixture().put("protected", true)))
        assertNull(WebVideoBilibiliCapture.formats(page, fixture().put("bilibili_enabled", false)))
        assertNull(WebVideoBilibiliCapture.formats(page, fixture().put("bilibili", "invalid")))
    }
    @Test fun latestObservedCodecWinsWithoutUpgradingQuality() {
        val media = fixture(); val data = media.getJSONObject("bilibili")
        val second = JSONObject(data.getJSONArray("video").getJSONObject(0).toString())
            .put("urls", JSONArray().put(url(81))).put("codec", "hev1.1.6.L120.90")
        data.getJSONArray("video").put(second)
        val request = JSONObject(media.getJSONArray("network").getJSONObject(0).toString()).put("url", url(81)).put("at", 2000)
        media.getJSONArray("network").put(request)
        val descriptor = WebVideoFormats.select(page, WebVideoBilibiliCapture.formats(page, media)!!, { true })
        assertEquals(url(81), descriptor.video.url.toString())
    }

    @Test fun newCdnAndPortNeedExactApiAndObservedUrlRatherThanAHostAllowlist() {
        for (port in listOf(443, 4483, 8082, 19443, 65535)) {
            val media = fixture()
            for ((index, key) in listOf("video", "audio").withIndex()) {
                val url = "https://new-cdn.example:$port/opaque/$key.m4s?token=synthetic"
                media.getJSONObject("bilibili").getJSONArray(key).getJSONObject(0).put("urls", JSONArray().put(url))
                media.getJSONArray("network").getJSONObject(index).put("url", url)
            }
            val formats = WebVideoBilibiliCapture.formats(page, media)
            assertNotNull(formats)
            val descriptor = WebVideoFormats.select(page, formats!!, { true })
            assertEquals(port, descriptor.video.url.port)
            assertFalse(descriptor.video.browserHeaders!!.forUrl(java.net.URI("https://unobserved.example:$port/opaque/video.m4s"), emptyMap()).containsKey("cookie"))
            media.getJSONArray("network").getJSONObject(0).put("url", "https://unobserved.example:$port/opaque/video.m4s?token=synthetic")
            assertNull(WebVideoBilibiliCapture.formats(page, media))
        }
    }
    @Test fun pgcSeasonResolvesOnlyBoundWholeEpisodeAndNeverTheSeasonPlaylist() {
        val media = fixture()
        val source = WebVideoPage.parse("https://www.bilibili.com/bangumi/play/ss456?tracking=removed")
        val episode = WebVideoPage.parse("https://www.bilibili.com/bangumi/play/ep123")
        media.put("frame", source.url)
        val data = media.getJSONObject("bilibili").put("page", source.url).put("id", "ss456")
            .put("pgc", true).put("whole", true).put("ep", "123").put("season", "456")
        assertEquals(episode, WebVideoBilibiliCapture.episodePage(source, media))
        assertNotNull(WebVideoBilibiliCapture.formats(episode, media))
        assertNull(WebVideoBilibiliCapture.formats(source, media))
        data.put("whole", false)
        assertNull(WebVideoBilibiliCapture.episodePage(source, media))
        data.put("whole", true).put("season", "457")
        assertNull(WebVideoBilibiliCapture.episodePage(source, media))
    }
}
