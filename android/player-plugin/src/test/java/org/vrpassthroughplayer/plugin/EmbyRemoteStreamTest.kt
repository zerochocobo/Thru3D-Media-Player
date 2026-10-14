package org.vrpassthroughplayer.plugin

import org.json.JSONArray
import org.json.JSONObject
import org.junit.Assert.*
import org.junit.Test
import java.net.URI
import java.util.concurrent.ConcurrentLinkedQueue
import org.vrpassthroughplayer.plugin.MediaServerClientTest.Fixture
import org.vrpassthroughplayer.plugin.MediaServerClientTest.Reply

class EmbyRemoteStreamTest {
    @Test fun embyAndJellyfinRemotePlaybackInfoStreamsOriginalRangesWithoutServerToken() {
        val bytes = ByteArray(4096) { (it % 251).toByte() }
        val seen = ConcurrentLinkedQueue<Map<String, String>>()
        Fixture { _, headers, _ ->
            seen.add(headers)
            val range = LocalStreamServer.parseRange(headers["range"], bytes.size.toLong())!!
            Reply(206, "Content-Type: video/mp4\r\nContent-Range: bytes ${range.first}-${range.second}/${bytes.size}\r\n", bytes.copyOfRange(range.first.toInt(), range.second.toInt() + 1))
        }.use { media ->
            for (provider in listOf("emby", "jellyfin")) {
                val remote = JSONObject().put("Id", "remote-source").put("Protocol", "Http").put("IsRemote", true)
                    .put("Size", 0).put("SupportsDirectPlay", true).put("Path", media.url + "/film_SBS.mp4?signature=private")
                    .put("RequiredHttpHeaders", JSONObject().put("X-Media-Key", "upstream-key"))
                Fixture { request, _, _ ->
                    val data = if (request.contains("PlaybackInfo")) JSONObject().put("MediaSources", JSONArray().put(remote))
                    else JSONObject().put("Id", "1").put("Name", "Film").put("MediaSources", JSONArray().put(remote))
                    Reply(body = data.toString().toByteArray())
                }.use { metadata -> LocalStreamServer().use { local ->
                    val account = MediaServerAccount("fixture", "Test", metadata.url, "private-server-token", provider, "user1")
                    val library = MediaServerLibrary({ null }, { local }, { 1 }, emit = { _, _ -> }, getAccount = { account })
                    try {
                        val url = library.playable(MediaLibraryUri.scene(account.id, "1"))
                        assertTrue(url.endsWith("/video")); assertFalse(url.contains("private"))
                        val c = URI(url).toURL().openConnection() as java.net.HttpURLConnection
                        try {
                            c.setRequestProperty("Range", "bytes=1024-1535")
                            assertArrayEquals(bytes.copyOfRange(1024, 1536), c.inputStream.use { it.readBytes() })
                        } finally { c.disconnect() }
                        MediaServerHttp(account).use { http ->
                            val detail = EmbyClient(account, http).detail("1")
                            assertEquals("film_SBS.mp4", detail.getString("basename"))
                        }
                    } finally { library.close() }
                } }
            }
        }
        assertTrue(seen.size >= 4)
        seen.forEach { headers ->
            assertEquals("upstream-key", headers["x-media-key"])
            assertFalse(headers.values.any { it.contains("private-server-token") })
        }
    }
    @Test fun crossOriginRedirectStripsRequiredCredentials() {
        val seen = ConcurrentLinkedQueue<Map<String, String>>()
        Fixture { _, headers, _ -> seen.add(headers); Reply(206, "Content-Range: bytes 0-0/1\r\n", byteArrayOf(7)) }.use { target ->
            Fixture { _, _, _ -> Reply(302, "Location: ${target.url}/media\r\n", byteArrayOf()) }.use { origin ->
                RemoteMediaHttp().use { http ->
                    val c = http.open(URI(origin.url), "bytes=0-0", mapOf("Authorization" to "Bearer upstream", "Cookie" to "private", "User-Agent" to "Media Player", "X-Custom-Key" to "private"))
                    try { assertEquals(7, c.inputStream.read()) } finally { http.release(c) }
                }
            }
        }
        assertEquals(1, seen.size)
        assertFalse(seen.first().containsKey("authorization")); assertFalse(seen.first().containsKey("cookie"))
        assertFalse(seen.first().containsKey("x-custom-key")); assertEquals("Media Player", seen.first()["user-agent"])
        assertEquals("bytes=0-0", seen.first()["range"])
    }
    @Test fun rejectsInvalidHeadersAndShowsRemoteHttpFailureWithoutResponseBody() {
        Fixture { _, _, _ -> Reply(403, body = "private-server-message".toByteArray()) }.use { fixture ->
            RemoteMediaHttp().use { http ->
                val denied = assertThrows(MediaServerFailure::class.java) { http.open(URI(fixture.url), "bytes=0-0", emptyMap()) }
                assertEquals("Remote media access denied", denied.code); assertEquals(403, denied.httpStatus)
                assertFalse(denied.message.orEmpty().contains("private"))
                assertEquals("Invalid remote media headers", assertThrows(MediaServerFailure::class.java) {
                    http.open(URI(fixture.url), "bytes=0-0", mapOf("X-Test" to "bad\r\ninjected"))
                }.code)
            }
        }
    }
}
