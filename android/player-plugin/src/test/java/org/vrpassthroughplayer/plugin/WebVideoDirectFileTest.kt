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
        assertTrue("Captured file must pass the actual native player input gate",
            MpvInputUri.accepts(descriptor.publicJson().getString("uri")))
        assertFalse(descriptor.publicJson().toString().contains("private"))
        assertFalse(descriptor.publicJson().toString().contains("sig="))
        assertNotNull(WebVideoDirectFile.descriptor("https://example/watch", media().put("width", 0).put("height", 0)))
    }

    @Test fun nativeInputGateAcceptsOnlyOpaqueCaptureHandlesAndKeepsExistingSources() {
        val valid = "webvideo://capture/" + "a1".repeat(32)
        assertTrue(MpvInputUri.accepts(valid))
        for (invalid in listOf("webvideo://capture/", valid + "?url=https://example/video.mp4", valid + "#fragment",
            valid + "/extra", valid.replace("capture/", "other/"), "webvideo://capture/not-a-hash",
            "javascript:alert(1)", "data:video/mp4,test")) assertFalse(invalid, MpvInputUri.accepts(invalid))
        for (scheme in listOf("content", "file", "usb", "smb", "cloud", "medialib", "dlna", "http", "https", "externalvideo", "airplayvideo"))
            assertTrue(scheme, MpvInputUri.accepts("$scheme://source/video.mp4"))
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

    @Test fun untransferableSnapshotReportsOnlyItsBranchSourceTypeAndCounts() {
        val page = "https://115vod.com/?pickcode=fixture-only"
        val chosen = media()
        val requests = chosen.getJSONArray("network")
        // Neither an unrelated preload nor an unbound blob establishes a whole file.
        chosen.put("source", "https://cdn.example/different.mp4")
        fun failed(direct: Boolean): JSONObject {
            WebVideoResolver({ android.content.ContextWrapper(null) }, { fail("Unexpected transfer") },
                browserMedia = { chosen }, selectedMedia = { _, _ -> chosen }).use { resolver ->
                resolver.begin(page, selection = if (direct) chosen.getString("capture_identity") else "", directFile = direct)
                val deadline = System.nanoTime() + 3_000_000_000L
                while (JSONObject(resolver.snapshot()).optString("state") == "resolving" && System.nanoTime() < deadline) Thread.sleep(5)
                val result = JSONObject(resolver.snapshot())
                assertEquals(result.toString(), "browser_playback_required", result.optString("error_code"))
                return result.getJSONObject("capture")
            }
        }
        val direct = failed(true)
        assertEquals(setOf("step", "source_kind", "file", "hls", "dash", "source_matches"), direct.keys().asSequence().toSet())
        assertEquals("file_descriptor", direct.getString("step"))
        assertEquals("http", direct.getString("source_kind"))
        assertEquals(0, direct.getInt("source_matches"))
        assertEquals(1, direct.getInt("file"))
        // Nine distinct files exceed the generic resolver's probe limit, before any I/O.
        chosen.put("source", "").put("blob", true)
        for (i in 1..8) requests.put(JSONObject().put("kind", "file").put("url", "https://cdn.example/$i.mp4"))
        val network = failed(false)
        assertEquals(direct.keys().asSequence().toSet(), network.keys().asSequence().toSet())
        assertEquals("network_capture", network.getString("step"))
        assertEquals("blob", network.getString("source_kind"))
        assertEquals(9, network.getInt("file"))
        for (key in listOf("hls", "dash", "source_matches")) assertEquals(0, network.getInt(key))
    }
}
