package org.vrpassthroughplayer.plugin

import org.junit.Assert.*
import org.junit.Test
import java.net.HttpURLConnection
import java.net.InetSocketAddress
import java.net.URL
import java.util.concurrent.atomic.AtomicInteger

class Mp4AudioPacketCacheTest {
    private fun bytes(at: Long, count: Int) = ByteArray(count) { ((at + it) % 251).toByte() }

    @Test fun indexedAudioGapsKeepVideoOnTheSameOriginConnection() {
        fun opens(spans: List<AudioReadSpan>, next: Long): Int {
            val connections = AtomicInteger()
            val origin = object : StreamSource {
                override val size = 1000000L
                override fun open(): StreamSource.Reader {
                    connections.incrementAndGet()
                    return object : StreamSource.Reader {
                        var position = -1L
                        override fun read(offset: Long, buffer: ByteArray, length: Int): Int {
                            if (position >= 0) assertEquals("Retain sequential upstream reads", position, offset)
                            bytes(offset, length).copyInto(buffer); position = offset + length; return length
                        }
                        override fun close() {}
                    }
                }
            }
            InterleaveReadCache(origin, 65536, audioChunks = spans).use { cache ->
                val buffer = ByteArray(1024)
                cache.open().use { assertEquals(1024, it.read(0, buffer, 1024)) }
                cache.open().use { assertEquals(1024, it.read(next, buffer, 1024)) }
                assertArrayEquals(bytes(next, 1024), buffer)
                if (connections.get() == 1) {
                    assertEquals(next + 1024, cache.stats().getValue("upstream_bytes"))
                    val before = cache.stats().getValue("upstream_bytes")
                    cache.open().use { reader ->
                        var total = 0
                        while (total < 6) {
                            val part = ByteArray(6 - total)
                            val count = reader.read(1024L + total, part, part.size)
                            assertTrue(count > 0)
                            part.copyInto(buffer, total, 0, count); total += count
                        }
                    }
                    assertArrayEquals(bytes(1024, 6), buffer.copyOf(6))
                    assertEquals(before, cache.stats().getValue("upstream_bytes"))
                }
            }
            return connections.get()
        }
        assertEquals(1, opens(listOf(AudioReadSpan(1024, 1030)), 1030))
        assertEquals(1, opens(listOf(AudioReadSpan(1024, 1027), AudioReadSpan(1027, 1030)), 1030))
        assertEquals(2, opens(emptyList(), 1030)) // ISO/ordinary transport behavior stays unchanged.
        assertEquals(1, opens(listOf(AudioReadSpan(1024, 1029)), 1030)) // Read actual intervening video too.
        assertEquals(2, opens(listOf(AudioReadSpan(1024, 70000)), 70000)) // Bound speculative gap reads.
    }

    @Test fun partialAndDisjointObservationsNeverReturnUnfilledBytes() {
        val cache = Mp4AudioPacketCache(listOf(AudioReadSpan(1000, 2000)))
        cache.capture(1000, bytes(1000, 100), 100)
        assertEquals(1100L, cache.end(1050))
        assertNull(cache.end(1100))
        cache.capture(1500, bytes(1500, 100), 100)
        assertNull(cache.end(1050))
        assertNull(cache.end(1400))
        cache.capture(1200, bytes(1200, 400), 400)
        assertEquals(1600L, cache.end(1200))
        val out = ByteArray(1000)
        assertEquals(400, cache.read(1200, out, out.size))
        assertArrayEquals(bytes(1200, 400), out.copyOf(400))
        cache.capture(1000, bytes(1000, 1000), 1000)
        assertEquals(2000L, cache.end(1000))
        assertEquals(1000, cache.read(1000, out, out.size))
        assertArrayEquals(bytes(1000, 1000), out)
    }

    @Test fun cacheBudgetEvictionLargeChunksAndCloseStayBounded() {
        val spans = listOf(AudioReadSpan(0, 32768), AudioReadSpan(65536, 98304), AudioReadSpan(131072, 163840),
            AudioReadSpan(200000, 400000))
        val cache = Mp4AudioPacketCache(spans, 65536)
        spans.take(3).forEach { cache.capture(it.start, bytes(it.start, 32768), 32768) }
        assertEquals(65536L, cache.sizeBytes())
        assertNull(cache.end(0))
        assertEquals(163840L, cache.end(131072))
        cache.capture(200000, bytes(200000, 65536), 65536)
        assertEquals(65536L, cache.sizeBytes())
        assertNull(cache.end(200000))
        cache.close(); assertEquals(0L, cache.sizeBytes()); assertNull(cache.end(131072))
    }
    @Test fun manyTinyChunksCannotGrowEntryOverheadWithoutBound() {
        val cache = Mp4AudioPacketCache((0L..8L).map { AudioReadSpan(it, it + 1) }, budget = 64, maxEntries = 4)
        cache.capture(0, bytes(0, 9), 9)
        assertEquals(4L, cache.sizeBytes())
        assertNull(cache.end(0)); assertEquals(9L, cache.end(8))
    }

    @Test fun audioSurvivesVideoReadaheadThatEvictsBothPhysicalWindowsWithoutExtraOriginIo() {
        val reads = AtomicInteger(); var metered = 0L
        val origin = object : StreamSource {
            override val size = 8L * 1024 * 1024 * 1024
            override fun open() = object : StreamSource.Reader {
                override fun read(offset: Long, buffer: ByteArray, length: Int): Int {
                    reads.incrementAndGet(); bytes(offset, length).copyInto(buffer); return length
                }
                override fun close() {}
            }
        }
        InterleaveReadCache(origin, 65536, { metered += it }, listOf(AudioReadSpan(1000, 3000))).use { cache ->
            val buffer = ByteArray(65536)
            cache.open().use { it.read(0, buffer, buffer.size) }
            for (start in listOf(10000000L, 20000000L)) cache.open().use { reader ->
                repeat(4) { reader.read(start + it * 65536, buffer, buffer.size) }
            }
            val before = reads.get(); val bytesBefore = metered
            cache.open().use { assertEquals(2000, it.read(1000, buffer, buffer.size)) }
            assertArrayEquals(bytes(1000, 2000), buffer.copyOf(2000))
            assertEquals(before, reads.get()); assertEquals(bytesBefore, metered)
            assertEquals(2000L, cache.stats().getValue("audio_payload_bytes"))
            assertEquals(2000L, cache.stats().getValue("audio_cached_bytes"))
        }
    }

    @Test fun ongoingVideoConsumesAudioOnItsExistingConnectionInsteadOfOpeningAgainAfterIt() {
        val opens = AtomicInteger()
        val origin = object : StreamSource {
            override val size = 1000000L
            override fun open(): StreamSource.Reader {
                opens.incrementAndGet()
                return object : StreamSource.Reader {
                    override fun read(offset: Long, buffer: ByteArray, length: Int): Int {
                        bytes(offset, length).copyInto(buffer); return length
                    }
                    override fun close() {}
                }
            }
        }
        InterleaveReadCache(origin, 65536, audioChunks = listOf(AudioReadSpan(65536, 67584))).use { cache ->
            val buffer = ByteArray(65536)
            cache.open().use { it.read(65536, buffer, 2048) }
            cache.open().use { reader ->
                reader.read(0, buffer, 65536)
                assertEquals(2048, reader.read(65536, buffer, 2048))
                reader.read(67584, buffer, 65536)
            }
            // Seed audio is one connection, continuous video is one connection.
            assertEquals(2, opens.get())
        }
    }

    @Test fun cachedAudioShortRangeDoesNotFetchFollowingVideoAndFullGetIsNeverTruncated() {
        val data = bytes(0, 512 * 1024); val requests = AtomicInteger()
        val origin = CloudStreamSourceTest.HttpServer.create(InetSocketAddress("127.0.0.1", 0), 0)
        origin.createContext("/file") { exchange ->
            requests.incrementAndGet()
            val start = exchange.requestHeaders.getFirst("Range")!!.removePrefix("bytes=").removeSuffix("-").toInt()
            exchange.responseHeaders.add("Content-Range", "bytes $start-${data.lastIndex}/${data.size}")
            exchange.sendResponseHeaders(206, (data.size - start).toLong())
            runCatching { exchange.responseBody.use { it.write(data, start, data.size - start) } }; exchange.close()
        }
        origin.start()
        try {
            LocalStreamServer().use { local ->
                val source = CloudStreamSource(data.size.toLong(), {
                    CloudLink("http://127.0.0.1:${origin.address.port}/file") { emptyMap() }
                }, { it.toURL().openConnection() as HttpURLConnection })
                val url = local.publish(source, "test.mp4")
                assertTrue(local.enableInterleaveCache(url, listOf(AudioReadSpan(0, 2048))))
                fun request(range: String?, expected: ByteArray, contentRange: String? = null) {
                    val client = URL(url).openConnection() as HttpURLConnection
                    try {
                        range?.let { client.setRequestProperty("Range", it) }
                        assertEquals(if (range == null) 200 else 206, client.responseCode)
                        assertEquals(contentRange, client.getHeaderField("Content-Range"))
                        assertEquals(expected.size.toLong(), client.contentLengthLong)
                        assertArrayEquals(expected, client.inputStream.readBytes())
                    } finally { client.disconnect() }
                }
                request("bytes=0-${data.lastIndex}", data, "bytes 0-${data.lastIndex}/${data.size}")
                val before = requests.get(); val metered = local.progress(url)!!.bytes
                request("bytes=0-33554431", data.copyOf(2048), "bytes 0-2047/${data.size}")
                assertEquals(before, requests.get()); assertEquals(metered, local.progress(url)!!.bytes)
                request("bytes=0-", data, "bytes 0-${data.lastIndex}/${data.size}")
                request(null, data)
            }
        } finally { origin.stop(0) }
    }
}
