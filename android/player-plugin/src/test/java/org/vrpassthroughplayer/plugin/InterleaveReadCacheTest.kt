package org.vrpassthroughplayer.plugin

import org.junit.Assert.*
import org.junit.Test
import java.io.IOException
import java.util.concurrent.CountDownLatch
import java.util.concurrent.TimeUnit
import java.util.concurrent.atomic.AtomicInteger

class InterleaveReadCacheTest {
    private class Origin : StreamSource {
        override val size = 8L * 1024 * 1024 * 1024
        val opens = AtomicInteger(); val closes = AtomicInteger(); val reads = AtomicInteger()
        @Volatile var closed = false
        override fun open(): StreamSource.Reader {
            check(!closed); opens.incrementAndGet()
            return object : StreamSource.Reader {
                var done = false
                override fun read(offset: Long, buffer: ByteArray, length: Int): Int {
                    check(!closed && !done); reads.incrementAndGet()
                    for (i in 0 until length) buffer[i] = ((offset + i) % 251).toByte()
                    return length
                }
                override fun close() { if (!done) { done = true; closes.incrementAndGet() } }
            }
        }
        override fun close() { closed = true }
    }
    private fun verify(reader: StreamSource.Reader, offset: Long, count: Int) {
        val buffer = ByteArray(count)
        var at = offset
        while (at < offset + count) {
            val n = reader.read(at, buffer, minOf(count.toLong(), offset + count - at).toInt())
            assertTrue(n > 0)
            for (i in 0 until n) assertEquals(((at + i) % 251).toByte(), buffer[i])
            at += n
        }
    }
    @Test fun ordinarySourcesDelegateWithoutCacheOrPersistentReaders() {
        val origin = Origin()
        AdaptiveInterleaveSource(origin).use { source ->
            repeat(4) { i -> source.open().use { verify(it, i * 100000000L, 1024) } }
            assertNull(source.stats())
            assertEquals(4, origin.opens.get()); assertEquals(4, origin.closes.get())
        }
        assertTrue(origin.closed)
    }
    @Test fun alternatingTransientAudioVideoClientsReuseBothUpstreamsAndReadAhead() {
        val origin = Origin()
        InterleaveReadCache(origin, 1024 * 1024).use { source ->
            repeat(40) { i ->
                for (base in listOf(20_000_000L, 1_000_000_000L)) source.open().use {
                    verify(it, base + i * 8192L, 256 * 1024)
                }
            }
            assertEquals(2, origin.opens.get())
            assertEquals(0, origin.closes.get())
            assertTrue(source.stats().getValue("cached_bytes") > 19_000_000)
            assertEquals(2L * 1024 * 1024, source.stats().getValue("capacity_bytes"))
        }
        assertEquals(2, origin.closes.get()); assertTrue(origin.closed)
    }
    @Test fun wrapEvictionAndBackwardOrForwardSeeksKeepExactBytesAndBoundedStorage() {
        val origin = Origin()
        InterleaveReadCache(origin, 65536).use { source ->
            source.open().use { verify(it, 4_500_000_123L, 180000) }
            source.open().use { verify(it, 4_500_000_123L + 150000, 10000) }
            source.open().use { verify(it, 19L, 80000) }
            source.open().use { verify(it, 7_000_000_123L, 100000) }
            source.open().use { verify(it, 4_500_000_123L, 10000) }
            assertEquals(2L * 65536, source.stats().getValue("capacity_bytes"))
            assertTrue(origin.closes.get() >= 2)
        }
        assertEquals(origin.opens.get(), origin.closes.get())
    }
    @Test fun clientCloseDoesNotInvalidateAnotherClientAndActivationIsPerSource() {
        val origin = Origin(); val other = Origin()
        AdaptiveInterleaveSource(origin).use { source ->
            AdaptiveInterleaveSource(other).use { normal ->
                source.open().use { verify(it, 0, 16) }
                assertTrue(source.enable()); assertTrue(source.enable())
                val first = source.open(); val second = source.open()
                verify(first, 90000000, 100); first.close()
                try { first.read(0, ByteArray(1), 1); fail("closed client") } catch (_: IOException) {}
                verify(second, 90000050, 50); second.close()
                assertNotNull(source.stats()); assertNull(normal.stats())
                normal.open().use { verify(it, 0, 16) }
            }
        }
        assertEquals(other.opens.get(), other.closes.get())
    }
    @Test fun cacheHitsDoNotInflateOriginTransferMeter() {
        val meter = TransferMeter()
        AdaptiveInterleaveSource(Origin(), meter).use { source ->
            source.enable()
            source.open().use { verify(it, 1000000, 1024) }
            source.open().use { verify(it, 1000000, 1024) }
            assertEquals(1024L, meter.snapshot().bytes)
            assertEquals(1024L, source.stats()!!.getValue("cached_bytes"))
        }
    }
    @Test fun playbackViewGapLimitAvoidsDownloadingLargeSkippedRegions() {
        for (limit in listOf(1024, 65536)) {
            val origin = Origin()
            InterleaveReadCache(origin, 65536, audioChunks = listOf(AudioReadSpan(0, 100)), maxForwardGapBytes = limit).use { source ->
                source.open().use { verify(it, 1_000_000, 100) }
                source.open().use { verify(it, 1_030_000, 100) }
                assertEquals(if (limit == 1024) 200L else 30100L, source.stats().getValue("upstream_bytes"))
            }
        }
    }
    @Test fun sourceCloseUnblocksPendingReadBeforeAcquiringCacheLock() {
        val entered = CountDownLatch(1); val cancelled = CountDownLatch(1); val finished = CountDownLatch(1)
        val source = InterleaveReadCache(object : StreamSource {
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
            try { source.open().use { it.read(0, ByteArray(10), 10) }; fail("cancelled") }
            catch (_: IOException) {} finally { finished.countDown() }
        }.apply { start() }
        assertTrue(entered.await(2, TimeUnit.SECONDS))
        source.close()
        assertTrue(finished.await(1, TimeUnit.SECONDS)); worker.join(1000)
        try { source.open(); fail("closed source") } catch (_: IllegalStateException) {}
    }
    @Test fun upstreamCloseFailureStillReleasesWindowsAndReaders() {
        val origin = Origin()
        val source = InterleaveReadCache(object : StreamSource by origin {
            override fun close() { origin.close(); throw IOException("close failed") }
        })
        source.open().use { verify(it, 0, 100) }
        try { source.close(); fail("origin failure") } catch (_: IOException) {}
        assertEquals(origin.opens.get(), origin.closes.get())
        assertEquals(0L, source.stats().getValue("capacity_bytes"))
    }
}
