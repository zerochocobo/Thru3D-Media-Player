package org.vrpassthroughplayer.plugin

import java.io.IOException
import java.util.concurrent.ConcurrentHashMap
import java.util.concurrent.locks.ReentrantLock
import java.util.concurrent.atomic.AtomicLong
import java.util.concurrent.ScheduledThreadPoolExecutor
import java.util.concurrent.TimeUnit
import kotlin.concurrent.withLock

/** Counts origin reads itself; loopback cache hits are not network traffic. */
internal interface UpstreamMeteredReader : StreamSource.Reader

/** An origin reader that can tell whether it is still waiting for response headers. */
internal interface OriginProgress { val awaitingResponse: Boolean }

/** Opt-in, source-lifetime read windows. A demuxer's alternating HTTP clients must
 * not throw away the other track's CDN connection and bytes on every close.
 * Two 8-MiB windows cover curl's 4-MiB producer buffer plus socket read-ahead.
 * No disk cache, full-file download, background reader or decoder-policy change. */
internal class InterleaveReadCache(private val source: StreamSource,
    private val windowBytes: Int = 8 * 1024 * 1024,
    private val onRead: (Int) -> Unit = {}, audioChunks: List<AudioReadSpan> = emptyList(),
    private val maxForwardGapBytes: Int = windowBytes,
    /** 0: one origin reader per window. Otherwise at most this many concurrent
     * origin bodies on a connection-limited CDN; only stalled reads are preempted. */
    private val upstreams: Int = 0,
    private val readAheadBytes: Int = 64 * 1024,
    private val windowCount: Int = 2,
    private val readAheadBudgetMs: Long = 100) : StreamSource {
    override val size get() = source.size
    @Volatile private var closed = false
    private val lock = ReentrantLock(true)
    private val windows = ArrayList<Window>(windowCount)
    private val scratch = ByteArray(64 * 1024)
    private val ioDone = lock.newCondition()
    private val limited get() = upstreams > 0
    // Lowered for this media lease once the CDN reports its connection limit.
    private var upstreamCap = upstreams
    private var clock = 0L
    private class YieldRead : IOException("Shared upstream yielded")
    private class Demand(val owner: Any)
    private class Flight(val reader: StreamSource.Reader, val demand: Demand, val speculative: Boolean) {
        val startedAt = System.nanoTime()
        @Volatile var yielded = false
        @Volatile var finished = false
        /** Healthy reads return within these bounds; only a stalled one yields the origin. */
        fun stalled(now: Long) = now - startedAt > if ((reader as? OriginProgress)?.awaitingResponse == true) RESPONSE_GRACE_NS else BODY_GRACE_NS
    }
    private val flights = ConcurrentHashMap.newKeySet<Flight>()
    @Volatile private var upstreamBytes = 0L
    private val cachedBytes = AtomicLong()
    @Volatile private var opens = 0L
    private var audioSpans = audioChunks
    @Volatile private var audioPackets = audioChunks.takeIf { it.isNotEmpty() }?.let { Mp4AudioPacketCache(it) }
    private val audioCachedBytes = AtomicLong()
    // Approximate counters only: clock/UI diagnostics must never wait on IO.
    override fun readSnapshot() = mapOf("upstream_bytes" to upstreamBytes,"cached_bytes" to cachedBytes.get(),
        "reader_opens" to opens,"audio_cached_bytes" to audioCachedBytes.get())
    private class Window(val bytes: ByteArray, var reader: StreamSource.Reader?, var start: Long) {
        var end = start
        var used = 0L
        /** The one demand reading origin bytes into this window; only it moves end. */
        var owner: Demand? = null
        /** Filled outside the gate by the owner only. */
        val io = ByteArray(64 * 1024)
    }
    init { require(windowCount in 1..4 && upstreams in 0..windowCount && windowBytes >= scratch.size && maxForwardGapBytes in 0..windowBytes && readAheadBytes in scratch.size..windowBytes && readAheadBudgetMs in 1..500) }

    override fun retainAudio(spans: List<AudioReadSpan>) = lock.withLock {
        if(closed || spans.isEmpty() || spans==audioSpans)return@withLock
        audioPackets?.close();audioSpans=spans
        val packets=Mp4AudioPacketCache(spans);audioPackets=packets
        // Metadata arrives after opening the audio demuxer. Seed it with bytes
        // already fetched by playback before retaining future compressed audio.
        for(window in windows){
            var at=window.start
            while(at<window.end){
                val index=(at%windowBytes).toInt()
                val n=minOf(window.end-at,scratch.size.toLong(),(windowBytes-index).toLong()).toInt()
                window.bytes.copyInto(scratch,0,index,index+n);packets.capture(at,scratch,n);at+=n
            }
        }
    }

    fun stats(): Map<String, Long> = lock.withLock {
        mapOf("upstream_bytes" to upstreamBytes, "cached_bytes" to cachedBytes.get(),
            "reader_opens" to opens, "capacity_bytes" to windows.size.toLong() * windowBytes,
            "active_readers" to windows.count { it.reader != null }.toLong(),
            "audio_payload_bytes" to (audioPackets?.sizeBytes() ?: 0L), "audio_cached_bytes" to audioCachedBytes.get())
    }
    fun cachedAudioEnd(offset: Long): Long? = lock.withLock { audioPackets?.end(offset) }

    override fun open(): StreamSource.Reader = openReader(false)
    override fun openAudio(): StreamSource.Reader = openReader(true)
    private fun openReader(audioOnly: Boolean): StreamSource.Reader {
        check(!closed)
        return object : UpstreamMeteredReader {
            @Volatile private var done = false
            @Volatile private var packetHits=0L
            @Volatile private var windowHits=0L
            @Volatile private var misses=0L
            override fun counters()=mapOf("packet_bytes" to packetHits,"window_bytes" to windowHits,"misses" to misses)
            private var logicalNext = -1L
            private fun cancelled() = closed || done || Thread.currentThread().isInterrupted
            override fun read(offset: Long, buffer: ByteArray, length: Int): Int {
                val demand = Demand(this)
                while (true) {
                    try { return readOnce(offset, buffer, length, demand) }
                    catch (_: YieldRead) {
                        // A stalled origin read was cancelled. Retry through the
                        // gate, retaining already cached bytes.
                        if (cancelled()) throw IOException("Request cancelled")
                    }
                }
            }
            private fun readOnce(offset: Long, buffer: ByteArray, length: Int, demand: Demand): Int {
                if (cancelled()) throw IOException("Request cancelled")
                require(offset in 0 until size && length in 1..buffer.size)
                if(audioOnly){
                    // Packet storage has its own short copy lock and never
                    // performs IO while holding that lock.
                    val count=audioPackets?.read(offset,buffer,length) ?: 0
                    if(count>0){
                        if(closed||done)throw IOException("Request cancelled")
                        cachedBytes.addAndGet(count.toLong());audioCachedBytes.addAndGet(count.toLong())
                        packetHits+=count
                        logicalNext=offset+count;return count
                    }
                }
                try { lock.lockInterruptibly() } catch (_: InterruptedException) {
                    Thread.currentThread().interrupt(); throw IOException("Request cancelled")
                }
                try {
                    while (true) {
                        if (cancelled()) throw IOException("Request cancelled")
                        hit(offset, buffer, length)?.let { return it }
                        // The gate is never held across origin IO, so cached
                        // bytes stay available while other windows fill.
                        val window = claim(offset)
                        if (window != null) {
                            window.owner = demand
                            try { return miss(window, offset, buffer, length, demand) }
                            finally { window.owner = null; ioDone.signalAll() }
                        }
                        // Every usable origin is busy. Preempt only a stalled read.
                        if (limited) flights.firstOrNull { it.demand !== demand && it.stalled(System.nanoTime()) }?.let {
                            lock.unlock()
                            try { yieldFlight(it) } finally { lock.lock() }
                        }
                        try { ioDone.await(10, TimeUnit.MILLISECONDS) } catch (_: InterruptedException) {
                            Thread.currentThread().interrupt(); throw IOException("Request cancelled")
                        }
                    }
                } finally { lock.unlock() }
            }
            /** Caller holds the gate. */
            private fun hit(offset: Long, buffer: ByteArray, length: Int): Int? {
                // An ongoing video response must consume its existing upstream
                // through audio too; skipping those bytes would force a new
                // CDN connection at the next video byte.
                val continuing = !audioOnly && audioPackets != null && logicalNext == offset && windows.any { offset >= it.start && offset <= it.end }
                val audio = if (!continuing) audioPackets?.read(offset, buffer, length) ?: 0 else 0
                if (audio > 0) {
                    cachedBytes.addAndGet(audio.toLong()); audioCachedBytes.addAndGet(audio.toLong())
                    packetHits+=audio
                    logicalNext = offset + audio
                    return audio
                }
                val window = windows.firstOrNull { offset >= it.start && offset < it.end } ?: return null
                window.used = ++clock
                val at = (offset % windowBytes).toInt()
                val n = minOf(length.toLong(), window.end - offset, (windowBytes - at).toLong()).toInt()
                window.bytes.copyInto(buffer, 0, at, at + n)
                audioPackets?.capture(offset, buffer, n)
                cachedBytes.addAndGet(n.toLong())
                windowHits+=n
                logicalNext = offset + n
                return n
            }
            /** Caller holds the gate and owns origin IO on the window. */
            private fun miss(window: Window, offset: Long, buffer: ByteArray, length: Int, demand: Demand): Int {
                window.used = ++clock
                misses++
                try {
                    while (window.end < offset)
                        fill(window, minOf(offset - window.end, window.io.size.toLong()).toInt(), demand)
                    val wanted = minOf(length.toLong(), window.io.size.toLong(), size - offset).toInt()
                    val n = fill(window, wanted, demand)
                    window.io.copyInto(buffer, 0, 0, n)
                    // A CDN slot cannot alternate distant metadata/audio/video
                    // ranges for every 32-KiB FFmpeg read. Fetch a bounded block per
                    // connection; other readers keep hitting RAM meanwhile.
                    val aheadEnd = minOf(size, offset + readAheadBytes)
                    // Speculation must not withhold already-read bytes or monopolize
                    // a slow link. Fast links fill the block; slow links yield after
                    // a short burst to the other consumer.
                    val aheadDeadline = System.nanoTime() + readAheadBudgetMs*1_000_000
                    try {
                        while (readAheadBytes > window.io.size && window.end < aheadEnd && System.nanoTime() < aheadDeadline) {
                            if (cancelled()) throw IOException("Request cancelled")
                            fill(window, minOf(aheadEnd - window.end, window.io.size.toLong()).toInt(), demand, aheadDeadline)
                        }
                    } catch (_: Exception) {
                        // A speculative read cannot invalidate bytes already copied
                        // to the caller. Retain the window and reconnect only when
                        // a later demand actually reaches the interrupted range.
                        runCatching { window.reader?.close() }; window.reader = null
                    }
                    if (cancelled()) throw IOException("Request cancelled")
                    logicalNext = offset + n
                    return n
                } catch (error: YieldRead) {
                    throw error
                } catch (error: Exception) {
                    windows.remove(window)
                    runCatching { window.reader?.close() }
                    throw error
                }
            }
            // This HTTP client may disappear after one audio packet. The shared
            // windows belong to the media lease, not to that transient client.
            override fun close() { done = true; flights.filter { it.demand.owner === this }.forEach { yieldFlight(it) } }
        }
    }

    /** Caller holds the gate. The window this offset extends (or a new one) with
     * an origin slot available, or null while every usable origin is busy. */
    private fun claim(offset: Long): Window? {
        var window = windows.firstOrNull { offset == it.end }
        if (window == null && (audioPackets != null || limited)) {
            // MOV can skip tiny AAC between video packets, or video
            // between tiny AAC packets. Both readers retain their
            // connections by consuming a bounded forward gap. Every
            // byte remains real and is metered/cached as usual. ISO
            // and sources without an audio index keep their old path.
            window = windows.filter { it.end < offset && offset - it.end <= maxForwardGapBytes }
                .maxByOrNull { it.end }
        }
        if (window?.owner != null) return null
        if (window == null) {
            val storage = if (windows.size == windowCount) {
                val old = windows.filter { it.owner == null }.minByOrNull { it.used } ?: return null
                windows.remove(old)
                old.reader?.close()
                old.bytes
            } else ByteArray(windowBytes)
            window = Window(storage, null, offset)
            windows.add(window)
        }
        if (limited && window.reader == null && windows.count { it.reader != null } >= upstreamCap) {
            // Keep the busiest streams (playback, ASR) on their own bodies;
            // retire the least recently used idle one for this new range.
            val idle = windows.filter { it !== window && it.reader != null && it.owner == null }.minByOrNull { it.used } ?: return null
            idle.reader?.close(); idle.reader = null
        }
        return window
    }

    private fun yieldFlight(active: Flight) = synchronized(active) {
        if (!active.finished && !active.yielded) {
            active.yielded = true
            // close sets RemoteReader.done before disconnecting, preventing its
            // idle-body reconnect from resurrecting the cancelled origin.
            runCatching { active.reader.close() }
        }
    }

    /** Caller holds the gate and owns origin IO on the window. The gate is released
     * only around the network read itself; bytes are committed under it. */
    private fun fill(window: Window, wanted: Int, demand: Demand, deadline: Long = Long.MAX_VALUE, retried: Boolean = false): Int {
        if (window.reader == null) { window.reader = source.open(); opens++ }
        val offset = window.end
        val reader = window.reader!!
        val active = Flight(reader, demand, deadline != Long.MAX_VALUE)
        flights.add(active)
        // Bound each speculative read itself, not just the gap between reads.
        val timeout = if (limited && active.speculative) cancellations.schedule(
            { yieldFlight(active) }, maxOf(0L, deadline - System.nanoTime()), TimeUnit.NANOSECONDS) else null
        var n = 0
        var failure: Exception? = null
        lock.unlock()
        try { n = reader.read(offset, window.io, wanted) }
        catch (error: Exception) { failure = error }
        finally { lock.lock() }
        timeout?.cancel(false)
        synchronized(active) { active.finished = true }
        flights.remove(active)
        if (active.yielded) window.reader = null
        if (closed) throw IOException("Request cancelled")
        if (failure != null) {
            if (active.yielded) throw YieldRead()
            if (!retried && upstreamCap > 1 && (failure as? PlaybackFailureException)?.failure?.sourceCode == "cdn_connections_limited") {
                // Another body (another app, a parent source's parked read) holds
                // a slot. Continue this lease on one origin instead of failing.
                upstreamCap = 1
                window.reader = null
                windows.filter { it !== window && it.owner == null }.forEach { it.reader?.close(); it.reader = null }
                if (windows.none { it !== window && it.reader != null }) return fill(window, wanted, demand, deadline, true)
            }
            throw failure
        }
        if (n !in 1..wanted) throw IOException("Invalid upstream read")
        val at = (offset % windowBytes).toInt()
        val first = minOf(n, windowBytes - at)
        window.io.copyInto(window.bytes, at, 0, first)
        if (first < n) window.io.copyInto(window.bytes, 0, first, n)
        window.end = offset + n
        window.start = maxOf(window.start, window.end - windowBytes)
        audioPackets?.capture(offset, window.io, n)
        upstreamBytes += n
        onRead(n)
        ioDone.signalAll() // Waiters may now hit these bytes.
        return n
    }

    override fun close() {
        closed = true
        // Cancel upstream IO before waiting for the cache lock held by a read.
        try { source.close() } finally {
            lock.withLock {
                windows.forEach { runCatching { it.reader?.close() }; it.bytes.fill(0) }
                windows.clear()
                audioPackets?.close()
            }
        }
    }
    companion object {
        // 115 responses through the loopback proxy can take ~0.5 s to start.
        private const val RESPONSE_GRACE_NS = 750_000_000L
        private const val BODY_GRACE_NS = 300_000_000L
        private val cancellations = ScheduledThreadPoolExecutor(1) { task ->
            Thread(task, "SharedReadBudget").apply { isDaemon = true }
        }.apply { removeOnCancelPolicy = true }
    }
}

/** Ordinary sources delegate unchanged until structural inspection opts in. */
internal class AdaptiveInterleaveSource(private val source: StreamSource,
    private val meter: TransferMeter? = null, private val parkedIdleNs: Long = PARKED_IDLE_NS) : StreamSource {
    override val size get() = source.size
    override fun shareReadAhead(onRead: (Int) -> Unit) = source.shareReadAhead(onRead)
    override fun retainAudio(spans: List<AudioReadSpan>) { if(cache==null)source.retainAudio(spans) else cache?.retainAudio(spans) }
    override val sharedReadAheadActive get() = source.sharedReadAheadActive
    override fun readSnapshot(): Map<String,Long> = source.readSnapshot() + (cache?.readSnapshot()?.mapKeys {"view_"+it.key} ?: emptyMap())
    @Volatile private var cache: InterleaveReadCache? = null
    @Volatile private var closed = false
    // MPV curl ends a bounded request every 32 MiB (about 2.5 s of 100 Mbit/s
    // video). A cloud reader released exactly there continues the same upstream
    // range for the next request instead of a new proxy/CDN connection with TLS
    // and slow start. Only the exact next byte reuses it; seeks open as before.
    private class Parked(val reader: StreamSource.Reader, val next: Long, val at: Long)
    private val parked = ArrayList<Parked>(PARKED_READERS)
    private var continuedReads = 0L
    @Synchronized fun enable(audioChunks: List<AudioReadSpan> = emptyList()): Boolean {
        if (closed) return false
        if (cache == null) {
            releaseParked()
            cache = InterleaveReadCache(source, onRead = { if (!source.sharedReadAheadActive) meter?.add(it) }, audioChunks = audioChunks)
        }
        return true
    }
    fun stats(): Map<String, Long>? = cache?.stats()
    val cloud get() = source is CloudStreamSource
    @Synchronized fun forkOrigin(): StreamSource? = if (closed) null else source.fork()
    fun responseEnd(offset: Long, requestedEnd: Long): Long =
        cache?.cachedAudioEnd(offset)?.let { minOf(requestedEnd, it - 1) } ?: requestedEnd
    override fun open(): StreamSource.Reader {
        check(!closed)
        cache?.let { return it.open() }
        return if ((source as? CloudStreamSource)?.continuable == true) ContinuingReader() else source.open()
    }
    override fun openAudio(): StreamSource.Reader {check(!closed);return cache?.openAudio() ?: source.openAudio()}
    override fun close() {
        val active = synchronized(this) { closed = true; releaseParked(); cache }
        if (active == null) source.close() else active.close()
    }
    @Synchronized private fun take(offset: Long): StreamSource.Reader? {
        val now = System.nanoTime()
        // An idle CDN body may have been dropped without FIN; never wait on it.
        parked.removeAll { (now - it.at > parkedIdleNs).also { stale -> if (stale) runCatching { it.reader.close() } } }
        val match = parked.firstOrNull { it.next == offset }
        if (match == null) {
            // A seek or new consumer. 115 allows two long bodies per file
            // ("pmt 3-2"); idle parked bodies must yield their CDN slots.
            releaseParked(); return null
        }
        parked.remove(match); continuedReads++
        return match.reader
    }
    private fun park(reader: StreamSource.Reader, next: Long) {
        val keep = synchronized(this) {
            if (closed || cache != null) false else {
                if (parked.size >= PARKED_READERS) parked.removeAt(0).reader.let { runCatching { it.close() } }
                val entry = Parked(reader, next, System.nanoTime())
                parked.add(entry)
                // A source that receives no further request (the parent once
                // MPV reads a playback view) must still free its CDN slot.
                expiry.schedule({ expire(entry) }, parkedIdleNs, TimeUnit.NANOSECONDS); true
            }
        }
        if (!keep) runCatching { reader.close() }
    }
    private fun expire(entry: Parked) {
        if (synchronized(this) { parked.remove(entry) }) runCatching { entry.reader.close() }
    }
    private fun releaseParked() { parked.forEach { runCatching { it.reader.close() } }; parked.clear() }
    @Synchronized fun continuedReads() = continuedReads

    private inner class ContinuingReader : BoundedStreamReader {
        private var reader: StreamSource.Reader? = null
        private var next = -1L
        private var rangeEnd = -1L
        private var failed = false
        @Volatile private var done = false
        override fun setRangeEnd(endInclusive: Long) {
            rangeEnd = endInclusive
            (reader as? BoundedStreamReader)?.setRangeEnd(endInclusive)
        }
        override fun read(offset: Long, buffer: ByteArray, length: Int): Int {
            if (done) throw IOException("Request cancelled")
            val current = reader ?: (take(offset) ?: source.open()).also { reader = it }
            try {
                val count = current.read(offset, buffer, length)
                next = offset + count
                return count
            } catch (error: Exception) { failed = true; throw error }
        }
        override fun close() {
            if (done) return
            done = true
            val current = reader ?: return
            reader = null
            // Only a completed bounded segment continues. A client that left
            // mid-body (an MPV seek) never returns to this byte.
            if (failed || next < 0 || next >= size || next != rangeEnd + 1) runCatching { current.close() } else park(current, next)
        }
    }
    private companion object {
        const val PARKED_READERS = 2 // video plus one alternating reader (narration, subtitles)
        const val PARKED_IDLE_NS = 15_000_000_000L
        val expiry = ScheduledThreadPoolExecutor(1) { task ->
            Thread(task, "ParkedOriginExpiry").apply { isDaemon = true }
        }.apply { removeOnCancelPolicy = true }
    }
}
