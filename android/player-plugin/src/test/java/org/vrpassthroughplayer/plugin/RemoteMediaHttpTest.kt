package org.vrpassthroughplayer.plugin

import org.junit.Assert.*
import org.junit.Test
import java.net.URI
import java.util.concurrent.atomic.AtomicInteger
import java.util.concurrent.CountDownLatch
import java.util.concurrent.atomic.AtomicReference
import org.vrpassthroughplayer.plugin.MediaServerClientTest.Fixture
import org.vrpassthroughplayer.plugin.MediaServerClientTest.Reply

class RemoteMediaHttpTest {
    @Test fun releasingTheLastConnectionCanRaceClose() {
        Fixture { _, _, _ -> Reply(body = byteArrayOf(1,2,3,4)) }.use { origin ->
            repeat(80) {
                RemoteMediaHttp().use { http ->
                    val connection = http.open(URI(origin.url + "/clip.mp4"), "", emptyMap())
                    val start = CountDownLatch(1); val failure = AtomicReference<Throwable?>()
                    val release = Thread { start.await(); try { http.release(connection) } catch (error: Throwable) { failure.set(error) } }
                    release.start(); start.countDown()
                    try { http.close() } finally { release.join(2000); http.close() }
                    assertFalse(release.isAlive); assertNull(failure.get())
                    assertThrows(MediaServerFailure::class.java) { http.open(URI(origin.url + "/closed"), "", emptyMap()) }
                }
            }
        }
    }
    @Test fun sendsAgainAfterAConnectionCutWithoutAResponse() {
        // The host JDK silently resends a GET once after a closed connection; cut past that.
        val requests = AtomicInteger()
        Fixture { _, _, _ ->
            if (requests.incrementAndGet() <= 2) error("Connection cut")
            Reply(206, "Content-Range: bytes 0-3/4\r\n", byteArrayOf(1, 2, 3, 4))
        }.use { origin -> RemoteMediaHttp().use { http ->
            val c = http.open(URI(origin.url + "/clip.mp4"), "bytes=0-", emptyMap())
            assertEquals(206, c.responseCode)
            assertArrayEquals(byteArrayOf(1, 2, 3, 4), c.inputStream.use { it.readBytes() })
            http.release(c)
        } }
        assertEquals(3, requests.get())
    }

    @Test fun anHttpAnswerAndAPersistentCutStayFinal() {
        val refused = AtomicInteger()
        Fixture { _, _, _ -> refused.incrementAndGet(); Reply(404, body = ByteArray(0)) }.use { origin -> RemoteMediaHttp().use { http ->
            val failure = assertThrows(MediaServerFailure::class.java) { http.open(URI(origin.url + "/clip.mp4"), "", emptyMap()) }
            assertEquals(404, failure.httpStatus)
        } }
        assertEquals(1, refused.get())
        val cut = AtomicInteger()
        Fixture { _, _, _ -> cut.incrementAndGet(); error("Connection cut") }.use { origin -> RemoteMediaHttp().use { http ->
            val failure = assertThrows(MediaServerFailure::class.java) { http.open(URI(origin.url + "/clip.mp4"), "", emptyMap()) }
            assertTrue(failure.transportError.isNotEmpty())
        } }
        assertEquals(6, cut.get()) // Three attempts, each resent once by the host JDK.
    }
}
