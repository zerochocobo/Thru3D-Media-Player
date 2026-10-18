package org.vrpassthroughplayer.plugin

import java.io.IOException

/** Counts origin reads itself; loopback cache hits are not network traffic. */
internal interface UpstreamMeteredReader : StreamSource.Reader

/** Opt-in, source-lifetime read windows. A demuxer's alternating HTTP clients must
 * not throw away the other track's CDN connection and bytes on every close.
 * Two 8-MiB windows cover curl's 4-MiB producer buffer plus socket read-ahead.
 * No disk cache, full-file download, background reader or decoder-policy change. */
internal class InterleaveReadCache(private val source: StreamSource,
    private val windowBytes: Int = 8 * 1024 * 1024,
    private val onRead: (Int) -> Unit = {}, audioChunks: List<AudioReadSpan> = emptyList()) : StreamSource {
    override val size get() = source.size
    @Volatile private var closed = false
    private val lock = Any()
    private val windows = ArrayList<Window>(2)
    private val scratch = ByteArray(64 * 1024)
    private var clock = 0L
    private var upstreamBytes = 0L
    private var cachedBytes = 0L
    private var opens = 0L
    private val audioPackets = audioChunks.takeIf { it.isNotEmpty() }?.let { Mp4AudioPacketCache(it) }
    private var audioCachedBytes = 0L
    private class Window(val bytes: ByteArray, val reader: StreamSource.Reader, var start: Long) {
        var end = start
        var used = 0L
    }
    init { require(windowBytes >= scratch.size) }

    fun stats(): Map<String, Long> = synchronized(lock) {
        mapOf("upstream_bytes" to upstreamBytes, "cached_bytes" to cachedBytes,
            "reader_opens" to opens, "capacity_bytes" to windows.size.toLong() * windowBytes,
            "audio_payload_bytes" to (audioPackets?.sizeBytes() ?: 0L), "audio_cached_bytes" to audioCachedBytes)
    }
    fun cachedAudioEnd(offset: Long): Long? = synchronized(lock) { audioPackets?.end(offset) }

    override fun open(): StreamSource.Reader {
        check(!closed)
        return object : UpstreamMeteredReader {
            @Volatile private var done = false
            private var logicalNext = -1L
            override fun read(offset: Long, buffer: ByteArray, length: Int): Int = synchronized(lock) {
                if (closed || done || Thread.currentThread().isInterrupted) throw IOException("Request cancelled")
                require(offset in 0 until size && length in 1..buffer.size)
                // An ongoing video response must consume its existing upstream
                // through audio too; skipping those bytes would force a new
                // CDN connection at the next video byte.
                val continuing = audioPackets != null && logicalNext == offset && windows.any { offset >= it.start && offset <= it.end }
                val audio = if (!continuing) audioPackets?.read(offset, buffer, length) ?: 0 else 0
                if (audio > 0) {
                    cachedBytes += audio; audioCachedBytes += audio
                    logicalNext = offset + audio
                    return@synchronized audio
                }
                var window = windows.firstOrNull { offset >= it.start && offset < it.end }
                if (window != null) {
                    window.used = ++clock
                    val at = (offset % windowBytes).toInt()
                    val n = minOf(length.toLong(), window.end - offset, (windowBytes - at).toLong()).toInt()
                    window.bytes.copyInto(buffer, 0, at, at + n)
                    audioPackets?.capture(offset, buffer, n)
                    cachedBytes += n
                    logicalNext = offset + n
                    return@synchronized n
                }
                window = windows.firstOrNull { offset == it.end }
                if (window == null && audioPackets != null) {
                    // MOV can skip tiny AAC between video packets, or video
                    // between tiny AAC packets. Both readers retain their
                    // connections by consuming a bounded forward gap. Every
                    // byte remains real and is metered/cached as usual. ISO
                    // and sources without an audio index keep their old path.
                    window = windows.filter { it.end < offset && offset - it.end <= windowBytes }
                        .maxByOrNull { it.end }
                }
                if (window == null) {
                    val storage = if (windows.size == 2) {
                        val old = windows.minBy { it.used }
                        windows.remove(old)
                        old.reader.close()
                        old.bytes
                    } else ByteArray(windowBytes)
                    window = Window(storage, source.open(), offset)
                    opens++
                    windows.add(window)
                }
                window.used = ++clock
                try {
                    while (window.end < offset)
                        fill(window, minOf(offset - window.end, scratch.size.toLong()).toInt())
                    val wanted = minOf(length.toLong(), scratch.size.toLong(), size - offset).toInt()
                    val n = fill(window, wanted)
                    scratch.copyInto(buffer, 0, 0, n)
                    logicalNext = offset + n
                    n
                } catch (error: Exception) {
                    windows.remove(window)
                    runCatching { window.reader.close() }
                    throw error
                }
            }
            // This HTTP client may disappear after one audio packet. The shared
            // windows belong to the media lease, not to that transient client.
            override fun close() { done = true }
        }
    }

    private fun fill(window: Window, wanted: Int): Int {
        val offset = window.end
        val n = window.reader.read(offset, scratch, wanted)
        if (n !in 1..wanted) throw IOException("Invalid upstream read")
        val at = (offset % windowBytes).toInt()
        val first = minOf(n, windowBytes - at)
        scratch.copyInto(window.bytes, at, 0, first)
        if (first < n) scratch.copyInto(window.bytes, 0, first, n)
        window.end = offset + n
        window.start = maxOf(window.start, window.end - windowBytes)
        audioPackets?.capture(offset, scratch, n)
        upstreamBytes += n
        onRead(n)
        return n
    }

    override fun close() {
        closed = true
        // Cancel upstream IO before waiting for the cache lock held by a read.
        try { source.close() } finally {
            synchronized(lock) {
                windows.forEach { runCatching { it.reader.close() }; it.bytes.fill(0) }
                windows.clear()
                audioPackets?.close()
            }
        }
    }
}

/** Ordinary sources delegate unchanged until structural inspection opts in. */
internal class AdaptiveInterleaveSource(private val source: StreamSource,
    private val meter: TransferMeter? = null) : StreamSource {
    override val size get() = source.size
    @Volatile private var cache: InterleaveReadCache? = null
    @Volatile private var closed = false
    @Synchronized fun enable(audioChunks: List<AudioReadSpan> = emptyList()): Boolean {
        if (closed) return false
        if (cache == null) cache = InterleaveReadCache(source, onRead = { meter?.add(it) }, audioChunks = audioChunks)
        return true
    }
    fun stats(): Map<String, Long>? = cache?.stats()
    fun responseEnd(offset: Long, requestedEnd: Long): Long =
        cache?.cachedAudioEnd(offset)?.let { minOf(requestedEnd, it - 1) } ?: requestedEnd
    override fun open(): StreamSource.Reader {
        check(!closed)
        return cache?.open() ?: source.open()
    }
    override fun close() {
        val active = synchronized(this) { closed = true; cache }
        if (active == null) source.close() else active.close()
    }
}
