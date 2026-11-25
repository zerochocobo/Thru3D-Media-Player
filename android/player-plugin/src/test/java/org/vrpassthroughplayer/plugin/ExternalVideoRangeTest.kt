package org.vrpassthroughplayer.plugin

import java.net.HttpURLConnection
import java.net.URL
import java.util.concurrent.CopyOnWriteArrayList
import org.json.JSONObject
import org.junit.Assert.*
import org.junit.Test
import org.vrpassthroughplayer.plugin.MediaServerClientTest.Fixture
import org.vrpassthroughplayer.plugin.MediaServerClientTest.Reply

class ExternalVideoRangeTest {
    private val bytes = ByteArray(1100000) { ((it * 17 + it / 251) % 251).toByte() }

    private fun withVideo(origin: String, check: (String) -> Unit) {
        LocalStreamServer().use { local -> ExternalPlaybackStreams { local }.use { streams ->
            val request = ExternalPlaybackRequest.parse("android.intent.action.VIEW", "$origin/video", mime = "video/mp4")
            val id = JSONObject(streams.receive(request, 0)).getString("uri")
            val url = streams.playable(id)!!
            try { check(url) } finally { local.revoke(url) }
        } }
    }

    private fun readRange(url: String, start: Int, end: Int) {
        val c = URL(url).openConnection() as HttpURLConnection
        try {
            c.setRequestProperty("Range", "bytes=$start-$end")
            assertEquals(206, c.responseCode)
            assertEquals("bytes $start-$end/${bytes.size}", c.getHeaderField("Content-Range"))
            assertArrayEquals(bytes.copyOfRange(start, end + 1), c.inputStream.use { it.readBytes() })
        } finally { c.disconnect() }
    }

    @Test fun ignoredRangesReuseTheProbeAndContinueThenSeekInBothDirections() {
        val requests = CopyOnWriteArrayList<String>()
        Fixture { _, headers, _ ->
            requests.add(headers.getValue("range"))
            Reply(200, body = bytes)
        }.use { origin -> withVideo(origin.url) { url ->
            readRange(url, 0, 511)
            readRange(url, 512, 1023)
            assertEquals(listOf("bytes=0-0"), requests.toList())
            readRange(url, bytes.size - 64, bytes.size - 1)
            readRange(url, 128, 170)
        } }
    }

    @Test fun alignedStartAndOversizedEndDeliverOnlyTheRequestedBytes() {
        Fixture { _, headers, _ ->
            val start = LocalStreamServer.parseRange(headers.getValue("range"), bytes.size.toLong())!!.first.toInt()
            Reply(206, "Content-Range: bytes $start-${bytes.lastIndex}/${bytes.size}\r\n", bytes.copyOfRange(start, bytes.size))
        }.use { origin -> withVideo(origin.url) { url ->
            readRange(url, 0, 1048600) // crosses the 1 MiB upstream window
            readRange(url, bytes.size - 64, bytes.size - 1)
            readRange(url, 13, 43)
        } }
    }

    @Test fun anOriginIgnoringOnlyTheProbeCanStillServeANonzeroSeekByRange() {
        val requests = CopyOnWriteArrayList<String>()
        Fixture { _, headers, _ ->
            val range = headers.getValue("range")
            requests.add(range)
            if (range == "bytes=0-0") Reply(200, body = bytes)
            else {
                val (start, end) = LocalStreamServer.parseRange(range, bytes.size.toLong())!!
                Reply(206, "Content-Range: bytes $start-$end/${bytes.size}\r\n", bytes.copyOfRange(start.toInt(), end.toInt() + 1))
            }
        }.use { origin -> withVideo(origin.url) { url ->
            readRange(url, 0, 31)
            readRange(url, 900000, 900031)
            assertEquals(listOf("bytes=0-0", "bytes=900000-${bytes.lastIndex}"), requests.toList())
        } }
    }

    @Test fun invalidSuccessResponsesKeepTheirStatusAndSafeRangeEvidence() {
        for ((response, reason) in listOf(
            Reply(200, "Content-Type: text/html\r\n", "login".toByteArray()) to "not_media",
            Reply(200, "Content-Range: bytes 0-0/32\r\n", byteArrayOf(7)) to "invalid_range",
            Reply(206, "Content-Range: bytes 1-1/32\r\n", byteArrayOf(7)) to "invalid_range",
            Reply(206, "Content-Range: fixture-secret\r\n", byteArrayOf(7)) to "invalid_range"
        )) {
            Fixture { _, _, _ -> response }.use { origin ->
                val error = assertThrows(PlaybackFailureException::class.java) { withVideo(origin.url) { fail() } }.failure
                assertEquals(reason, error.reason)
                assertEquals(response.code, error.httpStatus)
                assertEquals("resolving", error.stage)
                assertFalse(error.detail.contains("fixture-secret"))
            }
        }
    }

    @Test fun chunkedWholeFileIsStreamedToEofWithoutAdvertisingSeekOrConsumingTheProbeOnHead() {
        val requests = CopyOnWriteArrayList<String>()
        val chunk = "${bytes.size.toString(16)}\r\n".toByteArray() + bytes + "\r\n0\r\n\r\n".toByteArray()
        Fixture { _, headers, _ ->
            requests.add(headers["range"] ?: "none")
            Reply(200, "Transfer-Encoding: chunked\r\n", chunk, declaredLength = null)
        }.use { origin ->
            withVideo(origin.url) { url ->
                for (method in listOf("HEAD", "GET")) {
                    val c = URL(url).openConnection() as HttpURLConnection
                    try {
                        c.requestMethod = method
                        c.setRequestProperty("Range", "bytes=0-")
                        assertEquals(200, c.responseCode)
                        assertEquals(-1L, c.contentLengthLong)
                        assertEquals("none", c.getHeaderField("Accept-Ranges"))
                        if (method == "GET") assertArrayEquals(bytes, c.inputStream.use { it.readBytes() })
                    } finally { c.disconnect() }
                }
                assertEquals(listOf("bytes=0-0"), requests.toList())
            }
        }
    }
}
