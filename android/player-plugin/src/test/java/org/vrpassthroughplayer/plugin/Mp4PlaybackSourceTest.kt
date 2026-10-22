package org.vrpassthroughplayer.plugin

import org.junit.Assert.*
import org.junit.Test
import java.io.ByteArrayOutputStream
import java.io.DataOutputStream
import java.io.IOException
import java.util.concurrent.CountDownLatch
import java.util.concurrent.TimeUnit
import java.net.InetSocketAddress
import java.net.URI
import java.net.HttpURLConnection
import java.util.concurrent.atomic.AtomicInteger

class Mp4PlaybackSourceTest {
    private fun numbers(vararg n: Long) = ByteArrayOutputStream().also { b -> DataOutputStream(b).use { d -> n.forEach { d.writeInt(it.toInt()) } } }.toByteArray()
    private fun box(name: String, vararg pieces: ByteArray): ByteArray {
        val payload = pieces.fold(ByteArray(0)) { a, b -> a + b }
        return numbers(payload.size + 8L) + name.toByteArray(Charsets.US_ASCII) + payload
    }
    private fun fixture(wide: Boolean = false, gap: Boolean = false, auxiliary: Boolean = false,
        external: Boolean = false, editTime: Long? = null, extraTrack: Boolean = false, audioSampleBytes: Int = 2): ByteArray {
        val ftyp = box("ftyp", "isom".toByteArray(), numbers(0), "isommp41".toByteArray())
        val base = ftyp.size + 16L
        fun track(kind: String, positions: LongArray, length: Long) : ByteArray {
            val offsets = ByteArrayOutputStream().also { b -> DataOutputStream(b).use { d ->
                d.writeInt(0); d.writeInt(positions.size); positions.forEach { if (wide) d.writeLong(it) else d.writeInt(it.toInt()) }
            } }.toByteArray()
            return box("trak", if(editTime == null) ByteArray(0) else box("edts",box("elst",numbers(0,1,120,editTime,0x10000))),
                box("mdia", box("hdlr", numbers(0,0),kind.toByteArray()),
                box("mdhd",numbers(0,0,0,30,120,0)),box("minf",box("dinf",box("dref",numbers(0,1),box("url ",numbers(if(external) 0 else 1)))),box("stbl",
                    box("stsd",numbers(0,1),box(if(kind=="vide") "hvc1" else "mp4a",ByteArray(8).also { it[7]=1 })),
                    box(if(wide) "co64" else "stco",offsets),box("stsz",numbers(0,length,120)),
                    box("stsc",numbers(0,1,1,60,1)),box("stts",numbers(0,1,120,1)),
                    if(kind=="soun") box("sgpd",numbers(0x1000000),"roll".toByteArray(),numbers(2,1),byteArrayOf(-1,-1))+
                        box("sbgp",numbers(0),"roll".toByteArray(),numbers(1,120,1)) else ByteArray(0),
                    if(auxiliary) box("saio",numbers(0,0)) else ByteArray(0)))))
        }
        val padding = if(gap) 7 else 0
        val videoAt=base+120L*audioSampleBytes+padding
        val moov=box("moov",track("vide",longArrayOf(videoAt,videoAt+600),10),track("soun",longArrayOf(base,base+60L*audioSampleBytes),audioSampleBytes.toLong()),
            if(extraTrack) box("trak",box("mdia",box("hdlr",numbers(0,0),"text".toByteArray()))) else ByteArray(0))
        val data=ByteArray(1200+120*audioSampleBytes+padding) { (it%251).toByte() }
        val mdat=java.nio.ByteBuffer.allocate(16).putInt(1).put("mdat".toByteArray()).putLong(16L+data.size).array()
        return ftyp+mdat+data+moov
    }
    private fun inspect(bytes: ByteArray) = Mp4InterleavePolicy.inspect(object : Mp4InterleavePolicy.Reader {
        override val size=bytes.size.toLong()
        override fun read(offset:Long,length:Int)=bytes.copyOfRange(offset.toInt(),minOf(bytes.size,offset.toInt()+length))
    })
    private class Origin(val bytes:ByteArray):StreamSource {
        override val size=bytes.size.toLong(); var closed=false
        override fun open()=object:StreamSource.Reader {
            override fun read(offset:Long,buffer:ByteArray,length:Int):Int {
                check(!closed); val n=minOf(length,bytes.size-offset.toInt());bytes.copyInto(buffer,0,offset.toInt(),offset.toInt()+n);return n
            }
            override fun close() {}
        }
        override fun close() { closed=true }
    }
    @Test fun longChunksSplitOnSampleBoundariesAndPromoteBothOffsetFormats() {
        for(wide in listOf(false,true)) {
            val bytes=fixture(wide);val decision=inspect(bytes)
            assertTrue(decision.regionCache);assertFalse(decision.sequential)
            val layout=decision.playbackLayout!!
            assertEquals(16,layout.chunks.size)
            assertEquals(1440L,layout.chunks.sumOf { it.length })
            val expected=layout.header+layout.chunks.fold(ByteArray(0)) { a,c -> a+bytes.copyOfRange(c.origin.toInt(),(c.origin+c.length).toInt()) }
            val normalized=inspect(expected)
            assertEquals("default",normalized.diagnostic);assertFalse(normalized.regionCache)
            val origin=Origin(bytes)
            Mp4PlaybackSource(origin,layout).use { source ->
                source.open().use { reader ->
                    for(offset in listOf(0L,layout.header.size-5L,layout.header.size.toLong(),layout.size-23)) {
                        val output=ByteArray(257);val n=reader.read(offset,output,output.size)
                        assertArrayEquals(expected.copyOfRange(offset.toInt(),offset.toInt()+n),output.copyOf(n))
                    }
                }
                assertTrue(source.stats().getValue("capacity_bytes")<=16L*1024*1024)
            }
            assertTrue(origin.closed)
        }
    }
    @Test fun unknownPayloadAndAuxiliaryOffsetsKeepTheOriginalCompatibilityPath() {
        for(bytes in listOf(fixture(gap=true),fixture(auxiliary=true),fixture(external=true),fixture(editTime=30),fixture(extraTrack=true))) {
            val decision=inspect(bytes);assertTrue(decision.regionCache);assertNull(decision.playbackLayout)
        }
        assertNotNull(inspect(fixture(editTime=1)).playbackLayout)
    }
    @Test fun previouslyCacheableSmallAudioKeepsItsEstablishedPlaybackPath() {
        val small=inspect(fixture());assertTrue(small.regionCache);assertNotNull(small.playbackLayout)
        assertFalse(small.preferPlaybackView)
        val large=inspect(fixture(audioSampleBytes=100000))
        assertTrue(large.regionCache);assertNotNull(large.playbackLayout);assertTrue(large.preferPlaybackView)
    }
    @Test fun closingOneHttpReaderKeepsAnotherReaderAndClosingTheLeaseCancelsBoth() {
        val bytes=fixture();val layout=inspect(bytes).playbackLayout!!
        val source=Mp4PlaybackSource(Origin(bytes),layout)
        val first=source.open();val second=source.open();first.close()
        try { first.read(0,ByteArray(1),1);fail() } catch(_:IOException) {}
        assertEquals(1,second.read(0,ByteArray(1),1));source.close()
        try { second.read(0,ByteArray(1),1);fail() } catch(_:IOException) {}
    }
    @Test fun sourceCloseInterruptsAnUpstreamReadBeforeWaitingForTransportLock() {
        val bytes=fixture();val layout=inspect(bytes).playbackLayout!!
        val entered=CountDownLatch(1);val cancelled=CountDownLatch(1);val finished=CountDownLatch(1)
        val source=Mp4PlaybackSource(object:StreamSource {
            override val size=bytes.size.toLong()
            override fun open()=object:StreamSource.Reader {
                override fun read(offset:Long,buffer:ByteArray,length:Int):Int { entered.countDown();check(cancelled.await(3,TimeUnit.SECONDS));throw IOException("cancelled") }
                override fun close() {}
            }
            override fun close() { cancelled.countDown() }
        },layout)
        val thread=Thread { try { source.open().use { it.read(layout.header.size.toLong(),ByteArray(1),1) };fail() } catch(_:IOException) {} finally { finished.countDown() } }.apply { start() }
        assertTrue(entered.await(2,TimeUnit.SECONDS));source.close();assertTrue(finished.await(1,TimeUnit.SECONDS));thread.join(1000)
    }
    @Test fun forkedPlaybackLeaseSurvivesDecoderCloseButAccountRevocationClosesIt() {
        val bytes=fixture();val layout=inspect(bytes).playbackLayout!!;val resolutions=AtomicInteger()
        val upstream=CloudStreamSourceTest.HttpServer.create(InetSocketAddress("127.0.0.1",0),0)
        upstream.createContext("/file") { exchange ->
            val start=exchange.requestHeaders.getFirst("Range")!!.removePrefix("bytes=").substringBefore('-').toInt()
            exchange.responseHeaders.add("Content-Range","bytes $start-${bytes.lastIndex}/${bytes.size}")
            exchange.sendResponseHeaders(206,(bytes.size-start).toLong())
            runCatching { exchange.responseBody.use { it.write(bytes,start,bytes.size-start) } };exchange.close()
        }
        upstream.start()
        val field=CloudLibrary::class.java.getDeclaredField("activeStreams").apply { isAccessible=true }
        @Suppress("UNCHECKED_CAST") val streams=field.get(CloudLibrary) as MutableMap<String,MutableList<Pair<LocalStreamServer,String>>>
        assertTrue("Test requires exclusive cloud lease ownership",streams.isEmpty())
        try { LocalStreamServer().use { local ->
            val cloud=CloudStreamSource(bytes.size.toLong(),{
                resolutions.incrementAndGet();CloudLink("http://127.0.0.1:${upstream.address.port}/file") { emptyMap() }
            },connect={ uri -> uri.toURL().openConnection() as HttpURLConnection })
            cloud.prepare()
            val parent=local.publish(cloud,"fixture.mp4")
            streams["playback-view-test"]=arrayListOf(local to parent)
            val view=CloudLibrary.playbackView(parent,layout,local)!!
            local.revoke(parent)
            val connection=URI(view).toURL().openConnection() as HttpURLConnection
            try {
                connection.setRequestProperty("Range","bytes=${layout.header.size}-${layout.header.size+31}")
                assertEquals(206,connection.responseCode)
                val expected=bytes.copyOfRange(layout.chunks.first().origin.toInt(),layout.chunks.first().origin.toInt()+32)
                assertArrayEquals(expected,connection.inputStream.readBytes())
            } finally { connection.disconnect() }
            assertEquals("The immutable resolver/link is reused",1,resolutions.get())
            CloudLibrary.stopStreams()
            assertFalse(local.hasSource(view));assertTrue(streams.isEmpty())
            val revoked=URI(view).toURL().openConnection() as HttpURLConnection
            try { assertEquals(404,revoked.responseCode) } finally { revoked.disconnect() }
        } } finally { CloudLibrary.stopStreams();upstream.stop(0) }
    }
    /** SMB-like inputs: every reader reopens the file, so a view forks without an account boundary. */
    private class Forkable(val bytes:ByteArray, val forks:AtomicInteger):StreamSource {
        override val size=bytes.size.toLong()
        override val forkable get()=true
        override fun fork():StreamSource { forks.incrementAndGet(); return Forkable(bytes,forks) }
        override fun open()=Origin(bytes).open()
    }
    @Test fun forkableNonCloudSourceGetsPlaybackViewOwnedByItsLease() {
        val bytes=fixture();val layout=inspect(bytes).playbackLayout!!
        val forks=AtomicInteger()
        LocalStreamServer().use { local ->
            val parent=local.publish(Forkable(bytes,forks),"fixture.mp4")
            assertFalse(local.cloudBacked(parent))
            assertTrue("The read cache wraps forkable sources",local.enableInterleaveCache(parent))
            val view=local.playbackView(parent,layout)!!
            assertEquals(1,forks.get())
            local.revoke(parent)
            val connection=URI(view).toURL().openConnection() as HttpURLConnection
            try {
                connection.setRequestProperty("Range","bytes=${layout.header.size}-${layout.header.size+31}")
                assertEquals(206,connection.responseCode)
                val expected=bytes.copyOfRange(layout.chunks.first().origin.toInt(),layout.chunks.first().origin.toInt()+32)
                assertArrayEquals(expected,connection.inputStream.readBytes())
            } finally { connection.disconnect() }
            local.revoke(view); assertFalse(local.hasSource(view))
            val plain=local.publish(Origin(bytes),"plain.mp4")
            assertFalse("Plain sources keep the direct path",local.enableInterleaveCache(plain))
            assertNull(local.playbackView(plain,layout))
        }
    }
    @Test fun largeIndexCanFinishBeyondFiveSecondsWithoutExpandingTheByteBudget() {
        val small=fixture();val moovAt=java.nio.ByteBuffer.wrap(small,0,4).int+16+1440
        val bytes=small.copyOfRange(0,moovAt)+box("moov",small.copyOfRange(moovAt+8,small.size),box("free",ByteArray(4*1024*1024)))
        val upstream=CloudStreamSourceTest.HttpServer.create(InetSocketAddress("127.0.0.1",0),0)
        val starts=java.util.Collections.synchronizedList(ArrayList<Int>())
        upstream.createContext("/file") { exchange ->
            val range=exchange.requestHeaders.getFirst("Range")!!.removePrefix("bytes=").split('-')
            val start=range[0].toInt();val end=minOf(bytes.lastIndex,range[1].toInt());starts.add(start)
            exchange.responseHeaders.add("Content-Range","bytes $start-$end/${bytes.size}")
            exchange.sendResponseHeaders(206,(end-start+1).toLong())
            runCatching { exchange.responseBody.use { body ->
                var at=start
                while(at<=end) { val n=minOf(65536,end-at+1);if(start==moovAt)Thread.sleep(80);body.write(bytes,at,n);body.flush();at+=n }
            } };exchange.close()
        }
        upstream.start()
        try {
            val start=System.nanoTime()
            val result=Mp4InterleavePolicy.inspectHttp("http://127.0.0.1:${upstream.address.port}/file")
            assertTrue(result.diagnostic,result.regionCache);assertNotNull(result.playbackLayout)
            assertTrue((System.nanoTime()-start)/1e9>=5)
            assertEquals(listOf(0,moovAt),starts)
            assertTrue(bytes.size< Mp4InterleavePolicy.MAX_METADATA_BYTES)
        } finally { upstream.stop(0) }
    }
}
