package org.vrpassthroughplayer.plugin

import org.json.JSONArray
import org.json.JSONObject
import org.junit.Assert.*
import org.junit.Test
import java.net.HttpURLConnection
import java.net.URI
import java.util.concurrent.ConcurrentLinkedQueue
import org.vrpassthroughplayer.plugin.MediaServerClientTest.Fixture
import org.vrpassthroughplayer.plugin.MediaServerClientTest.Reply

class WebVideoTest {
    @Test fun prefersSiteSuppliedRangeCapableCdnAtTheSameQuality() {
        val d = WebVideoFormats.select(page, info(
            format("peer", true, true).put("url", "https://node.mcdn.bilivideo.cn/video.mp4"),
            format("backup", true, true).put("url", "https://upos-sz-mirrorcos.bilivideo.com/video.mp4"))) { true }
        assertEquals("backup", d.video.formatId)
    }

    @Test fun defaultWebHandoffUsesFiniteRangesAcrossChunkBoundary() {
        val bytes = ByteArray(2 * 1024 * 1024 + 100) { (it % 251).toByte() }
        Fixture { _, headers, _ ->
            val match = Regex("bytes=(\\d+)-(\\d+)").matchEntire(headers["range"].orEmpty())
            if (match == null) Reply(200, body = bytes) else {
                val start = match.groupValues[1].toInt(); val end = minOf(match.groupValues[2].toInt(), bytes.lastIndex)
                Reply(206, "Content-Range: bytes $start-$end/${bytes.size}\r\n", bytes.copyOfRange(start, end+1))
            }
        }.use { origin -> LocalStreamServer().use { server -> WebVideoStreams { server }.use { streams ->
            val video = WebVideoTrack("v", URI(origin.url+"/video"), emptyMap(), "mp4", "avc1.640028", "mp4a.40.2",1920,1080,30.0)
            val uri = streams.prepare(WebVideoDescriptor(page,"Fixture",video,null,10.0))
            val c = URI(uri).toURL().openConnection() as HttpURLConnection
            try {
                c.setRequestProperty("Range","bytes=500000-1800000")
                assertArrayEquals(bytes.copyOfRange(500000,1800001),c.inputStream.use { it.readBytes() })
            } finally { c.disconnect() }
        } } }
    }
    private val page = WebVideoPage.parse("https://www.youtube.com/watch?v=BaW_jenozKc")
    private fun format(id: String, video: Boolean, audio: Boolean, height: Int = 1080): JSONObject = JSONObject()
        .put("format_id", id).put("url", "https://cdn.test/$id?signature=secret")
        .put("protocol", "https").put("ext", if (video) "mp4" else "m4a")
        .put("vcodec", if (video) "avc1.640028" else "none").put("acodec", if (audio) "mp4a.40.2" else "none")
        .put("width", if (video) height * 16 / 9 else 0).put("height", if (video) height else 0)
        .put("fps", if (video) 30 else 0).put("tbr", if (video) height else 128)
    private fun info(vararg formats: JSONObject) = JSONObject().put("title", "Fixture").put("duration", 10)
        .put("formats", JSONArray(formats.toList()))
    private fun track(url: String, audio: Boolean, headers: Map<String, String> = emptyMap(), chunk: Long = 0) =
        WebVideoTrack(if (audio) "a" else "v", URI(url), headers, if (audio) "m4a" else "mp4",
            if (audio) "none" else "avc1.640028", if (audio) "mp4a.40.2" else "none", if (audio) 0 else 1920,
            if (audio) 0 else 1080, if (audio) 0.0 else 30.0, chunkBytes = chunk)

    @Test fun canonicalIdentityDropsTrackingAndPreservesBilibiliPart() {
        assertEquals(page, WebVideoPage.parse("https://youtu.be/BaW_jenozKc?si=private&t=30"))
        assertEquals(page, WebVideoPage.parse("https://m.youtube.com/shorts/BaW_jenozKc"))
        assertEquals("https://www.bilibili.com/video/BV1xx411c7mD/?p=2", WebVideoPage.parse("https://www.bilibili.com/video/BV1xx411c7mD?p=2&token=private").url)
        for (bad in listOf("https://youtube.com.evil/watch?v=BaW_jenozKc", "https://user@youtube.com/watch?v=BaW_jenozKc",
            "file:///tmp/a.mp4", "https://youtu.be/--version", "https://www.youtube.com/playlist?list=secret"))
            assertThrows(Exception::class.java) { WebVideoPage.parse(bad) }
    }
    @Test fun selectsCompatibleSplitStreamsWithSeparateHeadersWithoutExposingSecrets() {
        val json = info(format("4k", true, false, 2160), format("v", true, false), format("a", false, true)
            .put("http_headers", JSONObject().put("Authorization", "audio-key")))
            .put("http_headers", JSONObject().put("Referer", page.url).put("Authorization", "video-key"))
        val d = WebVideoFormats.select(page, json) { it.height <= 1080 }
        assertEquals("v", d.video.formatId); assertEquals("a", d.audio!!.formatId)
        assertEquals("video-key", d.video.headers["authorization"])
        assertEquals("audio-key", d.audio.headers["authorization"])
        for (text in listOf(d.publicJson().toString(), d.toString(), d.video.toString())) {
            assertFalse(text.contains("secret")); assertFalse(text.contains("video-key")); assertFalse(text.contains("cdn.test"))
        }
    }
    @Test fun rejectsMissingAudioAndUnsupportedOrProtectedTransportWithoutPretendingItIsAFile() {
        for (f in listOf(format("v", true, true).put("has_drm", true), format("v", true, true).put("protocol", "http_dash_segments"),
            format("v", true, true).put("fragments", JSONArray()), format("v", true, true).put("url", "file:///tmp/private"),
            format("v", true, false))) {
            assertThrows(Exception::class.java) { WebVideoFormats.select(page, info(f)) { true } }
        }
        assertThrows(Exception::class.java) { WebVideoFormats.select(page, info(format("v", true, true)).put("is_live", true)) { true } }
        assertNull(WebVideoFormats.select(page, info(format("v", true, true))) { true }.audio)
        assertThrows(Exception::class.java) { track("https://cdn.test/video", false, mapOf("Cookie" to "secret\r\nInjected: true")) }
    }
    @Test fun androidNullStringCoercionDoesNotDiscardYoutubeAudio() {
        // JVM org.json treats NULL differently from Android's platform implementation.
        val androidAudio = object : JSONObject(format("a", false, true).toString()) {
            override fun optString(key: String, fallback: String): String =
                if (has(key) && isNull(key)) "null" else super.optString(key, fallback)
            override fun optString(key: String): String = optString(key, "")
        }.put("dynamic_range", JSONObject.NULL).put("fps", JSONObject.NULL)
            .put("manifest_url", JSONObject.NULL).put("fragments", JSONObject.NULL)
        val selected = WebVideoFormats.select(page, info(format("v", true, false), androidAudio)) { true }
        assertEquals("v", selected.video.formatId)
        assertEquals("a", selected.audio!!.formatId)
        assertEquals(0.0, selected.audio!!.fps, 0.0)
    }
    @Test fun independentCredentialsAndBoundedRangesReachBothTracksAndOldReleaseCannotCloseReplacement() {
        val bytes = ByteArray(4096) { (it % 251).toByte() }
        val seen = ConcurrentLinkedQueue<Pair<String, Map<String, String>>>()
        Fixture { request, headers, _ ->
            seen.add(request to headers)
            val range = LocalStreamServer.parseRange(headers["range"], bytes.size.toLong())!!
            Reply(206, "Content-Type: video/mp4\r\nContent-Range: bytes ${range.first}-${range.second}/${bytes.size}\r\n",
                bytes.copyOfRange(range.first.toInt(), range.second.toInt()+1))
        }.use { origin -> LocalStreamServer().use { server -> WebVideoStreams { server }.use { streams ->
            val d = WebVideoDescriptor(page, "Test", track(origin.url + "/video", false, mapOf("Cookie" to "video-only"), 1024),
                track(origin.url + "/audio", true, mapOf("Cookie" to "audio-only"), 1024), 10.0)
            streams.remember(d)
            val first = streams.prepare(d)
            assertTrue(streams.audio(page.url).single().requiredPrimary)
            assertFalse(SidecarAudio.Track("file:///optional.m4a", "Optional dub").requiredPrimary)
            val firstAudio = streams.audio(page.url).single().location
            val listeningAudio = ListeningPolicy.audioInput(first, JSONObject().put("id",1).put("stream_index",0)
                .put("external",true).put("filename",firstAudio),streams.audio(page.url).single().location,0.0)!!
            assertEquals(firstAudio,listeningAudio.path)
            fun read(url: String) {
                val c = URI(url).toURL().openConnection() as HttpURLConnection
                try { c.setRequestProperty("Range", "bytes=2000-3500"); assertArrayEquals(bytes.copyOfRange(2000, 3501), c.inputStream.use { it.readBytes() }) }
                finally { c.disconnect() }
            }
            read(first); read(listeningAudio.path)
            val next = streams.prepare(d)
            streams.release(first)
            assertFalse(server.hasSource(first)); assertFalse(server.hasSource(firstAudio))
            assertTrue(server.hasSource(next)); assertTrue(server.hasSource(streams.audio(page.url).single().location))
            read(next)
            streams.release(next)
            assertFalse(server.hasSource(next))
        } } }
        assertTrue(seen.size >= 8)
        seen.forEach { (request, headers) ->
            assertEquals(if (request.contains("/audio")) "audio-only" else "video-only", headers["cookie"])
            val range = headers.getValue("range").removePrefix("bytes=").split('-')
            assertTrue(range[1].toLong() - range[0].toLong() < 1024)
        }
    }
    @Test fun failedVideoProbeDoesNotLeavePublishedAudioOrAPlayableHalfSession() {
        Fixture { request, _, _ -> if (request.contains("/audio")) Reply(206, "Content-Range: bytes 0-0/1\r\n", byteArrayOf(1))
            else Reply(403, body = "private".toByteArray()) }.use { origin -> LocalStreamServer().use { server ->
            WebVideoStreams { server }.use { streams ->
                val d = WebVideoDescriptor(page, "Test", track(origin.url + "/video", false), track(origin.url + "/audio", true), 10.0)
                assertThrows(Exception::class.java) { streams.prepare(d) }
                assertThrows(Exception::class.java) { streams.audio(page.url) }
            }
        } }
    }
}
