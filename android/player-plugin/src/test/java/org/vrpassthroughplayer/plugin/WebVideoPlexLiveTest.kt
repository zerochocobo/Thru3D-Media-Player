package org.vrpassthroughplayer.plugin

import java.io.File
import java.net.HttpURLConnection
import java.net.URI
import java.util.concurrent.TimeUnit
import org.json.JSONObject
import org.junit.Assert.*
import org.junit.Assume.assumeTrue
import org.junit.Test

/** Optional, read-only integration using a token supplied in the process environment. */
class WebVideoPlexLiveTest {
    @Test fun browserDashHlsAndDirectOriginalUseThePrivateNativeProxy() {
        val base = System.getenv("VRPP_PLEX_TEST_URL").orEmpty().trimEnd('/')
        val token = System.getenv("VRPP_PLEX_TEST_TOKEN").orEmpty()
        assumeTrue("Optional local Plex browser integration", base.isNotBlank() && token.isNotBlank())
        val id = System.getenv("VRPP_PLEX_BROWSER_TEST_ITEM").orEmpty().ifBlank { "4" }
        require(id.matches(Regex("[0-9]{1,20}")))
        val headers = mapOf("X-Plex-Token" to token, "X-Plex-Client-Identifier" to "thru3d-browser-live")
        fun read(uri: URI, auth: Map<String, String>): Pair<URI, ByteArray> = RemoteMediaHttp().use { http ->
            WebVideoBrowserResourceReader.read(uri, auth, false, http) { }
        }
        val item = JSONObject(String(read(URI("$base/library/metadata/$id"), headers + ("Accept" to "application/json")).second,
            Charsets.UTF_8)).getJSONObject("MediaContainer").getJSONArray("Metadata").getJSONObject(0)
        val version = item.getJSONArray("Media").getJSONObject(0)
        val part = version.getJSONArray("Part").getJSONObject(0)
        val frame = "$base/web/index.html#!/server/local/details?key=%2Flibrary%2Fmetadata%2F$id"
        for (kind in listOf("dash", "hls", "direct")) {
            val path = if (kind == "direct") part.getString("key") else
                "/video/:/transcode/universal/start.${if (kind == "dash") "mpd" else "m3u8"}?path=%2Flibrary%2Fmetadata%2F$id&mediaIndex=0&partIndex=0"
            val media = JSONObject().put("source", base + path).put("server", true).put("server_headers", JSONObject(headers))
                .put("frame", frame).put("width", version.getInt("width")).put("height", version.getInt("height"))
                .put("duration", item.getLong("duration") / 1000.0)
            val page = WebVideoBrowserCapture.serverPage(frame, media) ?: error("Plex browser source not recognized")
            val descriptor = WebVideoResolution.select(page, { WebVideoBrowserCapture.formats(media, readServer = ::read) },
                { error("Plex must not initialize the external extractor") },
                WebVideoCapabilities(WebVideoBrowserCapture.maximumHeight(media, false, false))::accepts).second
            assertEquals(part.getString("key"), descriptor.video.url.path)
            assertEquals(version.getInt("width"), descriptor.video.width)
            assertEquals("file", descriptor.video.transport)
            assertFalse(descriptor.publicJson().toString().contains(token))
            LocalStreamServer().use { local -> WebVideoStreams { local }.use { streams ->
                val playable = streams.prepare(descriptor)
                assertFalse(playable.contains(token))
                try {
                    for (start in listOf(0L, part.getLong("size") / 2)) {
                        val connection = URI(playable).toURL().openConnection() as HttpURLConnection
                        try {
                            connection.setRequestProperty("Range", "bytes=$start-${start + 63}")
                            assertEquals(206, connection.responseCode)
                            assertEquals(64, connection.inputStream.use { it.readBytes().size })
                        } finally { connection.disconnect() }
                    }
                    val ffmpeg = System.getenv("VRPP_WEB_VIDEO_FFMPEG").orEmpty()
                    if (kind == "dash" && ffmpeg.isNotBlank()) {
                        val sink = File(if (System.getProperty("os.name").orEmpty().startsWith("Windows")) "NUL" else "/dev/null")
                        for (position in listOf(0, 2)) {
                            val decoder = ProcessBuilder(ffmpeg, "-nostdin", "-v", "error", "-threads", "2", "-ss", position.toString(),
                                "-i", playable, "-t", "0.25", "-f", "null", "-").redirectOutput(sink).redirectError(sink).start()
                            try {
                                assertTrue("Desktop decode timed out", decoder.waitFor(45, TimeUnit.SECONDS))
                                assertEquals("Desktop audio/video decode or seek failed", 0, decoder.exitValue())
                            } finally { decoder.destroyForcibly() }
                        }
                        println("Live Plex native proxy: audio/video decode and time seek verified")
                    }
                } finally { streams.release(playable) }
            } }
            println("Live Plex browser $kind: ${descriptor.video.width}x${descriptor.video.height}, original selected, first/middle Range 206")
        }
    }
}
