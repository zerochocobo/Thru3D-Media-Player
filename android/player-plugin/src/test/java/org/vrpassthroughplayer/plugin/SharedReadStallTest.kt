package org.vrpassthroughplayer.plugin

import org.junit.Assert.*
import org.junit.Test
import java.io.InputStream
import java.net.HttpURLConnection
import java.net.InetSocketAddress
import java.net.URI
import java.util.concurrent.CountDownLatch
import java.util.concurrent.Executors
import java.util.concurrent.TimeUnit

/** Real socket reads, including the CDN stall from the developer handoff. */
class SharedReadStallTest {
    private class StalledCdn(private val firstBytes: Int, private val headerStall: Boolean = false) : AutoCloseable {
        val blocked = CountDownLatch(1)
        private val release = CountDownLatch(1)
        private val size = 1L shl 30
        private val server = CloudStreamSourceTest.HttpServer.create(InetSocketAddress("127.0.0.1", 0), 0)
        init {
            server.createContext("/file") { exchange ->
                runCatching {
                    val start = exchange.requestHeaders.getFirst("Range")!!.substringAfter("bytes=").substringBefore('-').toLong()
                    if (headerStall && start == 0L) { blocked.countDown(); release.await(10, TimeUnit.SECONDS) }
                    exchange.responseHeaders.add("Content-Range", "bytes $start-${size-1}/$size")
                    exchange.sendResponseHeaders(206, size-start)
                    exchange.responseBody.use { output ->
                        var at = start
                        if (start == 0L) {
                            if (firstBytes > 0) output.write(ByteArray(firstBytes) { (it%251).toByte() })
                            output.flush()
                            release.await(10, TimeUnit.SECONDS)
                        } else {
                            val bytes = ByteArray(65536)
                            while (at < size) {
                                val n = minOf(bytes.size.toLong(), size-at).toInt()
                                for (i in 0 until n) bytes[i] = ((at+i)%251).toByte()
                                output.write(bytes,0,n); at += n
                            }
                        }
                    }
                }
                runCatching { exchange.close() }
            }
            server.start()
        }
        fun source() = CloudStreamSource(size,
            { CloudLink("http://127.0.0.1:${server.address.port}/file") { emptyMap() } }, ::connection)
        private fun connection(uri: URI): HttpURLConnection {
            val origin = CancellableMediaConnection.open(uri)
            return object : HttpURLConnection(uri.toURL()) {
                private var rangeStart=0L
                override fun connect() = origin.connect()
                override fun disconnect() = origin.disconnect()
                override fun usingProxy() = origin.usingProxy()
                override fun setRequestProperty(name: String, value: String) {
                    if(name=="Range")rangeStart=value.substringAfter("bytes=").substringBefore('-').toLong()
                    origin.setRequestProperty(name,value)
                }
                override fun setConnectTimeout(value: Int) { origin.connectTimeout=value }
                override fun setReadTimeout(value: Int) { origin.readTimeout=value }
                override fun getResponseCode() = origin.responseCode
                override fun getHeaderField(name: String): String? = origin.getHeaderField(name)
                override fun getContentType(): String? = origin.contentType
                override fun getInputStream(): InputStream {
                    val stream = origin.inputStream
                    val start = rangeStart
                    return object : InputStream() {
                        private var at=start
                        override fun read(): Int { val b=ByteArray(1);return if(read(b,0,1)<0)-1 else b[0].toInt() and 255 }
                        override fun read(bytes: ByteArray, offset: Int, length: Int): Int {
                            if(start==0L && at>=firstBytes)blocked.countDown()
                            val n=stream.read(bytes,offset,length);if(n>0)at+=n;return n
                        }
                        override fun close() = stream.close()
                    }
                }
            }
        }
        override fun close() { release.countDown();server.stop(0) }
    }
    private fun verify(reader: StreamSource.Reader, offset: Long): Int {
        val bytes=ByteArray(65536);val n=reader.read(offset,bytes,bytes.size)
        assertTrue(n>0)
        for(i in 0 until n)assertEquals(((offset+i)%251).toByte(),bytes[i])
        return n
    }
    private fun seekDuringStall(firstBytes: Int) {
        StalledCdn(firstBytes).use { cdn -> cdn.source().use { source ->
            source.shareReadAhead()
            val pool=Executors.newFixedThreadPool(2)
            val old=source.open()
            try {
                val pending=pool.submit<Int> { verify(old,0) }
                assertTrue(cdn.blocked.await(2,TimeUnit.SECONDS))
                val started=System.nanoTime()
                val seek=pool.submit<Int> {source.open().use {verify(it,100L shl 20)}}
                assertTrue(seek.get(1,TimeUnit.SECONDS)>0)
                val elapsed=(System.nanoTime()-started)/1_000_000
                assertTrue("Seek waited $elapsed ms",elapsed<1000)
                if(firstBytes>0)assertTrue(pending.get(1,TimeUnit.SECONDS)>0)
                println("SHARED_STALL first_bytes=$firstBytes seek_ms=$elapsed")
            } finally {old.close();source.close();pool.shutdownNow();pool.awaitTermination(2,TimeUnit.SECONDS)}
        } }
    }
    @Test fun distantSeekPreemptsStalledSpeculationAndPreservesCopiedBytes() = seekDuringStall(65536)
    @Test fun distantSeekPreemptsStalledDemand() = seekDuringStall(0)
    @Test fun distantSeekPreemptsResponseThatNeverStarts() {
        StalledCdn(0, headerStall = true).use { cdn -> cdn.source().use { source ->
            source.shareReadAhead()
            val pool=Executors.newFixedThreadPool(2)
            val old=source.open()
            try {
                pool.submit<Int> { verify(old,0) }
                assertTrue(cdn.blocked.await(2,TimeUnit.SECONDS))
                val started=System.nanoTime()
                assertTrue(pool.submit<Int> {source.open().use {verify(it,100L shl 20)}}.get(1,TimeUnit.SECONDS)>0)
                val elapsed=(System.nanoTime()-started)/1_000_000
                assertTrue("Seek waited $elapsed ms",elapsed<1000)
                println("SHARED_STALL header_stall seek_ms=$elapsed")
            } finally {old.close();source.close();pool.shutdownNow();pool.awaitTermination(2,TimeUnit.SECONDS)}
        } }
    }
    @Test fun speculativeReadReturnsCopiedBytesWithinOneSecondWithoutAnotherClient() {
        StalledCdn(65536).use { cdn -> cdn.source().use { source ->
            source.shareReadAhead();val pool=Executors.newSingleThreadExecutor()
            try {
                val started=System.nanoTime()
                val pending=pool.submit<Int> {source.open().use {verify(it,0)}}
                assertTrue(cdn.blocked.await(2,TimeUnit.SECONDS))
                assertTrue(pending.get(1,TimeUnit.SECONDS)>0)
                val elapsed=(System.nanoTime()-started)/1_000_000
                assertTrue("Speculation withheld demand bytes for $elapsed ms",elapsed<1000)
                println("SHARED_STALL speculation_ms=$elapsed")
            } finally {source.close();pool.shutdownNow();pool.awaitTermination(2,TimeUnit.SECONDS)}
        } }
    }
    @Test fun activationDuringStalledBodyReadReturnsWithinOneSecondAndMigratesClient() {
        StalledCdn(65536).use { cdn -> cdn.source().use { source -> source.open().use { old ->
            var at=0L
            while(at<65536)at+=verify(old,at)
            val pool=Executors.newFixedThreadPool(2)
            try {
                val pending=pool.submit<Int> {verify(old,65536)}
                assertTrue(cdn.blocked.await(2,TimeUnit.SECONDS))
                val started=System.nanoTime()
                pool.submit {source.shareReadAhead()}.get(1,TimeUnit.SECONDS)
                val elapsed=(System.nanoTime()-started)/1_000_000
                assertTrue("Activation waited $elapsed ms",elapsed<1000)
                assertTrue(source.sharedReadAheadActive)
                assertTrue(pending.get(1,TimeUnit.SECONDS)>0)
                println("SHARED_STALL activation_ms=$elapsed")
            } finally {source.close();pool.shutdownNow();pool.awaitTermination(2,TimeUnit.SECONDS)}
        } } }
    }
}
