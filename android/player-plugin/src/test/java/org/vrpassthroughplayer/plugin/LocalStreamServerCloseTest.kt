package org.vrpassthroughplayer.plugin

import org.junit.Assert.*
import org.junit.Test
import java.net.Socket
import java.net.URI
import java.util.concurrent.CountDownLatch
import java.util.concurrent.atomic.AtomicInteger

class LocalStreamServerCloseTest {
    @Test fun clientCompletionCanRaceShutdownAndReleasesTheOwnedSourceOnce() {
        repeat(100) {
            val server = LocalStreamServer()
            val closed = AtomicInteger()
            val source = object : StreamSource {
                override val size = 1L
                override fun open() = object : StreamSource.Reader {
                    override fun read(offset: Long, buffer: ByteArray, length: Int) = -1
                    override fun close() {}
                }
                override fun close() { closed.incrementAndGet() }
            }
            val uri = URI(server.publish(source, "fixture.bin"))
            val client = Socket(uri.host, uri.port)
            val start = CountDownLatch(1)
            val closing = Thread { start.await(); client.close() }
            closing.start(); start.countDown()
            try { server.close(); server.close() }
            finally { closing.join(2000); client.close(); server.close() }
            assertFalse(server.hasSource(uri.toString()))
            assertEquals(1, closed.get())
            assertTrue(!closing.isAlive)
        }
    }
}
