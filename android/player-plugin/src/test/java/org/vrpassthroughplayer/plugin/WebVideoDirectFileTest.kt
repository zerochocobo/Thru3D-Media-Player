package org.vrpassthroughplayer.plugin

import org.json.JSONArray
import org.json.JSONObject
import org.junit.Assert.*
import org.junit.Test

class WebVideoDirectFileTest {
    private fun media() = JSONObject().put("direct_allowed", true).put("network_enabled", true)
        .put("source", "https://cdn.example/movie.mp4?sig=exact%2Bvalue").put("frame", "https://example/watch")
        .put("id", "7").put("network_epoch", 3).put("capture_identity", "tab:doc:7:3")
        .put("width", 1920).put("height", 1080).put("duration", 60).put("title", "Video")
        .put("network", JSONArray().put(JSONObject().put("url", "https://cdn.example/movie.mp4?sig=exact%2Bvalue")
            .put("kind", "file").put("mime", "video/mp4").put("at", System.currentTimeMillis())
            .put("headers", JSONObject().put("referer", "https://example/").put("cookie", "test=private")
                .put("range", "bytes=500-"))))

    @Test fun createsExactFileWithoutContainerOrExtractorAndKeepsCredentialsPrivate() {
        val descriptor = WebVideoDirectFile.descriptor("https://example/watch", media())!!
        assertEquals("https://cdn.example/movie.mp4?sig=exact%2Bvalue", descriptor.video.url.toString())
        assertEquals("test=private", descriptor.video.headers["cookie"])
        assertEquals("https://example/", descriptor.video.headers["referer"])
        assertFalse(descriptor.video.headers.containsKey("range"))
        assertNull(descriptor.audio)
        assertFalse(descriptor.publicJson().toString().contains("private"))
        assertFalse(descriptor.publicJson().toString().contains("sig="))
        assertNotNull(WebVideoDirectFile.descriptor("https://example/watch", media().put("width", 0).put("height", 0)))
    }

    @Test fun rejectsPreloadsSegmentsProtectedSourcesAndDisabledCapture() {
        val original = media()
        for ((key, value) in listOf("direct_allowed" to false, "network_enabled" to false,
            "protected" to true, "server" to true, "blob" to true, "width" to 20000,
            "source" to "https://cdn.example/another.mp4")) {
            assertNull(key, WebVideoDirectFile.descriptor("https://example/watch", JSONObject(original.toString()).put(key, value)))
        }
        for ((key, value) in listOf("kind" to "segment", "mime" to "text/html", "at" to 1L)) {
            val changed = media(); changed.getJSONArray("network").getJSONObject(0).put(key, value)
            assertNull(key, WebVideoDirectFile.descriptor("https://example/watch", changed))
        }
    }

    @Test fun clickedFileUsesNoAndroidContextCookiesOrPageExtractor() {
        val chosen = media()
        var published: WebVideoDescriptor? = null
        WebVideoResolver({ error("Must not initialize extractor") }, { published = it },
            { error("Must not collect page cookies") }, { error("Must not reselect another video") },
            { _, selection -> chosen.takeIf { selection == it.optString("capture_identity") } }).use { resolver ->
            resolver.begin("https://example/watch", selection = chosen.getString("capture_identity"), directFile = true)
            val deadline = System.nanoTime() + 3_000_000_000L
            while (JSONObject(resolver.snapshot()).optString("state") == "resolving" && System.nanoTime() < deadline) Thread.sleep(5)
            val result = JSONObject(resolver.snapshot())
            assertEquals(result.toString(), "ready", result.optString("state"))
            assertEquals("captured_file", result.getString("resolution_route"))
            assertNotNull(published)
        }
    }

    @Test fun sourceChangeDuringClickDoesNotPublishOldFileOrFallBackToExtraction() {
        val chosen = media(); var reads = 0; var published = false
        WebVideoResolver({ error("No fallback") }, { published = true }, selectedMedia = { _, _ ->
            if (++reads == 1) chosen else JSONObject(chosen.toString()).put("source", "https://cdn.example/new.mp4")
        }).use { resolver ->
            resolver.begin("https://example/watch", selection = chosen.getString("capture_identity"), directFile = true)
            val deadline = System.nanoTime() + 3_000_000_000L
            while (JSONObject(resolver.snapshot()).optString("state") == "resolving" && System.nanoTime() < deadline) Thread.sleep(5)
            assertEquals("browser_stream_changed", JSONObject(resolver.snapshot()).optString("error_code"))
            assertFalse(published)
        }
    }
}
