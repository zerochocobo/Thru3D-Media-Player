package org.vrpassthroughplayer.plugin

import java.io.IOException
import java.io.InterruptedIOException
import java.net.SocketException
import java.net.SocketTimeoutException
import java.net.HttpURLConnection
import java.net.URL
import java.util.concurrent.CountDownLatch
import java.util.concurrent.TimeUnit
import org.codelibs.jcifs.smb.impl.SmbAuthException
import org.codelibs.jcifs.smb.impl.SmbException
import org.codelibs.jcifs.smb.util.transport.TransportException
import org.codelibs.jcifs.smb.util.transport.RequestTimeoutException
import org.codelibs.jcifs.smb.util.transport.ConnectionTimeoutException
import org.junit.Assert.*
import org.junit.Test

class SmbRecoveryTest {
    private class Pool {
        val created = mutableListOf<Any>()
        val disposed = mutableListOf<Any>()
        val connection = SmbConnection({ Any().also { created.add(it) } }, { disposed.add(it) })
    }
    private fun reader(read: (Long, ByteArray, Int) -> Int, close: () -> Unit = {}) = object : StreamSource.Reader {
        override fun read(offset: Long, buffer: ByteArray, length: Int) = read(offset, buffer, length)
        override fun close() = close()
    }

    @Test fun failedReadReopensAtExactSeekOffsetAndOverwritesPartialBuffer() {
        val pool = Pool()
        val offsets = mutableListOf<Long>()
        var closes = 0
        val input = SmbRecoveringReader(pool.connection) { context ->
            reader({ offset, buffer, length ->
                offsets.add(offset)
                if (context === pool.created.first()) { buffer.fill(99); throw SocketTimeoutException() }
                repeat(length) { buffer[it] = (offset + it).toByte() }; length
            }, { closes++ })
        }
        val bytes = ByteArray(7)
        assertEquals(7, input.read(54321, bytes, bytes.size))
        assertEquals(listOf(54321L, 54321L), offsets)
        assertArrayEquals(ByteArray(7) { (54321 + it).toByte() }, bytes)
        assertEquals(2, pool.created.size)
        assertEquals(1, pool.disposed.size)
        input.close()
        assertEquals(2, closes)
    }

    @Test fun failedOpenAlsoRecovers() {
        val pool = Pool()
        var opens = 0
        SmbRecoveringReader(pool.connection) {
            if (++opens == 1) throw SocketException("Connection reset")
            reader({ _, _, length -> length })
        }.use { assertEquals(1, it.read(0, ByteArray(1), 1)) }
        assertEquals(2, opens)
        assertEquals(1, pool.disposed.size)
    }

    @Test fun persistentFailureIsBoundedAndNextOpenGetsFreshPool() {
        val pool = Pool()
        var opens = 0
        SmbRecoveringReader(pool.connection) {
            opens++
            reader({ _, _, _ -> throw SocketTimeoutException() })
        }.use { input -> assertThrows(SocketTimeoutException::class.java) { input.read(0, ByteArray(1), 1) } }
        assertEquals(2, opens)
        assertEquals(2, pool.disposed.size)
        SmbRecoveringReader(pool.connection) { reader({ _, _, n -> n }) }.use {
            assertEquals(1, it.read(0, ByteArray(1), 1))
        }
        assertEquals(3, pool.created.size)
    }

    @Test fun staleFailureCannotEvictNewPoolOrAnotherServer() {
        val pool = Pool()
        val other = Pool()
        val first = pool.connection.get()
        val unrelated = other.connection.get()
        pool.connection.invalidate(first)
        val second = pool.connection.get()
        pool.connection.invalidate(first)
        assertSame(second, pool.connection.get())
        assertSame(unrelated, other.connection.get())
        assertEquals(listOf(first), pool.disposed)
        assertTrue(other.disposed.isEmpty())
    }

    @Test fun existingReadersSwitchAwayFromRetiredPool() {
        val pool = Pool()
        val used = mutableListOf<Any>()
        var closes = 0
        SmbRecoveringReader(pool.connection) { context ->
            used.add(context); reader({ _, _, n -> n }, { closes++ })
        }.use {
            it.read(0, ByteArray(1), 1)
            pool.connection.invalidate(pool.connection.get())
            it.read(123, ByteArray(1), 1)
            assertEquals(2, used.size)
            assertNotSame(used[0], used[1])
        }
        assertEquals(2, closes)
    }

    @Test fun metadataFailureDoesNotPoisonSubsequentOpen() {
        val pool = Pool()
        var calls = 0
        assertThrows(SocketTimeoutException::class.java) {
            pool.connection.read { calls++; throw SocketTimeoutException() }
        }
        assertEquals(2, calls)
        assertEquals(42L, pool.connection.read { 42L })
        assertEquals(3, pool.created.size)
    }

    @Test fun permanentErrorsAndCancellationDoNotRetryOrEvict() {
        val errors = listOf(IOException("Unclassified"), InterruptedIOException(),
            SmbAuthException::class.java.getDeclaredConstructor(Int::class.javaPrimitiveType)
                .apply { isAccessible = true }.newInstance(0xC000006D.toInt()),
            SmbException(0xC0000034.toInt(), false),
            SmbException(0xC0000022.toInt(), SocketTimeoutException()),
            TransportException(InterruptedIOException()), TransportException(InterruptedException()))
        for (error in errors) {
            val pool = Pool()
            var attempts = 0
            SmbRecoveringReader(pool.connection) {
                reader({ _, _, _ -> attempts++; throw error })
            }.use { input -> assertSame(error, assertThrows(IOException::class.java) { input.read(0, ByteArray(1), 1) }) }
            assertEquals(1, attempts)
            assertTrue(pool.disposed.isEmpty())
        }
    }

    @Test fun wrappedTransportAndSessionFailuresAreRecognized() {
        assertTrue(SmbRecovery.retryable(SmbException("Read failed", TransportException(SocketTimeoutException()))))
        assertTrue(SmbRecovery.retryable(SmbException(0xC00000C9.toInt(), false)))
        assertTrue(SmbRecovery.retryable(SmbException(0xC0000008.toInt(), false)))
        assertTrue(SmbRecovery.retryable(SmbException("Read failed", RequestTimeoutException("Timed out"))))
        assertTrue(SmbRecovery.retryable(ConnectionTimeoutException("Timed out")))
        assertTrue(SmbRecovery.retryable(TransportException(IOException("end of stream"))))
    }

    @Test fun closeDuringReadDoesNotReconnectOrInvalidate() {
        val pool = Pool()
        lateinit var input: SmbRecoveringReader<Any>
        input = SmbRecoveringReader(pool.connection) {
            reader({ _, _, _ -> input.close(); throw SocketException() })
        }
        assertThrows(InterruptedIOException::class.java) { input.read(0, ByteArray(1), 1) }
        assertEquals(1, pool.created.size)
        assertTrue(pool.disposed.isEmpty())
        assertThrows(InterruptedIOException::class.java) { input.read(0, ByteArray(1), 1) }
    }

    @Test fun closeWhileOpeningClosesLateHandleWithoutReadingIt() {
        val pool = Pool()
        val opening = CountDownLatch(1)
        val proceed = CountDownLatch(1)
        var closes = 0
        var failure: Throwable? = null
        val input = SmbRecoveringReader(pool.connection) {
            opening.countDown()
            check(proceed.await(5, TimeUnit.SECONDS))
            reader({ _, _, _ -> error("Cancelled reader must not read") }, { closes++ })
        }
        val worker = Thread { try { input.read(0, ByteArray(1), 1) } catch (error: Throwable) { failure = error } }
        worker.start()
        try {
            assertTrue(opening.await(5, TimeUnit.SECONDS))
            input.close()
        } finally { proceed.countDown(); worker.join(5000) }
        assertFalse(worker.isAlive)
        assertTrue(failure is InterruptedIOException)
        assertEquals(1, closes)
        assertTrue(pool.disposed.isEmpty())
    }

    @Test fun cleanupFailureDoesNotPreventRecovery() {
        var generation = 0
        val connection = SmbConnection({ ++generation }, { throw IOException("Close failed") })
        SmbRecoveringReader(connection) { version ->
            reader({ _, _, n -> if (version == 1) throw SocketException() else n }, { throw IOException() })
        }.use { assertEquals(1, it.read(42, ByteArray(1), 1)) }
        assertEquals(2, generation)
    }

    @Test fun retiringServerPreventsOldSourcesReopeningWithOldCredentials() {
        val pool = Pool()
        pool.connection.get()
        pool.connection.close()
        pool.connection.close()
        assertThrows(IOException::class.java) { pool.connection.get() }
        assertEquals(1, pool.disposed.size)
    }

    @Test fun httpRangeSeekRecoversWithoutTruncatingOrMixingBytes() {
        val pool = Pool()
        val source = object : StreamSource {
            override val size = 4096L
            override val forkable = true
            override fun open() = SmbRecoveringReader(pool.connection) { generation ->
                reader({ offset, buffer, length ->
                    if (generation === pool.created.first()) throw SocketException("Connection reset")
                    repeat(length) { buffer[it] = ((offset + it) * 31).toByte() }
                    length
                })
            }
        }
        LocalStreamServer().use { server ->
            val url = server.publish(source, "test.mp4")
            for (start in listOf(2000, 32, 3900)) {
                val http = URL(url).openConnection() as HttpURLConnection
                http.connectTimeout = 3000; http.readTimeout = 3000
                http.setRequestProperty("Range", "bytes=$start-${start + 63}")
                try {
                    assertEquals(206, http.responseCode)
                    assertArrayEquals(ByteArray(64) { ((start + it) * 31).toByte() }, http.inputStream.use { it.readBytes() })
                    assertNull(server.failure(url))
                } finally { http.disconnect() }
            }
            assertEquals(2, pool.created.size)
        }
    }

    @Test fun interruptedMetadataDoesNotCreateConnection() {
        val pool = Pool()
        Thread.currentThread().interrupt()
        try {
            assertThrows(InterruptedIOException::class.java) { pool.connection.read { error("Must not read") } }
            assertTrue(pool.created.isEmpty())
        } finally { Thread.interrupted() }
    }
}
