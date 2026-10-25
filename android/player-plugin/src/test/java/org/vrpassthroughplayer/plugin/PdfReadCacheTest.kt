package org.vrpassthroughplayer.plugin

import org.junit.Assert.*
import org.junit.Test
import java.io.File
import java.io.IOException
import java.net.HttpURLConnection
import java.net.InetSocketAddress
import java.nio.file.Files
import java.util.concurrent.atomic.AtomicInteger

class PdfReadCacheTest {
    private val bytes = ByteArray(3 * PdfReadCache.BLOCK_BYTES + 197) { (it % 251).toByte() }
    private class Source(val bytes: ByteArray) : StreamSource {
        override val size = bytes.size.toLong()
        var opens = 0; var closed = false; var failAfter = Long.MAX_VALUE
        val requested = mutableListOf<Pair<Long, Long>>()
        override fun close() { closed = true }
        override fun open(): StreamSource.Reader {
            opens++
            return object : BoundedStreamReader {
                var end = size - 1
                override fun setRangeEnd(endInclusive: Long) { end = endInclusive }
                override fun read(offset: Long, buffer: ByteArray, length: Int): Int {
                    if (closed || offset >= failAfter) throw IOException("upstream failed")
                    requested.add(offset to end)
                    val count = minOf(length, 4096, (end - offset + 1).toInt())
                    bytes.copyInto(buffer, 0, offset.toInt(), offset.toInt() + count); return count
                }
                override fun close() {}
            }
        }
    }
    private fun file() = Files.createTempFile("pdf-blocks-test", ".cache").toFile()
    private fun read(cache: PdfReadCache, offset: Int, length: Int) {
        val result = ByteArray(length)
        assertEquals(minOf(length, bytes.size - offset), cache.read(offset.toLong(), result, length))
        assertArrayEquals(bytes.copyOfRange(offset, offset + length), result)
    }
    @Test fun repeatedTinySeeksUseTwoBlocksWithoutDownloadingTheWholeDocument() {
        val source = Source(bytes); val file = file()
        PdfReadCache(PdfNetworkSource(source) {}, file).use { cache ->
            for (i in 0..300) read(cache, (i * 73) % 900_000, 100)
            val calls = source.requested.size
            for (i in 0..300) read(cache, i * 211, 500)
            assertEquals(calls, source.requested.size)
            read(cache, bytes.size - 197, 197)
            assertEquals(1, source.opens)
            assertEquals(setOf(1_048_575L, bytes.lastIndex.toLong()), source.requested.map { it.second }.toSet())
            assertEquals(PdfReadCache.BLOCK_BYTES + 197L, file.length())
            assertEquals(0, cache.read(cache.size, ByteArray(1), 1))
        }
        assertFalse(file.exists()); assertTrue(source.closed)
    }
    @Test fun cacheHitChecksAuthorizationAndBoundedEvictionDoesNotCorruptBlocks() {
        val source = Source(bytes); var authorized = true
        PdfReadCache(PdfNetworkSource(source) { check(authorized) }, file(), blockSize = 256, capacity = 2).use { cache ->
            read(cache, 1, 10); read(cache, 257, 10); read(cache, 1, 10)
            read(cache, 513, 10); read(cache, 1, 10); read(cache, 257, 10)
            assertEquals(listOf(0L, 256L, 512L, 256L), source.requested.map { it.first })
            authorized = false
            assertThrows(IllegalStateException::class.java) { cache.read(257, ByteArray(1), 1) }
        }
    }
    @Test fun partialReadFailureIsNeverPublishedAndSpaceGuardMakesNoRequest() {
        val source = Source(bytes); source.failAfter = 4096
        PdfReadCache(PdfNetworkSource(source) {}, file(), blockSize = 8192).use { cache ->
            assertThrows(IOException::class.java) { cache.read(0, ByteArray(10), 10) }
            source.failAfter = Long.MAX_VALUE
            read(cache, 0, 10)
            assertEquals(2, source.opens)
            assertEquals(2, source.requested.count { it.first == 0L })
        }
        val empty = Source(bytes)
        PdfReadCache(PdfNetworkSource(empty) {}, file(), available = { 0 }).use { cache ->
            assertEquals("PDF_CACHE_FULL", assertThrows(IOException::class.java) { cache.read(0, ByteArray(10), 10) }.message)
            assertEquals(0, empty.opens)
        }
    }
    @Test fun blockBoundaryReadsAndShortFinalBlockAreExact() {
        val source = Source(bytes)
        PdfReadCache(PdfNetworkSource(source) {}, file()).use { cache ->
            read(cache, PdfReadCache.BLOCK_BYTES - 21, 500)
            read(cache, bytes.size - 197, 197)
            val result = ByteArray(1000)
            assertEquals(7, cache.read(bytes.size - 7L, result, 1000))
            assertArrayEquals(bytes.takeLast(7).toByteArray(), result.copyOf(7))
        }
    }
    @Test fun realHttpCloudRangesResolveOnceAndCachedPageRereadsMakeNoRequests() {
        val requests = AtomicInteger(); val resolutions = AtomicInteger()
        val ranges = mutableListOf<String>()
        val server = CloudStreamSourceTest.HttpServer.create(InetSocketAddress("127.0.0.1", 0), 0)
        server.createContext("/book.pdf") { exchange ->
            requests.incrementAndGet()
            val range = exchange.requestHeaders.getFirst("Range")!!
            synchronized(ranges) { ranges.add(range) }
            val (start, end) = range.removePrefix("bytes=").split('-').map(String::toInt)
            exchange.responseHeaders.add("Content-Range", "bytes $start-$end/${bytes.size}")
            exchange.sendResponseHeaders(206, (end - start + 1).toLong())
            exchange.responseBody.use { it.write(bytes, start, end - start + 1) }; exchange.close()
        }
        server.start()
        try {
            val source = CloudStreamSource(bytes.size.toLong(), {
                resolutions.incrementAndGet(); CloudLink("http://127.0.0.1:${server.address.port}/book.pdf") { emptyMap() }
            }) { it.toURL().openConnection() as HttpURLConnection }.boundedRanges(PdfReadCache.BLOCK_BYTES.toLong()).forPdfReading()
            source.prepare()
            PdfReadCache(PdfNetworkSource(source) {}, file()).use { cache ->
                read(cache, 0, 8); read(cache, bytes.size - 100, 100)
                read(cache, 3072, 8192); read(cache, 50, 77); read(cache, bytes.size - 100, 100)
                assertEquals(2, requests.get()); assertEquals(1, resolutions.get())
                assertEquals(listOf("bytes=0-1048575", "bytes=3145728-3145924"), ranges)
            }
        } finally { server.stop(0) }
    }
    @Test fun shortServerRangeFailsOnceInsteadOfSplittingIntoManyRequests() {
        val requests = AtomicInteger()
        val server = CloudStreamSourceTest.HttpServer.create(InetSocketAddress("127.0.0.1", 0), 0)
        server.createContext("/book.pdf") { exchange ->
            requests.incrementAndGet()
            exchange.responseHeaders.add("Content-Range", "bytes 0-7/${bytes.size}")
            exchange.sendResponseHeaders(206, 8)
            runCatching { exchange.responseBody.use { it.write(bytes, 0, 8) } }; exchange.close()
        }
        server.start()
        try {
            val source = CloudStreamSource(bytes.size.toLong(), { CloudLink("http://127.0.0.1:${server.address.port}/book.pdf") { emptyMap() } }) {
                it.toURL().openConnection() as HttpURLConnection
            }.boundedRanges(PdfReadCache.BLOCK_BYTES.toLong()).forPdfReading()
            PdfReadCache(PdfNetworkSource(source) {}, file()).use { cache ->
                assertThrows(IOException::class.java) { cache.read(0, ByteArray(8), 8) }
                assertEquals(1, requests.get())
            }
        } finally { server.stop(0) }
    }
}
