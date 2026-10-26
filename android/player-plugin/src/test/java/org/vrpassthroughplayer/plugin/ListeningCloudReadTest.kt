package org.vrpassthroughplayer.plugin

import org.junit.Assert.*
import org.junit.Test
import java.io.IOException
import java.io.InputStream
import java.net.HttpURLConnection
import java.net.URI
import java.util.concurrent.Executors
import java.util.concurrent.CountDownLatch
import java.util.concurrent.TimeUnit
import java.util.concurrent.atomic.AtomicInteger

class ListeningCloudReadTest {
    /** A CDN slot remains occupied until its body/connection is closed, even if
     * the local client is paused. Byte patterns validate seeks across >4 GiB. */
    private class Cdn {
        val size = 5L * 1024 * 1024 * 1024
        val active = AtomicInteger(); val peak = AtomicInteger(); val requests = AtomicInteger()
        val resolutions = AtomicInteger(); val rejected = AtomicInteger()
        @Volatile var limit = 2
        @Volatile var block = false
        @Volatile var readDelayMs = 0L
        @Volatile var headerDelayMs = 0L
        @Volatile var maxRead = Int.MAX_VALUE
        @Volatile var failRead = -1
        val reads = AtomicInteger()
        val entered = CountDownLatch(1); val released = CountDownLatch(1)
        fun connection(uri: URI) = object : HttpURLConnection(uri.toURL()) {
            private var acquired = false
            private var done = false
            private var start = 0L
            override fun connect() {}
            override fun usingProxy() = false
            @Synchronized override fun disconnect() { done = true; released.countDown(); if(acquired) {acquired=false; active.decrementAndGet()} }
            override fun getResponseCode(): Int {
                requests.incrementAndGet()
                start = getRequestProperty("Range").substringAfter("bytes=").substringBefore('-').toLong()
                val count = active.incrementAndGet()
                if(count > limit) { active.decrementAndGet(); rejected.incrementAndGet(); return 403 }
                acquired = true; peak.accumulateAndGet(count, ::maxOf)
                if(headerDelayMs>0)Thread.sleep(headerDelayMs)
                return 206
            }
            override fun getHeaderField(name: String): String? = when(name) {
                "Content-Range" -> "bytes $start-${size-1}/$size"
                "Content-Length" -> "${size-start}"
                "X-Thru3D-Upstream-Reason" -> if(!acquired) "cdn_connections_limited" else null
                else -> null
            }
            override fun getContentType() = "application/octet-stream"
            override fun getInputStream() = object : InputStream() {
                private var at = start
                override fun read(): Int { check(!done); return ((at++) % 251).toInt() }
                override fun read(b: ByteArray, off: Int, len: Int): Int {
                    if(reads.incrementAndGet() in failRead..failRead+1)throw IOException("Interrupted speculative read")
                    if(block){entered.countDown();check(released.await(5,TimeUnit.SECONDS))}
                    if(readDelayMs>0)Thread.sleep(readDelayMs)
                    if(done) throw IOException("Cancelled")
                    val n=minOf(len.toLong(),size-at,maxRead.toLong()).toInt()
                    for(i in 0 until n) b[off+i]=((at+i)%251).toByte()
                    at+=n;return n
                }
                override fun close() { disconnect() }
            }
        }
        fun source() = CloudStreamSource(size, { resolutions.incrementAndGet(); CloudLink("https://fixture.invalid/media") { emptyMap() } }, ::connection)
    }
    private fun verify(reader: StreamSource.Reader, offset: Long, count: Int = 4096) {
        val bytes=ByteArray(count); var at=offset
        while(at < offset+count) {
            val n=reader.read(at,bytes,minOf(count.toLong(),offset+count-at).toInt())
            assertTrue(n>0)
            for(i in 0 until n) assertEquals(((at+i)%251).toByte(),bytes[i])
            at+=n
        }
    }
    @Test fun activationRetiresExistingPlaybackAndParkedBodiesBeforeAsrConnects() {
        val cdn=Cdn();val meter=TransferMeter()
        cdn.source().use { origin ->
            AdaptiveInterleaveSource(origin,meter).use { source ->
                val playing=source.open();verify(playing,0)
                // A completed bounded segment is parked and still occupies a CDN slot.
                source.open().use { (it as BoundedStreamReader).setRangeEnd(90_000_000+4095);verify(it,90_000_000) }
                assertEquals(2,cdn.active.get())
                source.shareReadAhead {meter.add(it)}
                assertEquals(0,cdn.active.get());cdn.limit=2;cdn.peak.set(0)
                source.open().use { asr ->
                    verify(asr,0);verify(playing,4096);verify(asr,8192)
                    assertEquals(1,cdn.active.get())
                    val before=cdn.requests.get();verify(asr,0)
                    assertEquals(before,cdn.requests.get())
                    // Existing playback reader transparently migrates, including seek/large offsets.
                    verify(playing,4_500_000_123);verify(asr,0);verify(playing,4_500_000_123)
                }
                playing.close()
                assertTrue(cdn.peak.get()<=2);assertEquals(0,cdn.rejected.get())
                assertEquals(1,cdn.resolutions.get())
                assertTrue(origin.readAheadStats()!!.getValue("capacity_bytes") <= 32L*1024*1024)
                assertTrue(origin.readAheadStats()!!.getValue("cached_bytes") > 0)
                assertEquals(origin.readAheadStats()!!.getValue("upstream_bytes"),meter.snapshot().bytes)
            }
        }
        assertEquals(0,cdn.active.get())
    }
    @Test fun parallelClientsNeverExceedTwoOriginsAndClosedClientsCannotRead() {
        val cdn=Cdn();cdn.limit=2
        cdn.source().use { source ->
            source.shareReadAhead()
            val pool=Executors.newFixedThreadPool(3)
            try {
                (0..2).map { client -> pool.submit {
                    source.open().use { reader -> repeat(12) { verify(reader,client*200_000_000L+it*65536) } }
                } }.forEach { it.get(15,TimeUnit.SECONDS) }
                val closed=source.open();closed.close()
                assertThrows(PlaybackFailureException::class.java) {closed.read(0,ByteArray(1),1)}
                assertTrue(cdn.peak.get()<=2);assertEquals(0,cdn.rejected.get())
            } finally {pool.shutdownNow()}
        }
        assertEquals(0,cdn.active.get())
    }
    @Test fun activatingDuringStalledOriginKeepsOneSlotAndMigratesTheExistingClient() {
        val cdn=Cdn();cdn.limit=2;cdn.block=true
        cdn.source().use { source -> source.open().use { old ->
            val pool=Executors.newFixedThreadPool(2)
            try {
                val pending=pool.submit {verify(old,0)}
                assertTrue(cdn.entered.await(2,TimeUnit.SECONDS))
                pool.submit {source.shareReadAhead()}.get(1,TimeUnit.SECONDS)
                pending.get(1,TimeUnit.SECONDS)
                verify(old,65536)
                assertTrue(cdn.peak.get()<=2);assertEquals(0,cdn.rejected.get())
            } finally {source.close();pool.shutdownNow();pool.awaitTermination(2,TimeUnit.SECONDS)}
        } }
        assertEquals(0,cdn.active.get())
    }
    @Test fun healthyConnectionSetupIsNotRepeatedlyCancelledByParallelSmallReads() {
        val cdn=Cdn();cdn.limit=2;cdn.headerDelayMs=150
        cdn.source().use {source ->
            source.shareReadAhead();val pool=Executors.newFixedThreadPool(3)
            try {
                (0..2).map {client ->pool.submit {
                    source.open().use {reader ->repeat(12){verify(reader,client*200_000_000L+it*4096)}}
                }}.forEach {it.get(5,TimeUnit.SECONDS)}
                assertTrue("Healthy headers were cancelled: ${cdn.requests.get()} opens",cdn.requests.get()<=4)
                assertTrue(cdn.peak.get()<=2);assertEquals(0,cdn.rejected.get())
            } finally {source.close();pool.shutdownNow();pool.awaitTermination(2,TimeUnit.SECONDS)}
        }
        assertEquals(0,cdn.active.get())
    }
    @Test fun playbackHitsDoNotWaitForDistantAsrConnectionSetup() {
        // Bytes already in RAM must not queue behind another demand's origin
        // IO. Formerly a hit waited for the ASR header (or the 750-ms stall
        // grace), so catching-up ASR throttled playback to one read per open.
        val cdn=Cdn();cdn.limit=2;cdn.headerDelayMs=1500
        cdn.source().use {source ->
            source.shareReadAhead();val pool=Executors.newSingleThreadExecutor()
            try {
                source.open().use { playback ->
                    verify(playback,0,65536) // fills the 2-MiB read-ahead block
                    val asr=pool.submit { source.openAudio().use { verify(it,300_000_000L,32768) } }
                    val deadline=System.nanoTime()+1_000_000_000L
                    while(cdn.requests.get()<2 && System.nanoTime()<deadline) Thread.sleep(5)
                    assertEquals(2,cdn.requests.get()) // ASR is now waiting for its header
                    val started=System.nanoTime()
                    var at=65536L
                    while(at<1L shl 20){verify(playback,at,65536);at+=65536}
                    val elapsed=(System.nanoTime()-started)/1_000_000
                    assertTrue("Cached playback waited $elapsed ms",elapsed<300)
                    asr.get(5,TimeUnit.SECONDS)
                }
                assertTrue(cdn.peak.get()<=2);assertEquals(0,cdn.rejected.get())
            } finally {source.close();pool.shutdownNow();pool.awaitTermination(2,TimeUnit.SECONDS)}
        }
        assertEquals(0,cdn.active.get())
    }
    @Test fun playbackAndDistantAsrKeepTheirOwnOrigins() {
        // Late enable: MPV streams ~17 s ahead while ASR reads from the clock.
        // With one origin each turn reconnected the other (v6 device: ASR
        // advanced 1 s per 5 s and the video cache drained to zero).
        val cdn=Cdn();cdn.headerDelayMs=300
        var video=0L;var chunks=0
        cdn.source().use {source ->
            source.shareReadAhead();val pool=Executors.newFixedThreadPool(2)
            val end=System.nanoTime()+3_000_000_000L
            try {
                val playback=pool.submit { source.open().use { reader -> val bytes=ByteArray(65536)
                    while(System.nanoTime()<end) video+=reader.read(video,bytes,bytes.size) } }
                val asr=pool.submit { source.openAudio().use { reader ->
                    while(System.nanoTime()<end) verify(reader,300_000_000L+chunks++*1_000_000L,32768) } }
                playback.get(10,TimeUnit.SECONDS);asr.get(10,TimeUnit.SECONDS)
            } finally {source.close();pool.shutdownNow();pool.awaitTermination(2,TimeUnit.SECONDS)}
        }
        assertEquals("Each stream keeps one body",2,cdn.requests.get())
        assertTrue(cdn.peak.get()<=2);assertEquals(0,cdn.rejected.get())
        assertTrue("Playback read only $video bytes",video>=64L*1024*1024)
        assertEquals(0,cdn.active.get())
    }
    @Test fun aCdnAllowingOneBodyDegradesToOneSharedOrigin() {
        // Another body (a parent source, another client) may hold one of the
        // two slots. The lease continues on one origin instead of failing.
        val cdn=Cdn();cdn.limit=1
        cdn.source().use {source ->
            source.shareReadAhead()
            source.open().use {playback -> source.openAudio().use {asr ->
                verify(playback,0)
                verify(asr,300_000_000L)
                repeat(3){verify(playback,4096L*(it+1));verify(asr,300_000_000L+4096L*(it+1))}
            }}
            assertEquals(1,cdn.peak.get())
        }
        assertEquals(0,cdn.active.get())
    }
    @Test fun distantMetadataAndPlaybackDoNotReconnectForEverySmallFfmpegRead() {
        val cdn=Cdn();cdn.limit=2
        cdn.source().use {source ->
            source.shareReadAhead()
            source.open().use {video -> source.open().use {metadata ->
                repeat(20){
                    verify(video,it*4096L)
                    verify(metadata,100_000_000L+it*4096)
                }
            } }
            // The former 64-KiB demand fills reopened the one CDN slot on every
            // alternation. At 500 ms per connection a normal moov exceeded 15 s.
            assertEquals(2,cdn.requests.get())
            assertTrue(cdn.peak.get()<=2)
            assertEquals(0,cdn.rejected.get())
            assertEquals(4L*1024*1024,source.readAheadStats()!!.getValue("upstream_bytes"))
        }
        assertEquals(0,cdn.active.get())
    }
    @Test fun sharingIsPerLeaseAndDoesNotEnableArchiveOrReferenceTransfers() {
        val cdn=Cdn()
        cdn.source().use { first -> cdn.source().use { other ->
            first.shareReadAhead();assertTrue(first.sharedReadAheadActive);assertFalse(other.sharedReadAheadActive)
        } }
        cdn.source().forArchiveReading().use { it.shareReadAhead();assertFalse(it.sharedReadAheadActive) }
        cdn.source().boundedRanges(65536).use { it.shareReadAhead();assertFalse(it.sharedReadAheadActive) }
    }
    @Test fun headerIndexPlaybackAndAudioWindowsDoNotEvictEachOther() {
        val cdn=Cdn();cdn.limit=2
        cdn.source().use {source ->
            source.shareReadAhead()
            val readers=(0..3).map {source.open()}
            val positions=listOf(0L,100_000_000L,1_000_000_000L,4_000_000_000L)
            try {repeat(20){i ->readers.forEachIndexed {index,reader ->verify(reader,positions[index]+i*4096)}}}
            finally {readers.forEach {it.close()}}
            assertEquals(4,cdn.requests.get());assertTrue(cdn.peak.get()<=2)
            assertEquals(32L*1024*1024,source.readAheadStats()!!.getValue("capacity_bytes"))
        }
    }
    @Test fun playbackAudioSurvivesTransportEvictionWithLateArrivingIndex() {
        val cdn=Cdn();cdn.limit=2
        cdn.source().use {source ->
            source.shareReadAhead()
            source.open().use {video ->
                verify(video,0)
                source.retainAudio(listOf(AudioReadSpan(0,4096),AudioReadSpan(30_000_000,30_004_096)))
                verify(video,30_000_000)
                for(i in 1..5)verify(video,i*100_000_000L)
                val before=cdn.requests.get()
                source.open().use {asr ->verify(asr,0);verify(asr,30_000_000)}
                assertEquals("ASR must reuse compressed audio after video windows advance",before,cdn.requests.get())
                val stats=source.readAheadStats()!!
                assertEquals(8192L,stats.getValue("audio_cached_bytes"))
                assertTrue(stats.getValue("audio_payload_bytes")<=8L*1024*1024)
                assertTrue(stats.getValue("capacity_bytes")<=32L*1024*1024)
            }
        }
    }
    @Test fun slowPrefetchYieldsRequestedBytesInsteadOfHoldingThemForTheWholeBlock() {
        val cdn=Cdn();cdn.limit=2;cdn.readDelayMs=10;cdn.maxRead=8192
        cdn.source().use {source ->
            source.shareReadAhead()
            val began=System.nanoTime()
            source.open().use {verify(it,0)}
            // A full speculative 2 MiB takes 2.56 s on this link. The requested
            // 4 KiB is already available and must reach FFmpeg promptly.
            // The cloud burst budget is 500 ms plus the demanded and final
            // in-flight reads. Cached audio bypasses this IO lock.
            assertTrue("Speculative fill withheld requested audio",System.nanoTime()-began<800_000_000)
            assertTrue(source.readAheadStats()!!.getValue("upstream_bytes")<2L*1024*1024)
        }
    }
    @Test fun failedSpeculationPreservesAlreadyReadBytesAndReconnectsOnNextDemand() {
        val cdn=Cdn();cdn.limit=2;cdn.failRead=2
        cdn.source().use {source ->
            source.shareReadAhead()
            source.open().use {reader ->
                verify(reader,0)
                assertEquals(2,cdn.requests.get()) // origin's one retry also fails
                verify(reader,4096)
                assertEquals(3,cdn.requests.get())
                verify(reader,0)
                assertEquals(3,cdn.requests.get())
            }
        }
    }
    @Test fun closingTheLeaseCancelsBlockedSharedIoBeforeWaitingForCacheLock() {
        val cdn=Cdn();cdn.block=true
        val source=cdn.source();source.shareReadAhead()
        val pool=Executors.newSingleThreadExecutor()
        try {
            val read=pool.submit {source.open().use {verify(it,0)}}
            assertTrue(cdn.entered.await(3,TimeUnit.SECONDS))
            val closing=System.nanoTime()
            source.close()
            assertTrue("Close must interrupt IO, not wait for its timeout",System.nanoTime()-closing<500_000_000)
            assertThrows(java.util.concurrent.ExecutionException::class.java){read.get(3,TimeUnit.SECONDS)}
            assertEquals(0,cdn.active.get())
        } finally {source.close();pool.shutdownNow()}
    }
    @Test fun busySourcesAreNotReportedAsModelFailures() {
        val failure=PlaybackFailure.http(403).copy(sourceCode="cdn_connections_limited")
        assertEquals("source_busy",ListeningPolicy.failureState("audio_open",failure))
        assertEquals("source_busy",ListeningPolicy.failureState("recognition",failure))
        assertEquals("source_error",ListeningPolicy.failureState("audio_open",PlaybackFailure.http(404)))
        assertEquals("audio_error",ListeningPolicy.failureState("audio_open",null))
        assertEquals("listening_error",ListeningPolicy.failureState("model_load",failure))
    }
}
