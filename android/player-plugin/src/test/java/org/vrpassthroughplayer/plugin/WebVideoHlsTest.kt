package org.vrpassthroughplayer.plugin

import org.junit.Assert.*
import org.junit.Test
import java.net.URI
import org.vrpassthroughplayer.plugin.MediaServerClientTest.Fixture
import org.vrpassthroughplayer.plugin.MediaServerClientTest.Reply

class WebVideoHlsTest {
    private fun track(url: String, headers: Map<String, String> = emptyMap()) = WebVideoTrack("hls", URI(url), headers,
        "mp4", "avc1.640028", "mp4a.40.2", 1920, 1080, 30.0, transport = "hls")
    private fun read(url: String) = URI(url).toURL().openStream().use { it.readBytes() }

    @Test fun ffmpegDecodesAndSeeksThroughTheProductionManifestTransport() {
        val ffmpeg = System.getenv("WEB_VIDEO_FFMPEG")
        org.junit.Assume.assumeTrue("Optional host FFmpeg integration", !ffmpeg.isNullOrEmpty())
        val root = java.io.File(System.getenv("WEB_VIDEO_FIXTURES") ?: error("Set the fixture output directory")).apply { mkdirs() }
        fun run(vararg args: String) {
            val p = ProcessBuilder(listOf(ffmpeg!!) + args).directory(root).redirectErrorStream(true)
                .redirectOutput(java.io.File(root, "ffmpeg.log")).start()
            try { assertTrue(p.waitFor(45, java.util.concurrent.TimeUnit.SECONDS)); assertEquals(java.io.File(root, "ffmpeg.log").readText(), 0, p.exitValue()) }
            finally { p.destroyForcibly() }
        }
        run("-v", "error", "-y", "-f", "lavfi", "-i", "testsrc2=size=160x90:rate=15", "-f", "lavfi", "-i", "sine=frequency=440:sample_rate=48000",
            "-t", "4", "-c:v", "libx264", "-g", "15", "-c:a", "aac", "-f", "hls", "-hls_time", "1", "-hls_playlist_type", "vod", "sample.m3u8")
        Fixture { request, _, _ ->
            val name = request.split(' ')[1].substringAfterLast('/')
            val file = java.io.File(root, name)
            if (file.isFile && file.parentFile == root) Reply(200, body = file.readBytes()) else Reply(404, body = ByteArray(0))
        }.use { origin -> LocalStreamServer().use { local -> WebVideoHls(local).use { hls ->
            val url = hls.prepare(track(origin.url + "/sample.m3u8"))
            run("-v", "error", "-i", url, "-map", "0:v", "-map", "0:a", "-f", "null", "-")
            run("-v", "error", "-ss", "2", "-i", url, "-t", "1", "-map", "0:v", "-map", "0:a", "-f", "null", "-")
        } } }
    }

    @Test fun rewritesNestedManifestsMapAndSegmentsAndRevokesEveryCapability() {
        val segment = ByteArray(1024) { (it % 251).toByte() }
        Fixture { request, headers, _ ->
            assertEquals("session=synthetic", headers["cookie"])
            assertNull(headers["range"])
            when {
                request.contains("/master") -> Reply(200, body = "#EXTM3U\n#EXT-X-STREAM-INF:BANDWIDTH=1000\nvideo/list.m3u8?private=1\n".toByteArray())
                request.contains("/video/list") -> Reply(200, body = "#EXTM3U\n#EXT-X-TARGETDURATION:4\n#EXT-X-MAP:URI=\"init.mp4?private=2\"\n#EXTINF:4,\nsegment.m4s?private=3\n#EXT-X-ENDLIST\n".toByteArray())
                else -> Reply(200, body = segment)
            }
        }.use { origin -> LocalStreamServer().use { local ->
            val hls = WebVideoHls(local)
            val url = hls.prepare(track(origin.url + "/master.m3u8", mapOf("Cookie" to "session=synthetic")))
            val root = read(url).toString(Charsets.UTF_8)
            assertFalse(root.contains("private="))
            val child = root.lines().first { it.startsWith("http") }
            val playlist = read(child).toString(Charsets.UTF_8)
            val media = playlist.lines().first { it.startsWith("http") }
            val init = Regex("URI=\"([^\"]+)\"").find(playlist)!!.groupValues[1]
            assertFalse(playlist.contains("private="))
            assertArrayEquals(segment, read(media)); assertArrayEquals(segment, read(init))
            hls.close()
            listOf(url, child, media, init).forEach { assertFalse(local.hasSource(it)) }
        } }
    }

    @Test fun neverForwardsAccountHeadersToAnotherOriginAndHandlesAesIdentityKeys() {
        Fixture { _, headers, _ ->
            assertNull(headers["cookie"]); assertNull(headers["authorization"])
            Reply(200, body = ByteArray(16) { 7 })
        }.use { cdn -> Fixture { _, _, _ ->
            Reply(200, body = "#EXTM3U\n#EXT-X-TARGETDURATION:1\n#EXT-X-KEY:METHOD=AES-128,URI=\"${cdn.url}/key\"\n#EXTINF:1,\n${cdn.url}/segment.ts\n#EXT-X-ENDLIST\n".toByteArray())
        }.use { origin -> LocalStreamServer().use { local -> WebVideoHls(local).use { hls ->
            val text = read(hls.prepare(track(origin.url + "/list", mapOf("Cookie" to "private", "Authorization" to "private")))).toString(Charsets.UTF_8)
            val key = Regex("URI=\"([^\"]+)\"").find(text)!!.groupValues[1]
            assertEquals(16, read(key).size)
            assertEquals(16, read(text.lines().first { it.startsWith("http") }).size)
        } } } }
    }

    @Test fun rejectsProtectedLiveCyclicAndNonHttpManifests() {
        for (body in listOf(
            "#EXTM3U\n#EXT-X-KEY:METHOD=SAMPLE-AES,URI=\"key\"\n#EXT-X-ENDLIST\n",
            "#EXTM3U\n#EXT-X-KEY:METHOD=AES-128,KEYFORMAT=\"com.apple.streamingkeydelivery\",URI=\"key\"\n#EXT-X-ENDLIST\n",
            "#EXTM3U\n#EXTINF:1,\nsegment.ts\n",
            "#EXTM3U\n#EXT-X-STREAM-INF:BANDWIDTH=1\nlist\n",
            "#EXTM3U\n#EXTINF:1,\nfile:///secret\n#EXT-X-ENDLIST\n")) {
            Fixture { _, _, _ -> Reply(200, body = body.toByteArray()) }.use { origin -> LocalStreamServer().use { local ->
                WebVideoHls(local).use { hls -> assertThrows(Exception::class.java) { hls.prepare(track(origin.url + "/list")) } }
            } }
        }
    }
}
