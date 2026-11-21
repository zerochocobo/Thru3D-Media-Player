package org.vrpassthroughplayer.plugin

import org.json.JSONObject
import org.junit.Assert.*
import org.junit.Test
import java.net.URI
import java.util.concurrent.CountDownLatch
import java.util.concurrent.TimeUnit

class LocalThumbnailPrefetchTest {
    private val request = """{"uri":"file:///fixture/movie.mp4","kind":"video","sample_limit":999}"""

    @Test fun knownBoundsLimitPanoramaAndLargeImagesBeforeBitmapAllocation() {
        assertEquals(64, LocalThumbnailPrefetch.sampleSize(32768, 1024))
        assertEquals(16, LocalThumbnailPrefetch.sampleSize(7680, 4320))
        assertEquals(1, LocalThumbnailPrefetch.sampleSize(320, 180))
        assertNull(LocalThumbnailPrefetch.sampleSize(8192, 8192))
        assertNull(LocalThumbnailPrefetch.sampleSize(-1, -1))
    }

    @Test fun dlnaReadsOnlyMatchingPartialResponsesAndDeclinesFullFiles() {
        MediaServerClientTest.Fixture { _, headers, _ ->
            when (headers["range"]) {
                "bytes=0-0" -> MediaServerClientTest.Reply(206, "Content-Range: bytes 0-0/100\r\n", byteArrayOf(42))
                "bytes=10-12" -> MediaServerClientTest.Reply(206, "Content-Range: bytes 10-12/100\r\n", byteArrayOf(1, 2, 3))
                else -> MediaServerClientTest.Reply(body = ByteArray(100))
            }
        }.use { host ->
            DlnaThumbnailReader(URI("${host.url}/media")).use { reader ->
                reader.probe()
                assertEquals(100L, reader.size)
                assertEquals(206, reader.httpStatus)
                val buffer = ByteArray(3)
                assertEquals(3, reader.read(10, buffer, buffer.size))
                assertArrayEquals(byteArrayOf(1, 2, 3), buffer)
                assertEquals(-1, reader.read(20, buffer, buffer.size))
                assertEquals(200, reader.httpStatus)
            }
        }
    }

    @Test fun dlnaCanSampleOneSequentialResponseFromServersWithoutByteRanges() {
        val requests = java.util.concurrent.atomic.AtomicInteger()
        MediaServerClientTest.Fixture { _, _, _ ->
            requests.incrementAndGet()
            MediaServerClientTest.Reply(body = byteArrayOf(1, 2, 3, 4, 5, 6))
        }.use { host ->
            DlnaThumbnailReader(URI("${host.url}/stream")).use { reader ->
                reader.probe()
                assertTrue(reader.sequential)
                assertEquals(6L, reader.size)
                val sample = ByteArray(2)
                assertEquals(2, reader.read(0, sample, sample.size))
                assertArrayEquals(byteArrayOf(1, 2), sample)
                assertEquals(-1, reader.read(0, sample, sample.size))
                assertEquals(2, reader.read(2, sample, sample.size))
                assertArrayEquals(byteArrayOf(3, 4), sample)
                assertEquals(1, requests.get())
            }
        }
    }

    private fun waitFor(worker: LocalThumbnailPrefetch, id: Int, expected: String) {
        val deadline = System.nanoTime() + TimeUnit.SECONDS.toNanos(3)
        while (System.nanoTime() < deadline) {
            if (JSONObject(worker.state(id)).getString("state") == expected) return
            Thread.sleep(5)
        }
        fail("Expected $expected but received ${worker.state(id)}")
    }

    @Test fun timedOutReaderKeepsTheSlotUntilPhysicalExit() {
        val started = CountDownLatch(1)
        val exit = CountDownLatch(1)
        LocalThumbnailPrefetch({ null }, deadlineMs = 40) { work ->
            started.countDown()
            exit.await(2, TimeUnit.SECONDS)
            work.sampled = work.request.directoryLimit
            LocalThumbnailPrefetch.Result(byteArrayOf(1, 2, 3), work.request.uri)
        }.use { worker ->
            try {
                val id = worker.request(request)
                assertTrue(id > 0 && started.await(1, TimeUnit.SECONDS))
                waitFor(worker, id, "cancelling")
                repeat(100) {
                    assertEquals(-1, worker.request(request))
                    assertEquals(0, worker.take(id).size)
                }
                exit.countDown()
                waitFor(worker, id, "cancelled")
                assertEquals(32, JSONObject(worker.state(id)).getInt("sampled"))
                assertEquals(0, worker.take(id).size)
                assertTrue(worker.request(request) > id)
            } finally { exit.countDown() }
        }
    }

    @Test fun cancellingAReadyResultDiscardsItAndUnblocksTheNextRequest() {
        LocalThumbnailPrefetch({ null }) { work ->
            LocalThumbnailPrefetch.Result(byteArrayOf(1, 2, 3), work.request.uri)
        }.use { worker ->
            val id = worker.request(request)
            waitFor(worker, id, "ready")
            worker.cancel(id)
            waitFor(worker, id, "cancelled")
            assertEquals(0, worker.take(id).size)
            val next = worker.request(request)
            assertTrue(next > id)
            waitFor(worker, next, "ready")
            assertArrayEquals(byteArrayOf(1, 2, 3), worker.take(next))
        }
    }

    @Test fun diagnosticsDescribeTheAttemptWithoutResourceIdentifiersAndFollowPrivacy() {
        val previousMode = PlaybackPrivacy.mode
        val previousProtected = PlaybackPrivacy.protectedFavorites
        try {
            PlaybackPrivacy.mode = "all"
            PlaybackPrivacy.protectedFavorites = false
            LocalThumbnailPrefetch({ null }) { work ->
                work.stage = "video_decode"
                work.container = "mpegts"
                work.codec = "h264"
                work.mediaBytes = 120_000
                work.miss("no_frame")
            }.use { worker ->
                val id = worker.request("""{"uri":"smb://nas/private/movie.ts","kind":"video","resource":"https://server/secret?token=secret"}""")
                waitFor(worker, id, "missing")
                val detail = JSONObject(worker.state(id)).getJSONObject("diagnostic")
                assertEquals("no_frame", detail.getString("reason"))
                assertEquals("mpegts", detail.getString("container"))
                assertEquals(120_000L, detail.getLong("media_bytes"))
                assertFalse(detail.toString().contains("secret") || detail.toString().contains("nas"))
                PlaybackPrivacy.mode = "none"
                assertFalse(JSONObject(worker.state(id)).has("diagnostic"))
                PlaybackPrivacy.mode = "all"
                PlaybackPrivacy.protectedFavorites = true
                assertFalse(JSONObject(worker.state(id)).has("diagnostic"))
            }
        } finally {
            PlaybackPrivacy.mode = previousMode
            PlaybackPrivacy.protectedFavorites = previousProtected
        }
    }
}
