package org.vrpassthroughplayer.plugin

import org.junit.Assert.*
import org.junit.Test
import java.net.HttpURLConnection
import java.net.InetSocketAddress
import java.net.URI
import java.net.URL
import java.net.ServerSocket
import java.net.Socket
import java.io.Closeable
import java.io.OutputStream
import java.util.concurrent.Executors
import java.util.concurrent.atomic.AtomicInteger

class CloudStreamSourceTest {
    private val bytes = ByteArray(700000) { (it % 251).toByte() }
    private fun localConnection(uri: URI) = uri.toURL().openConnection() as HttpURLConnection
    @Test fun rangeConnectionsUseTheSelectedLinkWithoutRepeatingMetadataResolution() {
        val resolutions = AtomicInteger()
        val requests = AtomicInteger()
        val server = HttpServer.create(InetSocketAddress("127.0.0.1", 0), 0)
        server.createContext("/file") { exchange ->
            requests.incrementAndGet()
            val start = exchange.requestHeaders.getFirst("Range")!!.removePrefix("bytes=").removeSuffix("-").toInt()
            exchange.responseHeaders.add("Content-Range", "bytes $start-${bytes.lastIndex}/${bytes.size}")
            exchange.sendResponseHeaders(206, (bytes.size - start).toLong())
            runCatching { exchange.responseBody.use { it.write(bytes, start, bytes.size - start) } }
            exchange.close()
        }
        server.start()
        val link = CloudLink("http://127.0.0.1:${server.address.port}/file") { emptyMap() }
        try {
            CloudStreamSource(bytes.size.toLong(), { resolutions.incrementAndGet(); link },
                linkConnection = { uri, selected ->
                    assertSame(link, selected)
                    assertEquals(selected.url, uri.toASCIIString())
                    localConnection(uri)
                }).use { source ->
                source.prepare()
                for (offset in listOf(32768L, 524288L, 0L, 690000L)) source.open().use { reader ->
                    val buffer = ByteArray(2048)
                    val count = reader.read(offset, buffer, buffer.size)
                    assertTrue(count > 0)
                    assertArrayEquals(bytes.copyOfRange(offset.toInt(), offset.toInt() + count), buffer.copyOf(count))
                }
            }
            assertEquals(4, requests.get())
            assertEquals(1, resolutions.get())
        } finally { server.stop(0) }
    }
    // Android's compile classpath omits jdk.httpserver. Keep the fixture as real sockets.
    internal class HttpServer private constructor(bind: InetSocketAddress) {
        private val socket = ServerSocket().apply { bind(bind) }
        val address = InetSocketAddress("127.0.0.1", socket.localPort)
        private val routes = HashMap<String, (Exchange) -> Unit>()
        private val workers = Executors.newCachedThreadPool { Thread(it).apply { isDaemon = true } }
        @Volatile private var error: Throwable? = null
        fun createContext(path: String, handle: (Exchange) -> Unit) { routes[path] = handle }
        fun start() {
            workers.execute {
                while (!socket.isClosed) {
                    val client = try { socket.accept() } catch (_: Exception) { break }
                    workers.execute {
                        client.use {
                            try {
                                val reader = it.getInputStream().bufferedReader()
                                val request = reader.readLine().split(' ')
                                val exchange = Exchange(it)
                                while (true) {
                                    val line = reader.readLine() ?: break
                                    if (line.isEmpty()) break
                                    exchange.requestHeaders.add(line.substringBefore(':'), line.substringAfter(':').trim())
                                }
                                routes.getValue(URI(request[1]).path)(exchange)
                            } catch (failure: Throwable) { error = failure }
                        }
                    }
                }
            }
        }
        fun stop(@Suppress("UNUSED_PARAMETER") delay: Int) {
            socket.close(); workers.shutdownNow()
            error?.let { throw AssertionError("HTTP fixture failed", it) }
        }
        class Headers {
            private val values = HashMap<String, String>()
            fun add(key: String, value: String) { values[key.lowercase()] = value }
            fun getFirst(key: String): String? = values[key.lowercase()]
            override fun toString() = values.entries.joinToString("") { "${it.key}: ${it.value}\r\n" }
        }
        class Exchange(private val client: Socket) : Closeable {
            val requestHeaders = Headers()
            val responseHeaders = Headers()
            val responseBody: OutputStream get() = client.getOutputStream()
            fun sendResponseHeaders(status: Int, length: Long) {
                responseBody.write(("HTTP/1.1 $status Fixture\r\nContent-Length: ${maxOf(0, length)}\r\nConnection: close\r\n" + responseHeaders + "\r\n").toByteArray())
            }
            override fun close() { client.close() }
        }
        companion object { fun create(bind: InetSocketAddress, @Suppress("UNUSED_PARAMETER") backlog: Int) = HttpServer(bind) }
    }
    @Test fun sequentialReadsReuseOneConnectionAndSeeksUseCorrectOffsets() {
        val requests = AtomicInteger()
        val server = HttpServer.create(InetSocketAddress("127.0.0.1", 0), 0)
        server.createContext("/file") { exchange ->
            requests.incrementAndGet()
            assertEquals("fixture-agent", exchange.requestHeaders.getFirst("User-Agent"))
            assertNull(exchange.requestHeaders.getFirst("Cookie"))
            val start = exchange.requestHeaders.getFirst("Range")!!.removePrefix("bytes=").removeSuffix("-").toInt()
            exchange.responseHeaders.add("Content-Range", "bytes $start-${bytes.lastIndex}/${bytes.size}")
            exchange.sendResponseHeaders(206, (bytes.size - start).toLong())
            runCatching { exchange.responseBody.use { it.write(bytes, start, bytes.size - start) } }
            exchange.close()
        }
        server.start()
        try {
            val source = CloudStreamSource(bytes.size.toLong(), { CloudLink("http://127.0.0.1:${server.address.port}/file") { mapOf("User-Agent" to "fixture-agent") } }, ::localConnection)
            source.use {
                it.open().use { reader ->
                    val buffer = ByteArray(10000)
                    var offset = 100L
                    repeat(5) {
                        val count = reader.read(offset, buffer, buffer.size)
                        assertArrayEquals(bytes.copyOfRange(offset.toInt(), offset.toInt() + count), buffer.copyOf(count))
                        offset += count
                    }
                    assertEquals(1, requests.get())
                    val count = reader.read(600000, buffer, buffer.size)
                    assertArrayEquals(bytes.copyOfRange(600000, 600000 + count), buffer.copyOf(count))
                    assertEquals(2, requests.get())
                }
            }
        } finally { server.stop(0) }
    }
    @Test fun rejectedRangeBecomes502BeforeAnySuccessHeaders() {
        for (kind in listOf("ignored", "wrong-offset", "wrong-size")) {
            val upstream = HttpServer.create(InetSocketAddress("127.0.0.1", 0), 0)
            upstream.createContext("/file") { exchange ->
                if (kind != "ignored") exchange.responseHeaders.add("Content-Range", if (kind == "wrong-offset") "bytes 0-99/100" else "bytes 10-99/101")
                exchange.sendResponseHeaders(if (kind == "ignored") 200 else 206, 100)
                runCatching { exchange.responseBody.use { it.write(ByteArray(100)) } }; exchange.close()
            }
            upstream.start()
            try {
                LocalStreamServer().use { local ->
                    val source = CloudStreamSource(100, { CloudLink("http://127.0.0.1:${upstream.address.port}/file") { emptyMap() } }, ::localConnection)
                    val url = local.publish(source, "file.mp4")
                    val connection = URL(url).openConnection() as HttpURLConnection
                    connection.setRequestProperty("Range", "bytes=10-99")
                    assertEquals(kind, 502, connection.responseCode); connection.disconnect()
                    assertEquals(if (kind == "ignored") "range_unsupported" else "invalid_range", local.failure(url)?.reason)
                    assertEquals(if (kind == "ignored") 200 else 206, local.failure(url)?.httpStatus)
                }
            } finally { upstream.stop(0) }
        }
    }
    @Test fun expiredLinkIsRefreshedOnceAndRevocationStopsNewReads() {
        val resolutions = AtomicInteger()
        val upstream = HttpServer.create(InetSocketAddress("127.0.0.1", 0), 0)
        upstream.createContext("/expired") { it.sendResponseHeaders(403, -1); it.close() }
        upstream.createContext("/valid") { exchange ->
            exchange.responseHeaders.add("Content-Range", "bytes 0-9/10")
            exchange.sendResponseHeaders(206, 10); exchange.responseBody.use { it.write(ByteArray(10) { 42 }) }; exchange.close()
        }
        upstream.start()
        try {
            val source = CloudStreamSource(10, {
                CloudLink("http://127.0.0.1:${upstream.address.port}/" + if (resolutions.incrementAndGet() == 1) "expired" else "valid") { emptyMap() }
            }, ::localConnection)
            val reader = source.open()
            val data = ByteArray(10)
            assertEquals(10, reader.read(0, data, 10)); assertEquals(2, resolutions.get())
            assertArrayEquals(ByteArray(10) { 42 }, data)
            source.close()
            try { reader.read(0, data, 10); fail() } catch (error: PlaybackFailureException) { assertEquals("cancelled", error.failure.reason) }
            try { source.open(); fail() } catch (_: CloudFailure) {}
        } finally { upstream.stop(0) }
    }

    @Test fun transientGatewayRetriesTheExactRangeWithoutResolvingMetadataAgain() {
        for (status in listOf(502, 503, 504)) {
            val requests = AtomicInteger()
            val resolutions = AtomicInteger()
            val upstream = HttpServer.create(InetSocketAddress("127.0.0.1", 0), 0)
            val offset = 32768
            upstream.createContext("/file") { exchange ->
                assertEquals("bytes=$offset-", exchange.requestHeaders.getFirst("Range"))
                assertEquals("reference-agent", exchange.requestHeaders.getFirst("User-Agent"))
                if (requests.incrementAndGet() == 1) exchange.sendResponseHeaders(status, 0)
                else {
                    exchange.responseHeaders.add("Content-Range", "bytes $offset-${bytes.lastIndex}/${bytes.size}")
                    exchange.sendResponseHeaders(206, (bytes.size-offset).toLong())
                    runCatching { exchange.responseBody.write(bytes, offset, bytes.size-offset) }
                }
                exchange.close()
            }
            upstream.start()
            try {
                CloudStreamSource(bytes.size.toLong(), {
                    resolutions.incrementAndGet()
                    CloudLink("http://127.0.0.1:${upstream.address.port}/file") { mapOf("User-Agent" to "reference-agent") }
                }, ::localConnection).use { source ->
                    source.open().use { reader ->
                        val data=ByteArray(4096)
                        val count=reader.read(offset.toLong(),data,data.size)
                        assertTrue(count>0)
                        assertArrayEquals(bytes.copyOfRange(offset,offset+count),data.copyOf(count))
                    }
                }
                assertEquals(2,requests.get());assertEquals(1,resolutions.get())
            } finally { upstream.stop(0) }
        }
    }

    @Test fun persistentGatewayFailureStopsAfterOneRetryAndKeepsItsStatus() {
        val requests=AtomicInteger()
        val upstream=HttpServer.create(InetSocketAddress("127.0.0.1",0),0)
        upstream.createContext("/file") { exchange ->
            requests.incrementAndGet();exchange.sendResponseHeaders(502,0);exchange.close()
        }
        upstream.start()
        try {
            CloudStreamSource(10,{CloudLink("http://127.0.0.1:${upstream.address.port}/file") {emptyMap()}},::localConnection).use { source ->
                source.open().use { reader ->
                    try {reader.read(0,ByteArray(10),10);fail("Persistent gateway failure accepted")}
                    catch(error: PlaybackFailureException){assertEquals(502,error.failure.httpStatus)}
                }
            }
            assertEquals(2,requests.get())
        } finally {upstream.stop(0)}
    }

    @Test fun revokedSourceDoesNotSendTheGatewayRetry() {
        val requests=AtomicInteger()
        val upstream=HttpServer.create(InetSocketAddress("127.0.0.1",0),0)
        lateinit var source: CloudStreamSource
        upstream.createContext("/file") { exchange ->
            requests.incrementAndGet();source.close();exchange.sendResponseHeaders(502,0);exchange.close()
        }
        upstream.start()
        try {
            source=CloudStreamSource(10,{CloudLink("http://127.0.0.1:${upstream.address.port}/file") {emptyMap()}},::localConnection)
            source.open().use { reader ->
                try {reader.read(0,ByteArray(10),10);fail("Revoked source accepted")}
                catch(error: PlaybackFailureException){assertEquals("cancelled",error.failure.reason)}
            }
            assertEquals(1,requests.get())
        } finally {source.close();upstream.stop(0)}
    }

    @Test fun interruptedBodyResumesAtFirstUnreadByteWithoutRepeatingMetadata() {
        val requests=AtomicInteger();val resolutions=AtomicInteger()
        val upstream=HttpServer.create(InetSocketAddress("127.0.0.1",0),0)
        val payload=ByteArray(10) {it.toByte()}
        upstream.createContext("/file") { exchange ->
            val first=requests.incrementAndGet()==1
            val offset=if(first)0 else 3
            assertEquals("bytes=$offset-",exchange.requestHeaders.getFirst("Range"))
            exchange.responseHeaders.add("Content-Range","bytes $offset-9/10")
            exchange.sendResponseHeaders(206,(10-offset).toLong())
            exchange.responseBody.write(payload,offset,if(first)3 else 7)
            exchange.close()
        }
        upstream.start()
        try {
            CloudStreamSource(10,{
                resolutions.incrementAndGet();CloudLink("http://127.0.0.1:${upstream.address.port}/file") {emptyMap()}
            },::localConnection).use { source ->
                source.open().use { reader ->
                    val result=java.io.ByteArrayOutputStream();val buffer=ByteArray(10)
                    while(result.size()<10) {
                        val count=reader.read(result.size().toLong(),buffer,buffer.size)
                        result.write(buffer,0,count)
                    }
                    assertArrayEquals(payload,result.toByteArray())
                }
            }
            assertEquals(2,requests.get());assertEquals(1,resolutions.get())
        } finally {upstream.stop(0)}
    }

    @Test fun permanentlyInterruptedBodyStopsAfterOneResume() {
        val requests=AtomicInteger()
        val upstream=HttpServer.create(InetSocketAddress("127.0.0.1",0),0)
        upstream.createContext("/file") { exchange ->
            requests.incrementAndGet();exchange.responseHeaders.add("Content-Range","bytes 0-9/10")
            exchange.sendResponseHeaders(206,10);exchange.close()
        }
        upstream.start()
        try {
            CloudStreamSource(10,{CloudLink("http://127.0.0.1:${upstream.address.port}/file") {emptyMap()}},::localConnection).use { source ->
                source.open().use { reader ->
                    try {reader.read(0,ByteArray(10),10);fail("Truncated body accepted")}
                    catch(error: PlaybackFailureException){assertEquals("stream_interrupted",error.failure.reason)}
                }
            }
            assertEquals(2,requests.get())
        } finally {upstream.stop(0)}
    }

    @Test fun onlyKnownUpstreamDenialCodesReachStreamDiagnostics() {
        for (code in listOf("cdn_cookie_missing","https://private.invalid/token","arbitrary_message")) {
            val upstream=HttpServer.create(InetSocketAddress("127.0.0.1",0),0)
            upstream.createContext("/file") { exchange ->
                exchange.responseHeaders.add("X-Thru3D-Upstream-Reason",code)
                exchange.sendResponseHeaders(403,0);exchange.close()
            }
            upstream.start()
            try {
                LocalStreamServer().use { local ->
                    val url=local.publish(CloudStreamSource(10,{CloudLink("http://127.0.0.1:${upstream.address.port}/file") {emptyMap()}},::localConnection),"video.mp4")
                    val connection=URL(url).openConnection() as HttpURLConnection
                    assertEquals(502,connection.responseCode);connection.disconnect()
                    assertEquals(if(code=="cdn_cookie_missing")code else "",local.failure(url)?.sourceCode)
                }
            } finally {upstream.stop(0)}
        }
    }

    @Test fun boundedReferenceRangesKeepSequentialBytesWithoutHoldingAFullFileBody() {
        val requests=AtomicInteger();val resolutions=AtomicInteger()
        val upstream=HttpServer.create(InetSocketAddress("127.0.0.1",0),0)
        upstream.createContext("/file") { exchange ->
            requests.incrementAndGet()
            val range=exchange.requestHeaders.getFirst("Range")!!.removePrefix("bytes=").split('-')
            val start=range[0].toInt();val end=range[1].toInt()
            assertEquals(minOf(bytes.lastIndex,start+65535),end)
            exchange.responseHeaders.add("Content-Range","bytes $start-$end/${bytes.size}")
            exchange.sendResponseHeaders(206,(end-start+1).toLong())
            runCatching {exchange.responseBody.write(bytes,start,end-start+1)};exchange.close()
        }
        upstream.start()
        try {
            CloudStreamSource(bytes.size.toLong(),{
                resolutions.incrementAndGet();CloudLink("http://127.0.0.1:${upstream.address.port}/file") {emptyMap()}
            },::localConnection).boundedRanges(65536).use { source ->
                source.open().use { reader ->
                    val output=java.io.ByteArrayOutputStream();val buffer=ByteArray(10000)
                    while(output.size()<bytes.size) {
                        val count=reader.read(output.size().toLong(),buffer,buffer.size);output.write(buffer,0,count)
                    }
                    assertArrayEquals(bytes,output.toByteArray())
                }
            }
            assertEquals((bytes.size+65535)/65536,requests.get());assertEquals(1,resolutions.get())
        } finally {upstream.stop(0)}
    }

    @Test fun aServerIgnoringTheBoundedEndCannotHoldAWholeReferenceFile() {
        val upstream=HttpServer.create(InetSocketAddress("127.0.0.1",0),0)
        upstream.createContext("/file") { exchange ->
            exchange.responseHeaders.add("Content-Range","bytes 0-999/1000");exchange.sendResponseHeaders(206,1000)
            runCatching {exchange.responseBody.write(ByteArray(1000))};exchange.close()
        }
        upstream.start()
        try {
            CloudStreamSource(1000,{CloudLink("http://127.0.0.1:${upstream.address.port}/file") {emptyMap()}},::localConnection).boundedRanges(64).use { source ->
                source.open().use { reader ->
                    try {reader.read(0,ByteArray(10),10);fail("Ignored range end accepted")}
                    catch(error: PlaybackFailureException){assertEquals("invalid_range",error.failure.reason)}
                }
            }
        } finally {upstream.stop(0)}
    }

    @Test fun aBusyCdnWaitsAndRetriesWithoutRefreshingTheAccountOrTicket() {
        val requests=AtomicInteger();val resolutions=AtomicInteger()
        val upstream=HttpServer.create(InetSocketAddress("127.0.0.1",0),0)
        upstream.createContext("/file") { exchange ->
            if(requests.incrementAndGet()<=2) {
                exchange.responseHeaders.add("X-Thru3D-Upstream-Reason","cdn_connections_limited");exchange.sendResponseHeaders(403,0)
            } else {
                exchange.responseHeaders.add("Content-Range","bytes 0-9/10");exchange.sendResponseHeaders(206,10)
                exchange.responseBody.write(ByteArray(10){42})
            }
            exchange.close()
        }
        upstream.start()
        try {
            CloudStreamSource(10,{
                resolutions.incrementAndGet();CloudLink("http://127.0.0.1:${upstream.address.port}/file") {emptyMap()}
            },::localConnection).boundedRanges(65536).use { source ->
                source.open().use { reader ->
                    val data=ByteArray(10);assertEquals(10,reader.read(0,data,10));assertArrayEquals(ByteArray(10){42},data)
                }
            }
            assertEquals(3,requests.get());assertEquals(1,resolutions.get())
        } finally {upstream.stop(0)}
    }

    @Test fun comicReadsRejectWholeResponsesAndDoNotRetryBusySources() {
        for (status in listOf(200,429,503)) {
            val requests=AtomicInteger(); val resolutions=AtomicInteger()
            val upstream=HttpServer.create(InetSocketAddress("127.0.0.1",0),0)
            upstream.createContext("/file") { exchange ->
                requests.incrementAndGet()
                if(status!=200)exchange.responseHeaders.add("X-Thru3D-Upstream-Reason","cdn_connections_limited")
                exchange.sendResponseHeaders(status,10)
                runCatching {exchange.responseBody.write(ByteArray(10))}; exchange.close()
            }
            upstream.start()
            try {
                CloudStreamSource(10,{
                    resolutions.incrementAndGet();CloudLink("http://127.0.0.1:${upstream.address.port}/file"){emptyMap()}
                },::localConnection).boundedRanges(1024).forArchiveReading().use { source ->
                    source.open().use { reader ->
                        assertThrows(PlaybackFailureException::class.java){reader.read(0,ByteArray(10),10)}
                    }
                }
                assertEquals(1,requests.get());assertEquals(1,resolutions.get())
            } finally {upstream.stop(0)}
        }
    }

    @Test fun aPersistentlyBusyCdnStopsAfterSixWaitsWithoutAnAuthenticationRefresh() {
        val requests=AtomicInteger();val resolutions=AtomicInteger()
        val upstream=HttpServer.create(InetSocketAddress("127.0.0.1",0),0)
        upstream.createContext("/file") { exchange ->
            requests.incrementAndGet();exchange.responseHeaders.add("X-Thru3D-Upstream-Reason","cdn_connections_limited")
            exchange.sendResponseHeaders(403,0);exchange.close()
        }
        upstream.start()
        try {
            CloudStreamSource(10,{
                resolutions.incrementAndGet();CloudLink("http://127.0.0.1:${upstream.address.port}/file") {emptyMap()}
            },::localConnection).use { source ->
                source.open().use { reader ->
                    try {reader.read(0,ByteArray(10),10);fail("Persistent busy response accepted")}
                    catch(error: PlaybackFailureException){assertEquals("cdn_connections_limited",error.failure.sourceCode)}
                }
            }
            assertEquals(7,requests.get());assertEquals(1,resolutions.get())
        } finally {upstream.stop(0)}
    }

    @Test fun upstreamHttpStatusSurvivesTheLocal502AndIsScopedToItsStream() {
        for (status in listOf(401, 403, 404, 410, 500)) {
            val upstream = HttpServer.create(InetSocketAddress("127.0.0.1", 0), 0)
            val requests = AtomicInteger()
            upstream.createContext("/file") { requests.incrementAndGet(); it.sendResponseHeaders(status, 0); it.close() }
            upstream.start()
            try {
                LocalStreamServer().use { local ->
                    val source = CloudStreamSource(10, { CloudLink("http://127.0.0.1:${upstream.address.port}/file") { emptyMap() } }, ::localConnection)
                    val url = local.publish(source, "video.mkv")
                    val unrelated = local.publish(object : StreamSource {
                        override val size = 10L
                        override fun open() = object : StreamSource.Reader {
                            override fun read(offset: Long, buffer: ByteArray, length: Int) = length
                            override fun close() {}
                        }
                    }, "other.mkv")
                    val c = URL(url).openConnection() as HttpURLConnection
                    assertEquals(502, c.responseCode); c.disconnect()
                    assertEquals(status, local.failure(url)?.httpStatus)
                    assertEquals(PlaybackFailure.http(status).reason, local.failure(url)?.reason)
                    assertNull(local.failure(unrelated))
                    assertEquals(if (status in listOf(401, 403, 410)) 2 else 1, requests.get())
                    local.revoke(url)
                    assertNull(local.failure(url))
                }
            } finally { upstream.stop(0) }
        }
    }

    @Test fun recoveredRefreshAndNonMediaResponsesHaveDifferentDiagnostics() {
        val upstream = HttpServer.create(InetSocketAddress("127.0.0.1", 0), 0)
        upstream.createContext("/expired") { it.sendResponseHeaders(403, 0); it.close() }
        upstream.createContext("/valid") { exchange ->
            exchange.responseHeaders.add("Content-Range", "bytes 0-9/10")
            exchange.sendResponseHeaders(206, 10); exchange.responseBody.write(ByteArray(10)); exchange.close()
        }
        upstream.createContext("/html") { exchange ->
            exchange.responseHeaders.add("Content-Type", "text/html")
            exchange.responseHeaders.add("Content-Range", "bytes 0-9/10")
            exchange.sendResponseHeaders(206, 10); exchange.responseBody.write(ByteArray(10)); exchange.close()
        }
        upstream.start()
        try {
            LocalStreamServer().use { local ->
                val resolutions = AtomicInteger()
                val recovered = local.publish(CloudStreamSource(10, {
                    CloudLink("http://127.0.0.1:${upstream.address.port}/" + if (resolutions.incrementAndGet() == 1) "expired" else "valid") { emptyMap() }
                }, ::localConnection), "recovered.mkv")
                URL(recovered).openStream().use { assertEquals(10, it.readBytes().size) }
                assertNull(local.failure(recovered))
                val html = local.publish(CloudStreamSource(10, { CloudLink("http://127.0.0.1:${upstream.address.port}/html") { emptyMap() } }, ::localConnection), "html.mkv")
                val c = URL(html).openConnection() as HttpURLConnection
                assertEquals(502, c.responseCode); c.disconnect()
                assertEquals("not_media", local.failure(html)?.reason)
                assertEquals(206, local.failure(html)?.httpStatus)
                assertNull(local.failure(recovered))
            }
        } finally { upstream.stop(0) }
    }

    @Test fun successfulReadClearsPreviousFailureAndCancellationIsNotAFailure() {
        val mode = AtomicInteger()
        LocalStreamServer().use { local ->
            val url = local.publish(object : StreamSource {
                override val size = 10L
                override fun open() = object : StreamSource.Reader {
                    override fun read(offset: Long, buffer: ByteArray, length: Int): Int {
                        when (mode.get()) {
                            0 -> throw java.net.SocketTimeoutException("Read timed out")
                            2 -> throw PlaybackFailureException(PlaybackFailure("cancelled", "reading", "Cancelled"))
                        }
                        return length
                    }
                    override fun close() {}
                }
            }, "retry.mkv")
            val failed = URL(url).openConnection() as HttpURLConnection
            assertEquals(502, failed.responseCode); failed.disconnect()
            assertEquals("network_timeout", local.failure(url)?.reason)
            mode.set(1)
            URL(url).openStream().use { assertEquals(10, it.readBytes().size) }
            assertNull(local.failure(url))
            mode.set(2)
            val cancelled = URL(url).openConnection() as HttpURLConnection
            assertEquals(502, cancelled.responseCode); cancelled.disconnect()
            assertNull(local.failure(url))
        }
    }

    @Test fun delayedFailureOfAnOldSeekCannotOverwriteANewerSuccessfulRead() {
        val entered = java.util.concurrent.CountDownLatch(1)
        val resume = java.util.concurrent.CountDownLatch(1)
        val readers = AtomicInteger()
        val executor = Executors.newSingleThreadExecutor()
        try {
            LocalStreamServer().use { local ->
                val url = local.publish(object : StreamSource {
                    override val size = 10L
                    override fun open(): StreamSource.Reader {
                        val index = readers.incrementAndGet()
                        return object : StreamSource.Reader {
                            override fun read(offset: Long, buffer: ByteArray, length: Int): Int {
                                if (index == 1) {
                                    entered.countDown()
                                    check(resume.await(5, java.util.concurrent.TimeUnit.SECONDS))
                                    throw java.net.SocketTimeoutException("Old seek timed out")
                                }
                                return length
                            }
                            override fun close() {}
                        }
                    }
                }, "seek.mkv")
                val old = executor.submit<Int> {
                    val c = URL(url).openConnection() as HttpURLConnection
                    try { c.responseCode } finally { c.disconnect() }
                }
                assertTrue(entered.await(5, java.util.concurrent.TimeUnit.SECONDS))
                URL(url).openStream().use { assertEquals(10, it.readBytes().size) }
                resume.countDown()
                assertEquals(502, old.get(5, java.util.concurrent.TimeUnit.SECONDS).toInt())
                assertNull(local.failure(url))
            }
        } finally { resume.countDown(); executor.shutdownNow() }
    }
    @Test fun archiveLocalRangesAreExactAndShareOneAddressForALargeSource() {
        val size=3_000_000_000L
        val ranges=java.util.concurrent.CopyOnWriteArrayList<Pair<Long,Long>>()
        val resolutions=AtomicInteger()
        val upstream=HttpServer.create(InetSocketAddress("127.0.0.1",0),0)
        upstream.createContext("/file") { exchange ->
            val parts=exchange.requestHeaders.getFirst("Range")!!.removePrefix("bytes=").split('-')
            val start=parts[0].toLong();val end=parts[1].toLong()
            ranges.add(start to end)
            val body=ByteArray((end-start+1).toInt()){((start+it)%251).toByte()}
            exchange.responseHeaders.add("Content-Range","bytes $start-$end/$size")
            exchange.sendResponseHeaders(206,body.size.toLong())
            runCatching {exchange.responseBody.write(body)};exchange.close()
        }
        upstream.start()
        try {
            val source=CloudStreamSource(size,{
                resolutions.incrementAndGet();CloudLink("http://127.0.0.1:${upstream.address.port}/file"){emptyMap()}
            },::localConnection).boundedRanges(1024*1024).forArchiveReading()
            source.prepare()
            // Simulate a long reading session without sleeping five minutes.
            source.javaClass.getDeclaredField("resolvedAt").apply {isAccessible=true}
                .setLong(source,System.nanoTime()-360_000_000_000L)
            LocalStreamServer().use { local ->
                val location=local.publish(source,"book.zip")
                fun read(start:Long,end:Long) {
                    val request=URL(location).openConnection() as HttpURLConnection
                    request.setRequestProperty("Range","bytes=$start-$end")
                    try {
                        assertEquals(206,request.responseCode)
                        val body=request.inputStream.use {it.readBytes()}
                        assertEquals((end-start+1).toInt(),body.size)
                        assertEquals((start%251).toByte(),body.first());assertEquals((end%251).toByte(),body.last())
                    } finally {request.disconnect()}
                }
                read(0,0)
                read(size-131072,size-1)
                read(100,131171)
                read(10_000_000,12_499_999)
            }
            assertEquals(1,resolutions.get())
            assertEquals(listOf(0L to 0L,(size-131072) to (size-1),100L to 131171L,
                10_000_000L to 11_048_575L,11_048_576L to 12_097_151L,12_097_152L to 12_499_999L),ranges.toList())
            println("Archive 3GB source: address_resolutions=${resolutions.get()} upstream_ranges=${ranges.size}")
        } finally {upstream.stop(0)}
    }

    @Test fun archiveProxyRefreshDoesNotRepeatObjectLookup() {
        val requests=AtomicInteger();val resolutions=AtomicInteger()
        val upstream=HttpServer.create(InetSocketAddress("127.0.0.1",0),0)
        upstream.createContext("/file") { exchange ->
            assertEquals("1",exchange.requestHeaders.getFirst("X-Thru3D-Archive-Read"))
            if(requests.incrementAndGet()==1) {exchange.sendResponseHeaders(403,0)}
            else {exchange.responseHeaders.add("Content-Range","bytes 0-9/10");exchange.sendResponseHeaders(206,10);exchange.responseBody.write(ByteArray(10))}
            exchange.close()
        }
        upstream.start()
        try {
            CloudStreamSource(10,{
                resolutions.incrementAndGet();CloudLink("http://127.0.0.1:${upstream.address.port}/file"){emptyMap()}
            },linkConnection={uri,_->localConnection(uri)}).boundedRanges(64).forArchiveReading().use {source ->
                source.open().use {assertEquals(10,it.read(0,ByteArray(10),10))}
            }
            assertEquals(2,requests.get());assertEquals(1,resolutions.get())
        } finally {upstream.stop(0)}
    }

    @Test fun archiveRateLimitNeverRefreshesAnAddressOrRetries() {
        for(code in listOf("cdn_connections_limited","cdn_rate_limited")) {
            val requests=AtomicInteger();val resolutions=AtomicInteger()
            val upstream=HttpServer.create(InetSocketAddress("127.0.0.1",0),0)
            upstream.createContext("/file") {exchange ->
                requests.incrementAndGet();exchange.responseHeaders.add("X-Thru3D-Upstream-Reason",code)
                exchange.sendResponseHeaders(403,0);exchange.close()
            }
            upstream.start()
            try {
                CloudStreamSource(10,{
                    resolutions.incrementAndGet();CloudLink("http://127.0.0.1:${upstream.address.port}/file"){emptyMap()}
                },::localConnection).boundedRanges(64).forArchiveReading().use {source ->
                    source.open().use {reader ->
                        assertThrows(PlaybackFailureException::class.java){reader.read(0,ByteArray(10),10)}
                    }
                }
                assertEquals(1,requests.get());assertEquals(1,resolutions.get())
            } finally {upstream.stop(0)}
        }
    }

    @Test fun aNewArchiveReaderRetiresAnObsoletePacedRangeBeforeItCanConnect() {
        val requests=AtomicInteger();val resolutions=AtomicInteger()
        val upstream=HttpServer.create(InetSocketAddress("127.0.0.1",0),0)
        upstream.createContext("/file") {exchange ->
            requests.incrementAndGet();exchange.responseHeaders.add("Content-Range","bytes 0-9/10")
            exchange.sendResponseHeaders(206,10);exchange.responseBody.write(ByteArray(10));exchange.close()
        }
        upstream.start()
        try {
            CloudStreamSource(10,{
                resolutions.incrementAndGet();CloudLink("http://127.0.0.1:${upstream.address.port}/file"){emptyMap()}
            },::localConnection).boundedRanges(64).forArchiveReading().use {source ->
                val obsolete=source.open()
                source.open().use {latest ->
                    assertThrows(PlaybackFailureException::class.java){obsolete.read(0,ByteArray(10),10)}
                    assertEquals(10,latest.read(0,ByteArray(10),10))
                }
                obsolete.close()
            }
            assertEquals(1,resolutions.get());assertEquals(1,requests.get())
        } finally {upstream.stop(0)}
    }

}
