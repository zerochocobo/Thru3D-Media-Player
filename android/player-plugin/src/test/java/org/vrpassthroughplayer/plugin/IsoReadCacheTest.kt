package org.vrpassthroughplayer.plugin

import org.junit.Assert.*
import org.junit.Test
import java.io.IOException
import java.net.HttpURLConnection
import java.net.InetSocketAddress
import java.net.URL
import java.util.concurrent.CountDownLatch
import java.util.concurrent.TimeUnit
import java.util.concurrent.atomic.AtomicInteger

class IsoReadCacheTest {
    @Test fun smallCloudIsoReusesPreflightAcrossRealHttpClientsButOrdinaryVideoDoesNotOptIn() {
        val bytes = ByteArray(3 * 65536 + 7) { (it % 251).toByte() }
        val requests = AtomicInteger(); val resolutions = AtomicInteger()
        val origin = CloudStreamSourceTest.HttpServer.create(InetSocketAddress("127.0.0.1", 0), 0)
        origin.createContext("/file") { exchange ->
            requests.incrementAndGet()
            val start = exchange.requestHeaders.getFirst("Range")!!.removePrefix("bytes=").removeSuffix("-").toInt()
            exchange.responseHeaders.add("Content-Range", "bytes $start-${bytes.lastIndex}/${bytes.size}")
            exchange.sendResponseHeaders(206, (bytes.size - start).toLong())
            runCatching { exchange.responseBody.use { it.write(bytes, start, bytes.size - start) } }
            exchange.close()
        }
        origin.start()
        try {
            LocalStreamServer().use { local ->
                for (name in listOf("small.ISO", "ordinary.mp4", "ordinary.mkv")) {
                    val source = CloudStreamSource(bytes.size.toLong(), {
                        resolutions.incrementAndGet()
                        CloudLink("http://127.0.0.1:${origin.address.port}/file") { emptyMap() }
                    }, { it.toURL().openConnection() as HttpURLConnection })
                    val url = local.publish(source, name)
                    fun readAt(offset: Int, length: Int = 2048) {
                        val client = URL(url).openConnection() as HttpURLConnection
                        try {
                            client.setRequestProperty("Range", "bytes=$offset-${offset + length - 1}")
                            assertEquals(206, client.responseCode)
                            assertArrayEquals(bytes.copyOfRange(offset, offset + length), client.inputStream.readBytes())
                        } finally { client.disconnect() }
                    }
                    readAt(1000)
                    val before = requests.get(); val metered = local.progress(url)!!.bytes
                    local.finishIsoPreflight(url)
                    readAt(1000)
                    if (name.endsWith(".ISO")) {
                        assertEquals(before, requests.get())
                        assertEquals(metered, local.progress(url)!!.bytes)
                        readAt(bytes.size - 7, 7); readAt(1000)
                        assertEquals(1L, local.isoCacheStats(url)!!.getValue("protected_blocks"))
                    } else {
                        assertNull(local.isoCacheStats(url))
                        assertEquals(before + 1, requests.get())
                    }
                    local.revoke(url)
                    assertNull(local.isoCacheStats(url))
                }
                assertEquals(3, resolutions.get())
            }
        } finally { origin.stop(0) }
    }

    @Test fun incompleteIndexBlockIsNotPublishedAndANewReaderCanRetry() {
        val valid = Origin(); var calls = 0
        val faulty = object : StreamSource by valid {
            override fun open(): StreamSource.Reader {
                val reader = valid.open()
                return object : StreamSource.Reader by reader {
                    override fun read(offset: Long, buffer: ByteArray, length: Int): Int {
                        if (++calls == 2) throw IOException("interrupted response")
                        return reader.read(offset, buffer, length)
                    }
                }
            }
        }
        IsoReadCache(faulty).use { cache ->
            try { cache.open().use { verify(it, 5000000000L, 2048) }; fail("short origin") }
            catch (_: IOException) {}
            assertEquals(0L, cache.stats().getValue("metadata_bytes"))
            cache.open().use { verify(it, 5000000000L, 2048) }
            assertEquals(65536L, cache.stats().getValue("metadata_bytes"))
        }
    }

    private class Origin(override val size: Long = 16L * 1024 * 1024 * 1024) : StreamSource {
        val opens = AtomicInteger(); val reads = AtomicInteger(); val closes = AtomicInteger()
        @Volatile var closed = false
        override fun open(): StreamSource.Reader {
            opens.incrementAndGet()
            return object : StreamSource.Reader {
                var done = false
                override fun read(offset: Long, buffer: ByteArray, length: Int): Int {
                    check(!done && !closed); reads.incrementAndGet()
                    val n = minOf(length.toLong(), size - offset, 16384L).toInt()
                    for (i in 0 until n) buffer[i] = ((offset + i) % 251).toByte()
                    return n
                }
                override fun close() { if (!done) { closes.incrementAndGet(); done = true } }
            }
        }
        override fun close() { closed = true }
    }
    private fun verify(reader: StreamSource.Reader, offset: Long, length: Int) {
        val buffer = ByteArray(minOf(length, 65536)); var at = offset
        while (at < offset + length) {
            val n = reader.read(at, buffer, minOf(buffer.size.toLong(), offset + length - at).toInt())
            assertTrue(n > 0)
            for (i in 0 until n) assertEquals(((at + i) % 251).toByte(), buffer[i])
            at += n
        }
    }
    @Test fun preflightAndNewPlaybackReadersShareAllIndexBlocksIncludingCrossBlockReads() {
        val origin = Origin()
        IsoReadCache(origin).use { cache ->
            val offsets = (0 until 64).map { it * 1024L * 1024 + 65536 - 512 }
            offsets.forEach { offset -> cache.open().use { verify(it, offset, 2048) } }
            val before = origin.reads.get()
            assertEquals(8L * 1024 * 1024, cache.stats().getValue("metadata_bytes"))
            cache.finishPreflight(); cache.finishPreflight()
            offsets.reversed().forEach { offset -> cache.open().use { verify(it, offset, 2048) } }
            assertEquals(before, origin.reads.get())
            assertEquals(96L, cache.stats().getValue("protected_blocks"))
        }
        assertTrue(origin.closed); assertEquals(origin.opens.get(), origin.closes.get())
    }
    @Test fun continuousMediaCannotEvictProtectedIndexAndKeepsBoundedStorage() {
        val origin = Origin()
        IsoReadCache(origin).use { cache ->
            repeat(48) { i -> cache.open().use { verify(it, i * 1024L * 1024 + 65536 - 512, 2048) } }
            cache.finishPreflight()
            // More than the whole metadata cache in socket read-ahead. Only
            // landing blocks are admitted, with protected metadata preserved.
            cache.open().use { verify(it, 1024L * 1024 * 1024, 12 * 1024 * 1024) }
            repeat(80) { i -> cache.open().use { verify(it, (2L * 1024 + i) * 1024 * 1024, 131072) } }
            val before = origin.reads.get()
            repeat(48) { i -> cache.open().use { verify(it, i * 1024L * 1024 + 65536 - 512, 2048) } }
            assertEquals(before, origin.reads.get())
            assertTrue(cache.stats().getValue("metadata_bytes") <= 8L * 1024 * 1024)
            assertTrue(cache.stats().getValue("capacity_bytes") <= 16L * 1024 * 1024)
        }
    }
    @Test fun forwardBackwardAndTailReadsStayByteExactAndDoNotShareBetweenLeases() {
        val first = Origin(3 * 65536L + 7); val second = Origin(first.size)
        IsoReadCache(first).use { cache ->
            cache.open().use { verify(it, 0, first.size.toInt()) }
            cache.finishPreflight()
            cache.open().use { verify(it, 3 * 65536L, 7); verify(it, 65530, 64) }
            IsoReadCache(second).use { other ->
                other.open().use { verify(it, 0, 1024) }
                assertTrue(second.reads.get() > 0)
                assertEquals(0L, other.stats().getValue("playback_phase"))
            }
        }
    }
    @Test fun metadataHitsDoNotCountAsNewNetworkBytesAndNoWholeImageIsRead() {
        val origin = Origin(); var networkBytes = 0L
        IsoReadCache(origin) { networkBytes += it }.use { cache ->
            cache.open().use { verify(it, 5000000000L, 2048) }
            val before = networkBytes
            cache.finishPreflight()
            cache.open().use { verify(it, 5000000000L, 2048) }
            assertEquals(before, networkBytes)
            assertEquals(65536L, networkBytes)
        }
    }
    @Test fun revokeInterruptsPendingReadBeforeWaitingOnMetadataLock() {
        val entered = CountDownLatch(1); val cancelled = CountDownLatch(1); val finished = CountDownLatch(1)
        val cache = IsoReadCache(object : StreamSource {
            override val size = 1000000L
            override fun open() = object : StreamSource.Reader {
                override fun read(offset: Long, buffer: ByteArray, length: Int): Int {
                    entered.countDown(); assertTrue(cancelled.await(3, TimeUnit.SECONDS)); throw IOException("cancelled")
                }
                override fun close() {}
            }
            override fun close() { cancelled.countDown() }
        })
        val worker = Thread {
            try { cache.open().use { it.read(0, ByteArray(2048), 2048) }; fail("cancelled") }
            catch (_: IOException) {} finally { finished.countDown() }
        }.apply { start() }
        assertTrue(entered.await(2, TimeUnit.SECONDS)); cache.close()
        assertTrue(finished.await(1, TimeUnit.SECONDS)); worker.join(1000)
        assertEquals(0L, cache.stats().getValue("metadata_bytes"))
    }
}
