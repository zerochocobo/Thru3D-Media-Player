package org.vrpassthroughplayer.plugin

import java.net.HttpURLConnection
import java.net.URI
import java.nio.ByteBuffer
import org.junit.Assert.*
import org.junit.Test
import org.vrpassthroughplayer.plugin.MediaServerClientTest.Fixture
import org.vrpassthroughplayer.plugin.MediaServerClientTest.Reply

class WebVideoLiveHlsTest {
    private fun words(vararg fields: Int) = ByteBuffer.allocate(fields.size * 4).apply {
        fields.forEach { putInt(it) }
    }.array()

    private fun box(type: String, vararg parts: ByteArray): ByteArray =
        words(8 + parts.sumOf { it.size }) + type.toByteArray() + parts.fold(byteArrayOf()) { a, b -> a + b }

    @Test fun firstPlaylistStartsAtAVerifiedSyncFragmentAndThenResumesTheSlidingWindow() {
        val init = box("moov", box("trak", box("tkhd", words(0, 0, 0, 1)),
            box("mdia", box("hdlr", words(0, 0), "vide".toByteArray()))))
        fun fragment(sync: Boolean) = box("moof", box("traf", box("tfhd", words(0, 1)),
            box("trun", words(4, 1, if (sync) 0x02000000 else 0x01010000))))

        var clock = 0L
        var phase = 0
        Fixture { request, _, _ ->
            val path = request.split(' ')[1]
            val bytes = when {
                path == "/live.m3u8" -> (if (++phase == 1) playlist(12, 12, 13, 14, 15, 16, 17)
                    else playlist(13, 13, 14, 15, 16, 17, 18)).toByteArray()
                path.startsWith("/init.mp4") -> init
                else -> fragment(path.startsWith("/13.m4s"))
            }
            Reply(200, body = bytes)
        }.use { origin -> LocalStreamServer().use { server ->
            WebVideoLiveHls(server, URI(origin.url + "/live.m3u8"), emptyMap(), { emptyMap() },
                { clock }, {}).use { live ->
                val url = live.prepare()
                clock = 1200
                val first = read(url)
                assertEquals(1, phase)
                assertTrue(first.contains("#EXT-X-MEDIA-SEQUENCE:13"))
                val firstUris = first.lines().filter { it.startsWith("http") }
                assertEquals(3, firstUris.size)
                assertArrayEquals(fragment(true), URI(firstUris.first()).toURL().openStream().use { it.readBytes() })
                val next = read(url)
                assertEquals(2, phase)
                assertTrue(next.contains("#EXT-X-MEDIA-SEQUENCE:13"))
                val nextUris = next.lines().filter { it.startsWith("http") }
                assertEquals(firstUris, nextUris.take(3))
                assertEquals(6, nextUris.size)
            }
        } }
    }

    private fun playlist(sequence: Int, vararg segments: Int): String = buildString {
        append("#EXTM3U\n#EXT-X-VERSION:7\n#EXT-X-MEDIA-SEQUENCE:$sequence\n#EXT-X-TARGETDURATION:1\n")
        append("#EXT-X-MAP:URI=\"init.mp4?sig=exact-init\"\n#EXT-BILI-AUX:opaque\n")
        segments.forEach { append("#EXTINF:1.000,\n$it.m4s?sig=exact-$it\n") }
    }

    @Test fun reloadsARealSlidingWindowThroughOneRevocableLocalUrl() {
        var clock = 0L
        var requests = 0
        Fixture { request, headers, _ ->
            val path = request.split(' ')[1]
            if (path == "/live.m3u8?sig=playlist") {
                assertEquals("playlist", headers["authorization"])
                val body = if (++requests == 1) playlist(12, 12, 13, 14) else playlist(13, 13, 14, 15, 16)
                Reply(200, body = body.toByteArray())
            } else {
                assertNull(headers["authorization"])
                assertEquals(path, headers["x-resource"])
                Reply(200, body = "abcdef".toByteArray())
            }
        }.use { origin -> LocalStreamServer().use { server ->
            val live = WebVideoLiveHls(server, URI(origin.url + "/live.m3u8?sig=playlist"), mapOf("authorization" to "playlist"),
                { uri -> mapOf("x-resource" to "${uri.rawPath}?${uri.rawQuery}") }, { clock },
                { assertEquals("abcdef", it.decodeToString()) })
            live.use {
                val url = live.prepare()
                val first = read(url)
                val fragments = first.lines().filter { it.startsWith("http") }
                assertEquals(3, fragments.size)
                assertEquals(1, requests)
                assertFalse(first.contains("sig="))
                clock = 1_100
                val next = read(url)
                assertTrue(next.contains("#EXT-X-MEDIA-SEQUENCE:13"))
                assertEquals(fragments[1], next.lines().first { it.startsWith("http") })
                assertEquals(2, requests)
                val range = URI(fragments[1]).toURL().openConnection() as HttpURLConnection
                try {
                    range.setRequestProperty("Range", "bytes=1-3")
                    assertEquals(206, range.responseCode)
                    assertEquals("bytes 1-3/6", range.getHeaderField("Content-Range"))
                    assertEquals("bcd", range.inputStream.use { it.readBytes().decodeToString() })
                } finally { range.disconnect() }
                live.close()
                assertFalse(server.hasSource(url))
                assertFalse(server.hasSource(fragments[1]))
            }
        } }
    }

    @Test fun rejectsProtectedAndUnscopedOrNonRollingManifests() {
        val base = URI("https://example.test/live.m3u8?sig=original")
        val good = playlist(12, 12, 13)
        assertEquals("https://example.test/12.m4s?sig=exact-12", WebVideoLivePlaylist.parse(base, good.toByteArray()).segments.first().uri.toString())
        val bad = listOf(good + "#EXT-X-ENDLIST\n", good.replace("12.m4s", "https://other.test/12.m4s"),
            good.replace("#EXTINF:1.000,", "#EXT-X-KEY:METHOD=AES-128,URI=\"key\"\n#EXTINF:1.000,"),
            good.replace("#EXT-X-TARGETDURATION:1", "#EXT-X-TARGETDURATION:0"),
            good.replace("#EXT-X-MAP:URI=", "#EXT-X-MAP:BYTERANGE=\"3@0\",URI="))
        for (text in bad) assertThrows(Exception::class.java) { WebVideoLivePlaylist.parse(base, text.toByteArray()) }
        val master = "#EXTM3U\n#EXT-X-VERSION:7\n#EXT-X-STREAM-INF:BANDWIDTH=500000\nselected.m3u8?key=one\n"
        assertEquals(URI("https://example.test/selected.m3u8?key=one"), WebVideoLivePlaylist.singleRendition(base, master.toByteArray()))
        assertThrows(IllegalArgumentException::class.java) {
            WebVideoLivePlaylist.singleRendition(base, (master + "#EXT-X-STREAM-INF:BANDWIDTH=1\nother.m3u8\n").toByteArray())
        }
    }

    @Test fun rejectsReplacedSequenceWithoutPublishingNewSegmentTokens() {
        var clock = 0L
        var requests = 0
        Fixture { request, _, _ ->
            val path = request.split(' ')[1]
            val bytes = if (path == "/live.m3u8") {
                if (++requests == 1) playlist(12, 12, 13, 14).toByteArray()
                else playlist(13, 19, 14, 15).toByteArray()
            } else byteArrayOf(1, 2, 3)
            Reply(200, body = bytes)
        }.use { origin -> LocalStreamServer().use { server ->
            WebVideoLiveHls(server, URI(origin.url + "/live.m3u8"), emptyMap(), { emptyMap() }, { clock }, {}).use { live ->
                val url = live.prepare()
                val first = read(url)
                val fragment = first.lines().first { it.startsWith("http") }
                clock = 1_100
                val failed = URI(url).toURL().openConnection() as HttpURLConnection
                try { assertEquals(502, failed.responseCode) } finally { failed.disconnect() }
                assertEquals("Live rendition changed", live.refreshError())
                assertEquals(1 to 0L, live.progress())
                assertTrue(server.hasSource(fragment))
            }
        } }
    }

    private fun read(url: String) = URI(url).toURL().openStream().use { it.readBytes().decodeToString() }
}
