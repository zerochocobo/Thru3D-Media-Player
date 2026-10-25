package org.vrpassthroughplayer.plugin

import org.junit.Assert.*
import org.junit.Assume.assumeTrue
import org.junit.Rule
import org.junit.Test
import org.junit.rules.TemporaryFolder
import java.io.File
import java.io.FileInputStream
import java.net.HttpURLConnection
import java.net.InetSocketAddress
import java.net.URI
import java.net.URL
import java.util.Collections
import java.util.concurrent.atomic.AtomicBoolean
import java.util.concurrent.atomic.AtomicInteger

class SmallRarCacheTest {
    @get:Rule val temporary = TemporaryFolder()
    private val payload = ByteArray(2 * 1024 * 1024 + 137) { (it % 251).toByte() }.also {
        byteArrayOf(0x52,0x61,0x72,0x21,0x1a,0x07,0x00,0x43).copyInto(it)
    }
    private class Origin(val data: ByteArray, val advertised: Long = data.size.toLong(), val mode: String = "ok") : AutoCloseable {
        val ranges = Collections.synchronizedList(ArrayList<String>())
        val resolves = AtomicInteger()
        val server = CloudStreamSourceTest.HttpServer.create(InetSocketAddress("127.0.0.1",0),0)
        init {
            server.createContext("/file") { exchange ->
                val range = exchange.requestHeaders.getFirst("Range")!!
                assertEquals("1",exchange.requestHeaders.getFirst("X-Thru3D-Archive-Read"))
                ranges.add(range)
                val parts = range.removePrefix("bytes=").split('-')
                val start = parts[0].toInt(); val end = parts[1].toInt()
                if (mode == "busy" && start > 0) {
                    exchange.responseHeaders.add("X-Thru3D-Upstream-Reason", "cdn_connections_limited")
                    exchange.sendResponseHeaders(503,0)
                } else {
                    val total = advertised + if (mode == "changed" && start > 0) 1 else 0
                    val returnedEnd = if (mode == "short" && start > 0) minOf(end,start+65535) else end
                    exchange.responseHeaders.add("Content-Range", "bytes $start-$returnedEnd/$total")
                    exchange.sendResponseHeaders(206,(returnedEnd-start+1).toLong())
                    val count = minOf(returnedEnd-start+1, data.size-start).coerceAtLeast(0)
                    runCatching { exchange.responseBody.write(data,start,if (mode == "truncated" && start > 0) count/2 else count) }
                }
                exchange.close()
            }
            server.start()
        }
        fun source() = CloudStreamSource(advertised, {
            resolves.incrementAndGet()
            CloudLink("http://127.0.0.1:${server.address.port}/file") { emptyMap() }
        }, linkConnection = { uri, selected ->
            assertEquals(selected.url,uri.toASCIIString())
            uri.toURL().openConnection() as HttpURLConnection
        }).boundedRanges(1024*1024L).forArchiveReading()
        override fun close() { server.stop(0) }
    }

    @Test fun twoRealUpstreamRangesCacheTheWholeFileAndLoopbackReadsStayLocal() {
        Origin(payload).use { origin -> origin.source().use { source ->
            val directory = temporary.newFolder()
            val progress = ArrayList<Long>()
            val cached = SmallRarCache(directory,CloudCancellation()) { received,total ->
                assertEquals(payload.size.toLong(),total); progress.add(received)
            }.prepare(source,"book.RAR") {}
            assertTrue(cached is CachedRarSource)
            assertEquals(listOf("bytes=0-7","bytes=8-${payload.lastIndex}"),origin.ranges)
            assertEquals(1,origin.resolves.get())
            assertEquals(payload.size.toLong(),progress.last())
            assertTrue(progress.zipWithNext().all { it.first <= it.second })
            LocalStreamServer().use { local ->
                val url = local.publish(cached,"book.rar")
                assertTrue(local.cachedArchive(url))
                assertFalse(local.cachedArchive("http://127.0.0.1:1/not-ours/book.rar"))
                repeat(173) { i ->
                    val offset = (i * 9973) % (payload.size-32)
                    val connection = URL(url).openConnection() as HttpURLConnection
                    connection.setRequestProperty("Range","bytes=$offset-${offset+31}")
                    try {
                        assertEquals(206,connection.responseCode)
                        assertArrayEquals(payload.copyOfRange(offset,offset+32),connection.inputStream.use { it.readBytes() })
                    } finally { connection.disconnect() }
                }
                assertEquals(2,origin.ranges.size)
                local.revoke(url); assertFalse(local.cachedArchive(url))
            }
            assertTrue(directory.listFiles()!!.isEmpty())
        } }
    }

    @Test fun rar5KeepsSparseReadingAndNonRarAndLargeArchivesDoNotDownload() {
        val rar5 = payload.copyOf().also { it[6] = 1; it[7] = 0 }
        Origin(rar5).use { origin -> origin.source().use { source ->
            val directory = temporary.newFolder()
            assertSame(source,SmallRarCache(directory,CloudCancellation()).prepare(source,"book.rar") {})
            source.open().use { reader ->
                (reader as BoundedStreamReader).setRangeEnd(39)
                reader.read(32,ByteArray(8),8)
            }
            assertEquals(listOf("bytes=0-7","bytes=32-39"),origin.ranges)
            assertTrue(directory.listFiles()!!.isEmpty())
        } }
        for ((size,name) in listOf(payload.size.toLong() to "book.zip", (SmallRarCache.MAX_BYTES+1) to "book.rar")) {
            Origin(payload,size).use { origin -> origin.source().use { source ->
                assertSame(source,SmallRarCache(temporary.newFolder(),CloudCancellation()).prepare(source,name) {})
                assertTrue(origin.ranges.isEmpty())
            } }
        }
    }

    @Test fun exact256MiBBoundaryIsEligibleAndCanCancelBeforeDownloadingTheBody() {
        assertEquals(256L*1024*1024,SmallRarCache.MAX_BYTES)
        Origin(payload,SmallRarCache.MAX_BYTES).use { origin -> origin.source().use { source ->
            val cancel = CloudCancellation(); val directory = temporary.newFolder()
            try {
                SmallRarCache(directory,cancel) { _,_ -> cancel.cancel() }.prepare(source,"book.cbr") {}
                fail("Cancelled boundary download published a source")
            } catch (_: Exception) {}
            assertEquals(listOf("bytes=0-7"),origin.ranges)
            assertTrue(directory.listFiles()!!.isEmpty())
        } }
    }

    @Test fun failedDownloadsAreNotPublishedOrRetriedAndLeaveNoPartialFile() {
        for (mode in listOf("busy","changed","truncated","short")) Origin(payload,mode=mode).use { origin -> origin.source().use { source ->
            val directory = temporary.newFolder()
            try {
                SmallRarCache(directory,CloudCancellation()).prepare(source,"book.rar") {}
                fail("Failed transfer was published: $mode")
            } catch (_: Exception) {}
            assertEquals("Unexpected retries: $mode",2,origin.ranges.size)
            assertTrue("Partial file survived: $mode",directory.listFiles()!!.isEmpty())
        } }
    }

    @Test fun cancellingAnActiveDownloadCleansUpAndDoesNotFallBackToSparseScan() {
        Origin(payload).use { origin -> origin.source().use { source ->
            val cancel=CloudCancellation(); val directory=temporary.newFolder()
            try {
                SmallRarCache(directory,cancel) { received,_ -> if(received > 8) cancel.cancel() }.prepare(source,"book.rar") {}
                fail("Cancelled transfer was published")
            } catch (_: Exception) {}
            assertEquals(2,origin.ranges.size)
            assertTrue(directory.listFiles()!!.isEmpty())
        } }
    }

    @Test fun accountRevocationStopsCachedReadsAndCloseDeletesOriginalFile() {
        Origin(payload).use { origin -> origin.source().use { source ->
            val permitted=AtomicBoolean(true); val directory=temporary.newFolder()
            val cached=SmallRarCache(directory,CloudCancellation()).prepare(source,"book.rar") {
                if(!permitted.get()) throw CloudFailure("cloud_login_required")
            }
            val reader=cached.open(); permitted.set(false)
            try { reader.read(0,ByteArray(8),8);fail("Revoked account could read cached bytes") }
            catch(error:CloudFailure){assertEquals("cloud_login_required",error.reason)}
            reader.close(); cached.close();assertTrue(directory.listFiles()!!.isEmpty())
        } }
    }

    @Test fun cacheStorageFailureStopsBeforeStartingAFullBody() {
        Origin(payload).use { origin -> origin.source().use { source ->
            val directory=temporary.newFile()
            try {SmallRarCache(directory,CloudCancellation()).prepare(source,"book.rar") {};fail("Non-directory cache accepted")}
            catch(_:Exception){}
            assertEquals(listOf("bytes=0-7"),origin.ranges)
            assertTrue(directory.isFile)
        } }
    }

    @Test fun optionalMountedSampleCoversOriginalThroughCacheLoopbackAndGoDecoder() {
        val path=System.getenv("COMIC_LARGE_SAMPLE").orEmpty()
        val executable=System.getenv("COMIC_CACHED_GO_TEST").orEmpty()
        assumeTrue("Optional mounted original + Go decoder",path.isNotBlank() && executable.isNotBlank())
        val sample=File(path); val size=sample.length()
        require(size in 8L..SmallRarCache.MAX_BYTES)
        val upstream=CloudStreamSourceTest.HttpServer.create(InetSocketAddress("127.0.0.1",0),0)
        val requests=AtomicInteger(); val resolutions=AtomicInteger()
        upstream.createContext("/file") { exchange ->
            requests.incrementAndGet()
            assertEquals("1",exchange.requestHeaders.getFirst("X-Thru3D-Archive-Read"))
            val parts=exchange.requestHeaders.getFirst("Range")!!.removePrefix("bytes=").split('-')
            val start=parts[0].toLong(); val end=parts[1].toLong()
            assertTrue(start>=0 && end<size && start<=end)
            exchange.responseHeaders.add("Content-Range","bytes $start-$end/$size")
            exchange.sendResponseHeaders(206,end-start+1)
            runCatching {
                FileInputStream(sample).use { input ->
                    input.channel.position(start)
                    val buffer=ByteArray(256*1024); var left=end-start+1
                    while(left>0) {
                        val count=input.read(buffer,0,minOf(buffer.size.toLong(),left).toInt())
                        check(count>0); exchange.responseBody.write(buffer,0,count);left-=count
                    }
                }
            }
            exchange.close()
        }
        upstream.start()
        try {
            CloudStreamSource(size,{
                resolutions.incrementAndGet();CloudLink("http://127.0.0.1:${upstream.address.port}/file") { emptyMap() }
            },linkConnection = {uri,_ -> uri.toURL().openConnection() as HttpURLConnection}).boundedRanges(1024*1024L).forArchiveReading().use { source ->
                val started=System.nanoTime(); val directory=temporary.newFolder()
                val cached=SmallRarCache(directory,CloudCancellation()).prepare(source,sample.name) {}
                val cachedMs=(System.nanoTime()-started)/1_000_000
                assertTrue(cached is CachedRarSource)
                LocalStreamServer().use { local ->
                    val url=local.publish(cached,"sample.rar")
                    assertTrue(local.cachedArchive(url))
                    val command=ProcessBuilder(executable,"-test.run=^TestComicCachedLoopbackOptional$","-test.v","-test.timeout=30s")
                        .redirectErrorStream(true)
                    command.environment()["COMIC_CACHED_LOOPBACK"]=url
                    val process=command.start();val result=process.inputStream.bufferedReader().use {it.readText()}
                    assertEquals(result,0,process.waitFor())
                    assertEquals(2,requests.get());assertEquals(1,resolutions.get())
                    println("Mounted RAR: size=$size upstream_ranges=${requests.get()} resolutions=${resolutions.get()} full_cache_ms=$cachedMs total_ms=${(System.nanoTime()-started)/1_000_000}\n$result")
                }
                assertTrue(directory.listFiles()!!.isEmpty())
            }
        } finally { upstream.stop(0) }
    }
}
