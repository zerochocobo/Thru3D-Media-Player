package org.vrpassthroughplayer.plugin

import org.junit.Assert.*
import org.junit.Test
import java.net.URI

class TransferMeterTest {
    @Test fun countsActualBytesAndFallsToZeroWhenReadingStops() {
        var now = 0L
        val meter = TransferMeter { now }
        assertEquals(TransferMeter.Snapshot(0, 0), meter.snapshot())
        now = 200; meter.add(2000)
        assertEquals(10000, meter.snapshot().bytesPerSecond)
        now = 1000; meter.add(3000)
        assertEquals(TransferMeter.Snapshot(5000, 5000), meter.snapshot())
        now = 1200
        assertEquals(TransferMeter.Snapshot(5000, 3000), meter.snapshot())
        now = 2100
        assertEquals(TransferMeter.Snapshot(5000, 0), meter.snapshot())
        meter.add(-1); meter.add(0)
        assertEquals(5000, meter.snapshot().bytes)
    }
    @Test fun proxyCountsBodyBytesAcrossSeeksButNotHeadersAndRevocationClearsProgress() {
        val bytes = ByteArray(2048) { it.toByte() }
        val source = object : StreamSource {
            override val size = bytes.size.toLong()
            override fun open() = object : StreamSource.Reader {
                override fun read(offset: Long, buffer: ByteArray, length: Int): Int {
                    val count = minOf(length, bytes.size - offset.toInt())
                    bytes.copyInto(buffer, 0, offset.toInt(), offset.toInt() + count); return count
                }
                override fun close() {}
            }
        }
        LocalStreamServer().use { server ->
            val url = server.publish(source, "ordinary.mp4")
            assertEquals(0, server.progress(url)!!.bytes)
            for (range in listOf("bytes=0-127", "bytes=64-191")) {
                val c = URI(url).toURL().openConnection() as java.net.HttpURLConnection
                try { c.setRequestProperty("Range", range); assertEquals(128, c.inputStream.use { it.readBytes().size }) }
                finally { c.disconnect() }
            }
            assertEquals(256, server.progress(url)!!.bytes)
            assertNull(server.progress(url.replace("127.0.0.1", "localhost")))
            server.revoke(url); assertNull(server.progress(url))
        }
    }
}
