package org.vrpassthroughplayer.plugin

import org.json.JSONArray
import org.json.JSONObject
import org.junit.Assert.*
import org.junit.Test

class WebVideoPlexCaptureTest {
    private val frame = "http://127.0.0.1:32400/web/index.html#!/server/local/details"
    private val source = "http://127.0.0.1:32400/video/:/transcode/universal/start.mpd?path=%2Flibrary%2Fmetadata%2F4&mediaIndex=1&partIndex=0"
    private fun media(url: String = source) = JSONObject().put("server", true).put("frame", frame).put("source", url)
        .put("server_headers", JSONObject().put("X-Plex-Token", "private").put("X-Plex-Client-Identifier", "web"))
        .put("width", 1920).put("height", 1080).put("duration", 60.0)
    private fun metadata(): JSONObject {
        fun version(id: Int, width: Int) = JSONObject().put("width", width).put("height", width / 2).put("container", "mkv")
            .put("Part", JSONArray().put(JSONObject().put("id", id).put("key", "/library/parts/$id/123/file.mkv").put("duration", 60000)))
        return JSONObject().put("MediaContainer", JSONObject().put("Metadata", JSONArray().put(JSONObject().put("ratingKey", "4")
            .put("type", "movie").put("Media", JSONArray().put(version(41, 1920)).put(version(42, 8192))))))
    }
    @Test fun selectsTheBrowsersVersionAndKeepsCredentialsOutOfThePublicDescriptor() {
        val captured = media(); val page = WebVideoBrowserCapture.serverPage(frame, captured)!!
        var calls = 0
        val info = WebVideoBrowserCapture.formats(captured) { uri, headers ->
            calls++; assertEquals("/library/metadata/4", uri.path); assertNull(uri.rawQuery)
            assertEquals("private", headers["X-Plex-Token"]); assertEquals("application/json", headers["Accept"])
            uri to metadata().toString().toByteArray()
        }!!
        val descriptor = WebVideoResolution.select(page, { info }, { error("Extractor must stay lazy") },
            WebVideoCapabilities(WebVideoBrowserCapture.maximumHeight(captured, false, false))::accepts).second
        assertEquals(1, calls); assertEquals("plex:4:1:0", page.id)
        assertEquals("/library/parts/42/123/file.mkv", descriptor.video.url.path)
        assertEquals(8192, descriptor.video.width); assertEquals("private", descriptor.video.headers["x-plex-token"])
        assertFalse(descriptor.publicJson().toString().contains("private")); assertNull(descriptor.video.url.rawQuery)
    }
    @Test fun directOriginalNeedsNoMetadataFetchAndOnlyReplaysItsOwnPlexHeaders() {
        val captured = media("http://127.0.0.1:32400/library/parts/4/123/file.mp4?X-Plex-Token=private")
        val info = WebVideoBrowserCapture.formats(captured) { _, _ -> error("Direct original must not fetch metadata") }!!
        val descriptor = WebVideoFormats.select(WebVideoBrowserCapture.serverPage(frame, captured)!!, info) { true }
        assertEquals("file", descriptor.video.transport); assertEquals("/library/parts/4/123/file.mp4", descriptor.video.url.path)
        assertEquals(setOf("x-plex-token", "x-plex-client-identifier"), descriptor.video.headers.keys)
    }
    @Test fun reverseProxyAndOffsetHlsKeepTheOriginalDurationAndPart() {
        val captured = media(source.replace("/video/", "/plex/video/") + "&copyts=0&offset=30")
            .put("frame", frame.replace("/web/", "/plex/web/")).put("duration", 30.0)
        val info = WebVideoBrowserCapture.formats(captured) { uri, _ ->
            assertEquals("/plex/library/metadata/4", uri.path)
            uri to metadata().toString().toByteArray()
        }!!
        val descriptor = WebVideoFormats.select(WebVideoBrowserCapture.serverPage(captured.getString("frame"), captured)!!, info) { true }
        assertEquals("/plex/library/parts/42/123/file.mkv", descriptor.video.url.path)
        assertEquals(60.0, descriptor.durationSeconds, 0.0)
    }
    @Test fun rejectsAmbiguousVersionsMultipartMismatchedItemsDurationsAndForeignParts() {
        val variants = listOf<(JSONObject) -> Unit>(
            { it.getJSONObject("MediaContainer").getJSONArray("Metadata").getJSONObject(0).put("ratingKey", "5") },
            { it.getJSONObject("MediaContainer").getJSONArray("Metadata").getJSONObject(0).put("type", "photo") },
            { selected(it).put("origin", "livetv") },
            { selected(it).put("drm", true) },
            { selected(it).getJSONArray("Part").put(JSONObject()) },
            { part(it).put("key", "https://foreign.test/library/parts/42/123/file.mkv") },
            { part(it).put("key", "/library/parts/99/123/file.mkv") },
            { part(it).put("duration", 120000) },
            { part(it).put("accessible", false) },
            { part(it).put("license", "protected") })
        for (change in variants) {
            val data = metadata(); change(data)
            assertNull(WebVideoBrowserCapture.formats(media()) { uri, _ -> uri to data.toString().toByteArray() })
        }
        assertNull(WebVideoBrowserCapture.formats(media(source.replace("mediaIndex=1", "mediaIndex=-1"))) { uri, _ -> uri to metadata().toString().toByteArray() })
    }
    @Test fun rejectsUnrelatedOriginsDuplicateTokensProtectedAndNonLibraryRequests() {
        for (url in listOf(source.replace("127.0.0.1", "other.test"), source.replace("metadata%2F4", "metadata%2F4%2F.."),
            source + "&X-Plex-Token=other", source + "&path=%2Flibrary%2Fmetadata%2F5", source.replace("start.mpd", "session/segment.m4s")))
            assertNull(WebVideoBrowserCapture.serverPage(frame, media(url)))
        assertNull(WebVideoBrowserCapture.serverPage(frame, media().put("protected", true)))
        assertNull(WebVideoBrowserCapture.serverPage(frame, media().put("server_headers", JSONObject())))
    }
    private fun selected(data: JSONObject) = data.getJSONObject("MediaContainer").getJSONArray("Metadata").getJSONObject(0).getJSONArray("Media").getJSONObject(1)
    private fun part(data: JSONObject) = selected(data).getJSONArray("Part").getJSONObject(0)
}
