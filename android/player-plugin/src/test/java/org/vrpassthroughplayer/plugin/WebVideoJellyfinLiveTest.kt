package org.vrpassthroughplayer.plugin

import org.json.JSONArray
import org.json.JSONObject
import org.junit.Assert.*
import org.junit.Assume.assumeTrue
import org.junit.Test
import java.net.URI
import java.util.UUID

/** Read-only server/browser-format integration. All credentials stay in process memory. */
class WebVideoJellyfinLiveTest {
    @Test fun webOriginalAndDeclaredHlsUseTheProductionServerHandoff() {
        val base = System.getenv("VRPP_JELLYFIN_TEST_URL").orEmpty()
        val username = System.getenv("VRPP_JELLYFIN_TEST_USERNAME").orEmpty()
        val password = System.getenv("VRPP_JELLYFIN_TEST_PASSWORD")
        assumeTrue("Optional local Jellyfin browser integration", base.isNotBlank() && username.isNotBlank() && password != null)
        val anonymous = MediaServerAccount(UUID.randomUUID().toString(), "Browser integration", MediaServerAccount.address(base), "", "jellyfin")
        val account = MediaServerHttp(anonymous).use { EmbyClient(anonymous, it).login(username, password!!) }
        MediaServerHttp(account).use { http ->
            fun request(path: String, body: JSONObject? = null): JSONObject {
                val raw = String(http.bytes(account.endpoint(path), 4 * 1024 * 1024, body), Charsets.UTF_8)
                return if (raw.isBlank()) JSONObject() else JSONObject(raw)
            }
            try {
                val requested = System.getenv("VRPP_JELLYFIN_BROWSER_TEST_ITEM").orEmpty()
                val items = request("Items?UserId=${account.userId}&Recursive=true&IncludeItemTypes=Movie,Episode,Video&Fields=MediaSources,MediaStreams&Limit=100")
                    .getJSONArray("Items").objects()
                val item = items.firstOrNull { it.getString("Id") == requested } ?: items.firstOrNull { it.optInt("Width") >= 3840 }
                assumeTrue("Need a high-resolution sample", item != null)
                val id = item!!.getString("Id")
                val info = request("Items/$id/PlaybackInfo?UserId=${account.userId}")
                val source = info.getJSONArray("MediaSources").getJSONObject(0)
                val video = source.getJSONArray("MediaStreams").objects().first { it.optString("Type") == "Video" }
                val frame = account.base.trimEnd('/') + "/web/#/video"
                fun verify(url: URI, kind: String) {
                    val media = JSONObject().put("server", true).put("frame", frame).put("source", url.toString())
                        .put("width", video.getInt("Width")).put("height", video.getInt("Height"))
                        .put("duration", source.optLong("RunTimeTicks") / 10000000.0).put("title", "Jellyfin test")
                    val page = WebVideoBrowserCapture.serverPage(frame, media) ?: error("Server URL not recognized ($kind)")
                    val limit = WebVideoBrowserCapture.maximumHeight(media, false, false)
                    val (_, descriptor) = WebVideoResolution.select(page, { WebVideoBrowserCapture.formats(media) },
                        { error("Media-server playback must not invoke the external extractor") }, WebVideoCapabilities(limit)::accepts)
                    assertEquals("media_server", descriptor.page.site)
                    assertEquals("file", descriptor.video.transport)
                    assertEquals(video.getInt("Width"), descriptor.video.width)
                    assertEquals(video.getInt("Height"), descriptor.video.height)
                    assertFalse(descriptor.publicJson().toString().contains(account.key))
                    assertFalse(page.url.contains(account.key))
                    LocalStreamServer().use { local -> WebVideoStreams { local }.use { streams ->
                        val playable = streams.prepare(descriptor)
                        assertFalse(playable.contains(account.key))
                        for (start in listOf(0L, source.getLong("Size") / 2)) {
                            val connection = URI(playable).toURL().openConnection() as java.net.HttpURLConnection
                            try {
                                connection.setRequestProperty("Range", "bytes=$start-${start + 63}")
                                assertEquals(206, connection.responseCode)
                                assertEquals(64, connection.inputStream.use { it.readBytes().size })
                            } finally { connection.disconnect() }
                        }
                        val ffmpeg = System.getenv("VRPP_WEB_VIDEO_FFMPEG").orEmpty()
                        if (kind == "direct" && ffmpeg.isNotBlank()) {
                            val sink = java.io.File(if (System.getProperty("os.name").orEmpty().startsWith("Windows")) "NUL" else "/dev/null")
                            for (position in listOf(0, 2)) {
                                val decoder = ProcessBuilder(ffmpeg, "-nostdin", "-v", "error", "-threads", "2", "-ss", position.toString(),
                                    "-i", playable, "-an", "-frames:v", "1", "-f", "null", "-")
                                    .redirectOutput(sink).redirectError(sink).start()
                                try { assertTrue("Desktop decoder timed out", decoder.waitFor(45, java.util.concurrent.TimeUnit.SECONDS))
                                    assertEquals("Desktop decode/seek failed", 0, decoder.exitValue())
                                } finally { decoder.destroyForcibly() }
                            }
                            println("Live Jellyfin native proxy: desktop frame decode and time seek verified")
                        }
                        streams.release(playable)
                    } }
                    println("Live Jellyfin browser $kind: ${descriptor.video.width}x${descriptor.video.height}, native original selected, first/middle Range 206")
                }
                // Exact URL shape observed on this installation's HTMLVideoElement.
                verify(account.endpoint("Videos/$id/stream.mp4?" + mediaQuery(mapOf("Static" to true,
                    "mediaSourceId" to source.getString("Id"), "deviceId" to account.id, "ApiKey" to account.key))), "direct")
                val profile = JSONObject().put("Name", "HLS browser probe").put("MaxStreamingBitrate", 2000000)
                    .put("DirectPlayProfiles", JSONArray()).put("CodecProfiles", JSONArray())
                    .put("TranscodingProfiles", JSONArray().put(JSONObject().put("Type", "Video").put("Container", "ts")
                        .put("Protocol", "hls").put("Context", "Streaming").put("VideoCodec", "h264").put("AudioCodec", "aac")))
                val posted = request("Items/$id/PlaybackInfo?UserId=${account.userId}", JSONObject()
                    .put("DeviceProfile", profile).put("MediaSourceId", source.getString("Id"))
                    .put("EnableDirectPlay", false).put("EnableDirectStream", false).put("EnableTranscoding", true)
                    .put("MaxStreamingBitrate", 2000000).put("StartTimeTicks", 0))
                val transcoding = posted.getJSONArray("MediaSources").getJSONObject(0).optString("TranscodingUrl")
                assertTrue("Server must declare its HLS path", transcoding.isNotBlank())
                verify(account.endpoint("").resolve(transcoding), "declared-hls")
            } finally { request("Sessions/Logout", JSONObject()) }
        }
    }
}
