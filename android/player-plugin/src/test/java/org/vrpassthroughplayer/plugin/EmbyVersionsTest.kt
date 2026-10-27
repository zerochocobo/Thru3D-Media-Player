package org.vrpassthroughplayer.plugin

import org.json.JSONArray
import org.json.JSONObject
import org.junit.Assert.*
import org.junit.Test
import java.net.URI
import java.net.URLDecoder
import java.util.concurrent.ConcurrentLinkedQueue
import org.vrpassthroughplayer.plugin.MediaServerClientTest.Fixture
import org.vrpassthroughplayer.plugin.MediaServerClientTest.Reply

class EmbyVersionsTest {
    private fun query(request: String): Map<String, String> = URI(request.split(' ')[1]).rawQuery.orEmpty()
        .split('&').filter { it.contains('=') }.associate {
            it.substringBefore('=') to URLDecoder.decode(it.substringAfter('='), "UTF-8")
        }
    private fun source(id: String, duration: Long = 600000000) = JSONObject()
        .put("Id", id).put("Name", id).put("Protocol", "File").put("SupportsDirectPlay", true)
        .put("Path", "/private/Film - $id.mp4").put("Size", 4096).put("RunTimeTicks", duration)
        .put("Video3DFormat", if (id == "2") "FullTopAndBottom" else "HalfSideBySide")
        .put("Chapters", JSONArray().put(JSONObject().put("Name", "Chapter $id").put("StartPositionTicks", 10000000)))
        .put("MediaStreams", JSONArray().put(JSONObject().put("Type", "Video").put("Width", if (id == "2") 3840 else 1920).put("Height", 1080))
            .put(JSONObject().put("Type", "Subtitle").put("IsExternal", true).put("Codec", "srt").put("Index", 3).put("DisplayTitle", "Subtitle $id")))
    private fun item(sources: JSONArray) = JSONObject().put("Id", "film").put("Name", "Film").put("Type", "Movie")
        .put("MediaSources", sources).put("UserData", JSONObject().put("PlaybackPositionTicks", 400000000))

    @Test fun detailExposesNamedVersionsWithIndependentMetadataAndLeavesSingleSourceUnchanged() {
        for (provider in listOf("emby", "jellyfin")) for (count in listOf(1, 2)) {
            val sources = JSONArray().put(source("1"))
            if (count == 2) sources.put(source("2", 900000000))
            Fixture { request, _, _ -> Reply(body = (if (request.contains("/Images")) "[]" else item(sources).toString()).toByteArray()) }.use { fixture ->
                val account = MediaServerAccount("test", "Test", fixture.url, "", provider, "user")
                MediaServerHttp(account).use { http ->
                    val detail = EmbyClient(account, http).detail("film")
                    assertEquals(count > 1, detail.has("versions"))
                    assertEquals("medialib://test/scene/film", detail.getString("uri"))
                    if (count == 2) {
                        val versions = detail.getJSONArray("versions").objects()
                        assertEquals(listOf("1", "2"), versions.map { it.getString("version_name") })
                        assertEquals("medialib://test/scene/film?source=2", versions[1].getString("uri"))
                        assertEquals(90000L, versions[1].getLong("duration_ms"))
                        assertEquals(3840, versions[1].getInt("width"))
                        assertEquals("FullTopAndBottom", versions[1].getString("video_3d_format"))
                        assertEquals("Chapter 2", versions[1].getJSONArray("markers").getJSONObject(0).getString("title"))
                        assertEquals(0L, versions[1].getLong("position_ms"))
                        assertTrue(versions[0].getBoolean("default_version"))
                        assertFalse(detail.toString().contains("/private/"))
                        assertFalse(detail.has("parts"))
                    }
                }
            }
        }
    }

    @Test fun explicitSelectionPinsPlaybackInfoFileSubtitlesAndRejectsMissingOrUnsupportedVersion() {
        val seen = ConcurrentLinkedQueue<Map<String, String>>()
        val sources = JSONArray().put(source("1")).put(source("2")).put(source("transcode").put("SupportsDirectPlay", false))
        Fixture { request, _, _ ->
            seen.add(query(request)); Reply(body = JSONObject().put("MediaSources", sources).toString().toByteArray())
        }.use { fixture ->
            for (provider in listOf("emby", "jellyfin")) {
                val account = MediaServerAccount("test", "Test", fixture.url, "", provider, "user")
                MediaServerHttp(account).use { http ->
                    val client = EmbyClient(account, http)
                    val selected = client.stream("film", "2")
                    assertEquals("2", query("GET ${selected.url} HTTP/1.1")["MediaSourceId"])
                    assertEquals("Film - 2.mp4", selected.basename)
                    assertEquals("/Videos/film/2/Subtitles/3/Stream.srt", selected.subtitles.single().url.path)
                    assertEquals("1", query("GET ${client.stream("film").url} HTTP/1.1")["MediaSourceId"])
                    for (id in listOf("missing", "transcode")) assertThrows(MediaServerFailure::class.java) { client.stream("film", id) }
                }
            }
        }
        assertEquals(listOf("2", null, "missing", "transcode", "2", null, "missing", "transcode"), seen.map { it["MediaSourceId"] })
    }

    @Test fun sourceIdentityIsCanonicalScopedAndKeepsLegacyUris() {
        val source = "source +/中文?&=1"
        val uri = MediaLibraryUri.scene("server", "film", source)
        assertEquals(Triple("server", "film", source), MediaLibraryUri.identity(uri))
        assertEquals("server" to "film", MediaLibraryUri.parse(uri))
        assertEquals(Triple("server", "film", ""), MediaLibraryUri.identity("medialib://server/scene/film"))
        assertNotEquals(uri, MediaLibraryUri.scene("other", "film", source))
        for (bad in listOf("?source=", "?source=1&token=secret", "?source=1&source=2", "?source=%0A", "?source=%", "?token=secret"))
            assertThrows(MediaServerFailure::class.java) { MediaLibraryUri.identity("medialib://server/scene/film$bad") }
    }

    @Test fun selectedIdentityReachesProxyAndCaptureReader() {
        val selected = ConcurrentLinkedQueue<String>()
        val payload = ByteArray(4096) { (it % 251).toByte() }
        Fixture { request, headers, _ ->
            if (request.contains("PlaybackInfo")) Reply(body = JSONObject().put("MediaSources", JSONArray().put(source("1")).put(source("2"))).toString().toByteArray())
            else {
                selected.add(query(request)["MediaSourceId"].orEmpty())
                val range = LocalStreamServer.parseRange(headers["range"], payload.size.toLong())!!
                Reply(206, "Content-Range: bytes ${range.first}-${range.second}/${payload.size}\r\n", payload.copyOfRange(range.first.toInt(), range.second.toInt() + 1))
            }
        }.use { fixture -> LocalStreamServer().use { local ->
            val account = MediaServerAccount("test", "Test", fixture.url, "", "emby", "user")
            val library = MediaServerLibrary({ null }, { local }, { 1 }, emit = { _, _ -> }, getAccount = { account })
            try {
                for (capture in listOf(false, true)) {
                    val url = library.playable(MediaLibraryUri.scene("test", "film", "2"), capture)
                    val connection = URI(url).toURL().openConnection() as java.net.HttpURLConnection
                    try {
                        connection.setRequestProperty("Range", "bytes=100-199")
                        assertArrayEquals(payload.copyOfRange(100, 200), connection.inputStream.use { it.readBytes() })
                    } finally { connection.disconnect(); library.release(url) }
                }
            } finally { library.close() }
        } }
        assertTrue(selected.isNotEmpty()); assertTrue(selected.all { it == "2" })
    }
}
