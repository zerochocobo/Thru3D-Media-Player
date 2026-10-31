package org.vrpassthroughplayer.plugin

import org.junit.Assert.*
import org.junit.Test
import java.io.IOException
import java.nio.file.Files
import java.util.concurrent.CountDownLatch
import java.util.concurrent.Executors
import java.util.concurrent.TimeUnit
import java.util.concurrent.atomic.AtomicInteger

class PdfSmbSourceTest {
    private val uri = "smb://saved-server/VRRecommend/TEST/[weiphone][PDF电子书][龙珠]Vol.02.pdf"
    private val bytes = ByteArray(3 * PdfReadCache.BLOCK_BYTES + 197) { (it % 251).toByte() }
    private class Memory(val bytes: ByteArray) : StreamSource {
        val transferred = AtomicInteger(); val closes = AtomicInteger()
        override val size = bytes.size.toLong()
        override fun open() = object : StreamSource.Reader {
            override fun read(offset: Long, buffer: ByteArray, length: Int): Int {
                val count = minOf(length.toLong(), size - offset).toInt()
                bytes.copyInto(buffer, 0, offset.toInt(), offset.toInt() + count)
                transferred.addAndGet(count); return count
            }
            override fun close() {}
        }
        override fun close() { closes.incrementAndGet() }
    }

    @Test fun literalNameUsesIndependentSmbLeaseAndOnlyRequestedCacheBlocks() {
        LocalStreamServer().use { server ->
            val input = Memory(bytes); var lease = ""; var releases = 0
            val cancellation = CloudCancellation()
            val source = PdfSmbSource.open(uri, cancellation, { original ->
                assertEquals(uri, original)
                (server.publish(input, "document.pdf").also { lease = it }) to input.size
            }, { releases++; server.revoke(it) }, server::hasSource)
            val file = Files.createTempFile("pdf-smb", ".blocks").toFile()
            PdfReadCache(source, file).use { cache ->
                for (offset in listOf(0, bytes.size - 100, 1000, bytes.size - 100)) {
                    val output = ByteArray(100)
                    assertEquals(100, cache.read(offset.toLong(), output, 100))
                    assertArrayEquals(bytes.copyOfRange(offset, offset + 100), output)
                }
                assertEquals(PdfReadCache.BLOCK_BYTES + 197, input.transferred.get())
                assertTrue(server.hasSource(lease))
            }
            source.close(); cancellation.cancel()
            assertEquals(1, releases); assertEquals(1, input.closes.get())
            assertFalse(file.exists()); assertFalse(server.hasSource(lease))
        }
    }

    @Test fun cancellationDuringPublicationRetiresLateLeaseAndPreCancelledDoesNotPublish() {
        val cancel = CloudCancellation(); var releases = 0; var publishes = 0
        assertThrows(Exception::class.java) { PdfSmbSource.open(uri, cancel, {
            publishes++; cancel.cancel(); "http://127.0.0.1:1234/lease/document.pdf" to 10L
        }, { releases++ }, { true }) }
        assertEquals(1, publishes); assertEquals(1, releases)
        assertThrows(IOException::class.java) { PdfSmbSource.open(uri, cancel, {
            publishes++; error("must not publish")
        }, { releases++ }, { true }) }
        assertEquals(1, publishes); assertEquals(1, releases)
    }

    @Test fun invalidPublishedSourceReleasesLeaseWithoutConnectingElsewhere() {
        for ((url, size) in listOf("https://example.invalid/book.pdf" to 10L,
            "http://127.0.0.1:1234/book.pdf" to 0L)) {
            var releases = 0
            assertThrows(Exception::class.java) { PdfSmbSource.open(uri, CloudCancellation(), { url to size }, {
                assertEquals(url, it); releases++
            }, { true }) }
            assertEquals(1, releases)
        }
    }

    @Test fun closingOneDocumentLeavesOtherLeaseAndCachedPageValid() {
        LocalStreamServer().use { server ->
            fun open() = PdfSmbSource.open(uri, CloudCancellation(), {
                val input = Memory(bytes); server.publish(input, "document.pdf") to input.size
            }, server::revoke, server::hasSource)
            val first = open(); val second = open()
            try {
                PdfReadCache(second, Files.createTempFile("pdf-smb-other", ".blocks").toFile()).use { cache ->
                    cache.read(0, ByteArray(32), 32); first.close()
                    assertEquals(32, cache.read(0, ByteArray(32), 32))
                    assertEquals(32, cache.read(bytes.size - 32L, ByteArray(32), 32))
                }
            } finally { first.close(); second.close() }
        }
    }

    @Test fun revokedLeaseIsRejectedEvenOnCacheHit() {
        LocalStreamServer().use { server ->
            var lease = ""
            val source = PdfSmbSource.open(uri, CloudCancellation(), {
                val input = Memory(bytes)
                server.publish(input, "document.pdf").also { lease = it } to input.size
            }, server::revoke, server::hasSource)
            PdfReadCache(source, Files.createTempFile("pdf-smb-revoked", ".blocks").toFile()).use { cache ->
                cache.read(0, ByteArray(32), 32); server.revoke(lease)
                assertEquals("PDF_NETWORK_UNAVAILABLE", assertThrows(IOException::class.java) {
                    cache.read(0, ByteArray(32), 32)
                }.message)
            }
        }
    }

    @Test fun cancellingBlockedSmbReadUnblocksClientAndReleasesOnlyItsLease() {
        val entered = CountDownLatch(1); val stopped = CountDownLatch(1)
        val cancel = CloudCancellation(); val worker = Executors.newSingleThreadExecutor()
        LocalStreamServer().use { server ->
            val input = object : StreamSource {
                override val size = 1000L
                override fun open() = object : StreamSource.Reader {
                    override fun read(offset: Long, buffer: ByteArray, length: Int): Int {
                        entered.countDown(); check(stopped.await(5, TimeUnit.SECONDS)); throw IOException("closed")
                    }
                    override fun close() {}
                }
                override fun close() { stopped.countDown() }
            }
            val source = PdfSmbSource.open(uri, cancel, { server.publish(input, "document.pdf") to input.size }, server::revoke, server::hasSource)
            val cache = PdfReadCache(source, Files.createTempFile("pdf-smb-cancel", ".blocks").toFile())
            try {
                val future = worker.submit<Int> { cache.read(0, ByteArray(32), 32) }
                assertTrue(entered.await(3, TimeUnit.SECONDS)); cancel.cancel()
                assertTrue(stopped.await(1, TimeUnit.SECONDS))
                assertThrows(java.util.concurrent.ExecutionException::class.java) { future.get(3, TimeUnit.SECONDS) }
            } finally { cache.close(); worker.shutdownNow() }
        }
    }
}
