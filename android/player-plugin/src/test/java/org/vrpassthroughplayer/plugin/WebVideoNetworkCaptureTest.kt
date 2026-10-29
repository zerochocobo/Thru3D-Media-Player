package org.vrpassthroughplayer.plugin

import org.json.JSONArray
import org.json.JSONObject
import org.junit.Assert.*
import org.junit.Test
import java.net.URI
import java.nio.ByteBuffer

class WebVideoNetworkCaptureTest {
    private val page = WebVideoPage("browser", "fixture", "webvideo://capture/fixture")
    private fun box(type: String, data: ByteArray) = ByteBuffer.allocate(8 + data.size).putInt(data.size + 8).put(type.toByteArray()).put(data).array()
    private fun mp4(video: Boolean = true, audio: Boolean = true, duration: Int = 10, protected: Boolean = false, width: Int = 1920, height: Int = 1080): ByteArray {
        fun track(kind: String): ByteArray {
            val video = kind == "vide"
            val sample = if (video) ByteArray(78).also { ByteBuffer.wrap(it).putShort(24, width.toShort()).putShort(26, height.toShort()) } + box("avcC", byteArrayOf(1, 100, 0, 40)) else ByteArray(28)
            val stsd = box("stsd", ByteBuffer.allocate(8).putInt(0).putInt(1).array() + box(if (protected) if (video) "encv" else "enca" else if (video) "avc1" else "mp4a", sample))
            val mdhd = ByteBuffer.allocate(24).putInt(12, 1000).putInt(16, duration * 1000).array()
            val hdlr = ByteArray(24).also { kind.toByteArray().copyInto(it, 8) }
            return box("trak", box("mdia", box("mdhd", mdhd) + box("hdlr", hdlr) + box("minf", box("stbl", stsd))))
        }
        return box("ftyp", "isom0000isom".toByteArray()) + box("moov", (if (video) track("vide") else byteArrayOf()) + (if (audio) track("soun") else byteArrayOf())) + box("mdat", ByteArray(16))
    }
    private fun candidate(url: String, kind: String = "file", headers: JSONObject = JSONObject(), cookies: JSONArray = JSONArray()) =
        JSONObject().put("url", url).put("kind", kind).put("headers", headers).put("cookies", cookies)
    private fun media(vararg items: JSONObject, direct: String = "") = JSONObject().put("frame", "https://page.test/watch")
        .put("source", direct).put("duration", 10).put("width", 1920).put("height", 1080).put("title", "Fixture")
        .put("network", JSONArray(items.toList())).put("id", "1").put("network_epoch", 1).put("network_enabled", true)
    private fun resolver(data: Map<String, ByteArray>, observed: MutableList<Pair<URI, Map<String, String>>> = arrayListOf()) = WebVideoNetworkCapture({ uri, headers, _ ->
        observed.add(uri to headers); uri to (data[uri.toString()] ?: error("Unexpected request"))
    }, { it.height <= 1080 })

    @Test fun verifiedMuxedFileUsesActualHeadersAndBypassesExtractorAndCookieExport() {
        val url = "https://cdn.test/movie?token=private"
        val observed = arrayListOf<Pair<URI, Map<String, String>>>()
        val capture = resolver(mapOf(url to mp4()), observed)
        var extractions = 0
        val (_, d) = WebVideoResolution.select(page, { capture.resolve(page, media(candidate(url, headers = JSONObject().put("Cookie", "session=synthetic").put("Range", "bytes=99-100")))) },
            { extractions++; error("Extractor must stay cold") }, { true })
        assertEquals(0, extractions); assertEquals("avc1.640028", d.video.videoCodec); assertTrue(d.video.hasAudio)
        assertEquals("session=synthetic", observed.single().second["cookie"]); assertFalse(observed.single().second.containsKey("range"))
        assertFalse(d.publicJson().toString().contains("private")); assertFalse(d.toString().contains("cdn.test"))
    }
    @Test fun incompleteOrUnsupportedCaptureFallsBackExactlyOnceAndCancellationDoesNotExtract() {
        var extracts = 0
        val url = "https://cdn.test/movie.mp4"; val m = media(candidate(url))
        val fallback = WebVideoBrowserCapture.formats(media(direct = url))!!
        for (capture in listOf<() -> JSONObject?>({ null }, { error("invalid container") }, { JSONObject().put("formats", JSONArray()) })) {
            WebVideoResolution.select(page, capture, { extracts++; fallback }, { true })
        }
        assertEquals(3, extracts)
        assertThrows(Exception::class.java) { WebVideoResolution.select(page, { null }, { extracts++; fallback }, { true }, { error("cancelled") }) }
        assertEquals(3, extracts)
        assertNull(resolver(mapOf(url to mp4(duration = 0))).resolve(page, m))
        assertNull(resolver(mapOf(url to mp4(protected = true))).resolve(page, m))
        assertNull(resolver(mapOf(url to mp4())).resolve(page, JSONObject(m.toString()).put("protected", true)))
    }
    @Test fun observedMemberQualityIsNotReplacedByAnExtractorPreviewOrTheOld1080Cap() {
        val url = "https://cdn.test/member.mp4?token=synthetic"
        val m = media(candidate(url, headers = JSONObject().put("Authorization", "Bearer member"))).put("width", 3840).put("height", 2160)
        var extracted = false
        val capture = WebVideoNetworkCapture({ uri, headers, _ ->
            assertEquals("Bearer member", headers["authorization"]); uri to mp4(width = 3840, height = 2160)
        }, { it.height <= 2160 })
        val (_, descriptor) = WebVideoResolution.select(page, { capture.resolve(page, m) }, { extracted = true; error("Public preview must not replace member quality") }, { it.height <= 2160 })
        assertFalse(extracted); assertEquals(3840, descriptor.video.width); assertEquals(2160, descriptor.video.height)
        assertTrue(WebVideoNetworkCapture.keepsQuality(descriptor.video, m))
        val preview = WebVideoTrack("preview", URI("https://cdn.test/preview.mp4"), emptyMap(), "mp4", "avc1", "mp4a", 1920, 1080, 30.0)
        assertFalse(WebVideoNetworkCapture.keepsQuality(preview, m))
    }
    @Test fun pairsOnlyMatchingCompleteBilibiliRepresentationsAndPreservesPerTrackHeaders() {
        val v = "https://upos-a.bilivideo.com/upgcxcode/12/34/1234/1234-1-100026.m4s?token=video"
        val a = "https://upos-b.bilivideo.com/upgcxcode/12/34/1234/1234-1-30280.m4s?token=audio"
        val m = media(candidate(v, headers = JSONObject().put("Authorization", "video")), candidate(a, headers = JSONObject().put("Authorization", "audio")))
        val data = mapOf(v to mp4(audio = false), a to mp4(video = false))
        val d = WebVideoFormats.select(page, resolver(data).resolve(page, m)!!) { true }
        assertEquals("video", d.video.headers["authorization"]); assertEquals("audio", d.audio!!.headers["authorization"])
        val other = a.replace("1234-1-", "9999-1-")
        assertNull(resolver(mapOf(v to mp4(audio = false), other to mp4(video = false))).resolve(page, media(candidate(v), candidate(other))))
        assertNull(resolver(mapOf(v to mp4(audio = false), a to mp4(video = false, duration = 30))).resolve(page, m))
    }
    @Test fun rejectsUnrelatedAdsAndDoesNotPairByHostOrTimingAlone() {
        val v = "https://cdn.test/video.mp4"; val a = "https://cdn.test/audio.mp4"
        assertNull(resolver(mapOf(v to mp4(audio = false), a to mp4(video = false))).resolve(page, media(candidate(v), candidate(a))))
        assertNull(resolver(mapOf(v to mp4(), a to mp4())).resolve(page, media(candidate(v), candidate(a))))
        val chosen = resolver(mapOf(v to mp4(), a to mp4())).resolve(page, media(candidate(v), candidate(a), direct = v))!!
        assertEquals(v, chosen.getJSONArray("formats").getJSONObject(0).getString("url"))
    }
    @Test fun youtubeOnlyRemovesUnsignedRangeAndRejectsLiveSequenceRequests() {
        val url = "https://r1.googlevideo.com/videoplayback?id=abcdefgh.1&source=youtube&sparams=id,source,expire&expire=999&range=0-999&sig=opaque"
        assertEquals(url.replace("&range=0-999", ""), WebVideoNetworkCapture.wholeFile(URI(url)).toString())
        assertNull(WebVideoNetworkCapture.wholeFile(URI(url.replace("sparams=id,source,expire", "sparams=id,source,expire,range"))))
        assertNull(WebVideoNetworkCapture.wholeFile(URI(url + "&sq=10")))
        assertNull(WebVideoNetworkCapture.wholeFile(URI(url + "&live=1")))
        val signed = URI("https://cdn.test/file?range=1-20&signature=private")
        assertEquals(signed, WebVideoNetworkCapture.wholeFile(signed))
    }
    @Test fun masterPlaylistSelectsCompatibleVideoWithItsOwnAudioAndDetectsLiveOrDrmBeforeHandoff() {
        val root = "https://cdn.test/master"; val video = "https://cdn.test/video"; val audio = "https://cdn.test/audio"
        val master = "#EXTM3U\n#EXT-X-MEDIA:TYPE=AUDIO,GROUP-ID=\"en\",DEFAULT=YES,URI=\"audio\"\n" +
            "#EXT-X-STREAM-INF:BANDWIDTH=1000000,RESOLUTION=1920x1080,CODECS=\"avc1.640028,mp4a.40.2\",AUDIO=\"en\"\nvideo\n" +
            "#EXT-X-STREAM-INF:BANDWIDTH=5000000,RESOLUTION=3840x2160,CODECS=\"avc1.640033,mp4a.40.2\",AUDIO=\"en\"\nlarge\n"
        val vod = "#EXTM3U\n#EXT-X-TARGETDURATION:10\n#EXTINF:10,\nsegment.ts\n#EXT-X-ENDLIST\n"
        val data = mapOf(root to master.toByteArray(), video to vod.toByteArray(), audio to vod.toByteArray())
        val m = media(candidate(root, "hls"), candidate(video, "hls"), candidate(audio, "hls"))
        val d = WebVideoFormats.select(page, resolver(data).resolve(page, m)!!) { true }
        assertEquals(video, d.video.url.toString()); assertEquals(audio, d.audio!!.url.toString()); assertEquals("hls", d.audio.transport)
        assertNull(resolver(data + (video to vod.replace("#EXT-X-ENDLIST", "").toByteArray())).resolve(page, m))
        assertNull(resolver(data + (video to vod.replace("#EXTINF", "#EXT-X-KEY:METHOD=SAMPLE-AES,URI=\"key\"\n#EXTINF").toByteArray())).resolve(page, m))
    }
    @Test fun extensionlessHlsLeafMustContainBothAudioAndVideo() {
        val root = "https://cdn.test/list"; val init = "https://cdn.test/init.mp4"
        val playlist = "#EXTM3U\n#EXT-X-MAP:URI=\"init.mp4\"\n#EXTINF:10,\nsegment.m4s\n#EXT-X-ENDLIST\n".toByteArray()
        val m = media(candidate(root, "hls"))
        assertNotNull(resolver(mapOf(root to playlist, init to mp4())).resolve(page, m))
        assertNull(resolver(mapOf(root to playlist, init to mp4(audio = false))).resolve(page, m))
    }
    @Test fun staticDashBaseUrlPairsValidatedWholeTracksAndRejectsProtectedOrSegmentedManifests() {
        val url = "https://cdn.test/manifest"
        val xml = """<MPD xmlns="urn:mpeg:dash:schema:mpd:2011" type="static" mediaPresentationDuration="PT10S"><Period><AdaptationSet><Representation id="v"><BaseURL>v.mp4</BaseURL><SegmentBase indexRange="0-100"/></Representation></AdaptationSet><AdaptationSet><Representation id="a"><BaseURL>a.m4a</BaseURL></Representation></AdaptationSet></Period></MPD>"""
        val data = mapOf(url to xml.toByteArray(), "https://cdn.test/v.mp4" to mp4(audio = false), "https://cdn.test/a.m4a" to mp4(video = false))
        val m = media(candidate(url, "dash"))
        assertNotNull(WebVideoFormats.select(page, resolver(data).resolve(page, m)!!) { true }.audio)
        for (bad in listOf(xml.replace("type=\"static\"", "type=\"dynamic\""), xml.replace("<Period>", "<Period><ContentProtection/>"),
            xml.replace("<Period>", "<Period><SegmentTemplate/>"), "<!DOCTYPE MPD [<!ENTITY ext SYSTEM 'file:///private'>]>$xml"))
            assertNull(resolver(data + (url to bad.toByteArray())).resolve(page, m))
    }
    @Test fun cookieScopeAndExactRequestHeadersAreRetainedWithoutLeakingToOtherResources() {
        val cookie = JSONObject().put("name", "session").put("value", "synthetic").put("domain", "cdn.test").put("hostOnly", true).put("path", "/media").put("secure", true)
        val scope = WebVideoRequestHeaders(mapOf("https://cdn.test/media/root" to mapOf("authorization" to "exact")), JSONArray().put(cookie))
        val fallback = mapOf("cookie" to "unscoped=private", "authorization" to "private", "x-token" to "private", "user-agent" to "fixture")
        assertEquals("exact", scope.forUrl(URI("https://cdn.test/media/root"), fallback)["authorization"])
        assertEquals("session=synthetic", scope.forUrl(URI("https://cdn.test/media/segment"), fallback)["cookie"])
        for (url in listOf("https://cdn.test/other", "https://cdn.test/media-extra", "http://cdn.test/media/a", "https://other.test/media/a")) {
            val headers = scope.forUrl(URI(url), fallback)
            assertEquals(mapOf("user-agent" to "fixture"), headers)
        }
    }
    @Test fun genericIdentityDoesNotPublishPageOrResourceTokens() {
        val m = media(candidate("https://cdn.test/file.mp4?token=private"))
        val p = WebVideoNetworkCapture.page("https://server.test:8920/path?access_token=private#secret", m)!!
        assertTrue(p.url.startsWith("webvideo://capture/")); assertFalse(p.toString().contains("private")); assertFalse(p.toString().contains("server.test"))
        assertNotEquals(p, WebVideoNetworkCapture.page("https://server.test:8920/path?access_token=private#secret", JSONObject(m.toString()).put("network_epoch", 2)))
        assertNull(WebVideoNetworkCapture.page("https://page.test/watch", JSONObject(m.toString()).put("network_enabled", false)))
    }
    @Test fun realHostContainersAreInspectedWhenFixtureDirectoryIsProvided() {
        val root = System.getenv("WEB_VIDEO_NETWORK_FIXTURES")
        org.junit.Assume.assumeTrue(root != null)
        for (name in listOf("muxed.mp4", "video.mp4", "audio.m4a", "muxed.webm", "hevc.mp4")) {
            val info = WebVideoContainer.parse(java.io.File(root, name).readBytes()) ?: error("Cannot inspect $name")
            assertEquals(name != "audio.m4a", info.video != "none"); assertEquals(name != "video.mp4", info.audio != "none")
            assertTrue(info.duration in 3.9..4.1)
        }
        assertNull(WebVideoContainer.parse(java.io.File(root, "hevc10.mp4").readBytes()))
    }
    @Test fun realCapturedFileAndHlsDecodeAndSeekThroughProductionLeasesWithScopedSession() {
        val root = System.getenv("WEB_VIDEO_NETWORK_FIXTURES"); val ffmpeg = System.getenv("WEB_VIDEO_FFMPEG")
        org.junit.Assume.assumeTrue(root != null && ffmpeg != null)
        requireNotNull(root); requireNotNull(ffmpeg)
        org.vrpassthroughplayer.plugin.MediaServerClientTest.Fixture { request, headers, _ ->
            assertEquals("session=synthetic", headers["cookie"])
            val name = URI(request.split(' ')[1]).path.substringAfterLast('/')
            val file = java.io.File(root, name); require(file.parentFile == java.io.File(root))
            val data = file.readBytes()
            val range = headers["range"]?.let { LocalStreamServer.parseRange(it, data.size.toLong()) }
            if (range == null) org.vrpassthroughplayer.plugin.MediaServerClientTest.Reply(200, body = data)
            else org.vrpassthroughplayer.plugin.MediaServerClientTest.Reply(206,
                "Content-Range: bytes ${range.first}-${range.second}/${data.size}\r\n", data.copyOfRange(range.first.toInt(), range.second.toInt() + 1))
        }.use { origin ->
            for (name in listOf("muxed.mp4", "sample-network.m3u8")) {
                val url = "${origin.url}/media/$name"
                val cookies = JSONArray().put(JSONObject().put("name", "session").put("value", "synthetic")
                    .put("domain", URI(origin.url).host).put("path", "/media").put("hostOnly", true))
                val m = media(candidate(url, if (name.endsWith("m3u8")) "hls" else "file", JSONObject().put("Cookie", "session=synthetic"), cookies)).put("duration", 4)
                val capture = WebVideoNetworkCapture({ uri, headers, prefix ->
                    RemoteMediaHttp().use { http ->
                        val connection = http.open(uri, if (prefix) "bytes=0-2097151" else "", headers)
                        try { connection.url.toURI() to connection.inputStream.use { it.readBytes() } } finally { http.release(connection) }
                    }
                }, { true })
                val descriptor = WebVideoFormats.select(page, capture.resolve(page, m)!!) { true }
                LocalStreamServer().use { local -> WebVideoStreams { local }.use { streams ->
                    val leased = streams.prepare(descriptor)
                    val log = java.io.File(root, "network-decode-$name.log")
                    val process = ProcessBuilder(ffmpeg, "-v", "error", "-ss", "2", "-i", leased, "-t", "1", "-map", "0:v", "-map", "0:a", "-f", "null", "-")
                        .redirectErrorStream(true).redirectOutput(log).start()
                    try {
                        assertTrue(process.waitFor(30, java.util.concurrent.TimeUnit.SECONDS))
                        assertEquals(log.readText(), 0, process.exitValue()); assertTrue(log.readText().isBlank())
                    } finally { process.destroyForcibly() }
                    streams.release(leased); assertFalse(local.hasSource(leased))
                } }
            }
        }
    }
}
