package org.vrpassthroughplayer.plugin

import java.io.InputStream
import java.io.IOException
import java.net.HttpURLConnection
import java.net.URI
import java.util.concurrent.ConcurrentHashMap
import java.util.concurrent.locks.ReentrantReadWriteLock
import kotlin.concurrent.read
import kotlin.concurrent.write

/** Reuses one upstream range stream per MPV connection, never buffers the whole video. */
internal class CloudStreamSource(
    override val size: Long,
    private val resolve: () -> CloudLink,
    private val connect: (URI) -> HttpURLConnection = ::openMediaConnection,
) : StreamSource {
    private var linkConnection: ((URI, CloudLink) -> HttpURLConnection)? = null
    constructor(size: Long, resolve: () -> CloudLink, linkConnection: (URI, CloudLink) -> HttpURLConnection) :
        this(size, resolve) { this.linkConnection = linkConnection }
    @Volatile private var link: CloudLink? = null
    private var resolvedAt = 0L
    @Volatile private var rangeWindow=Long.MAX_VALUE
    @Volatile private var closed = false
    private val readers = ConcurrentHashMap.newKeySet<RemoteReader>()
    private val readMode = ReentrantReadWriteLock(true)
    @Volatile private var sharedReadAhead: InterleaveReadCache? = null
    /** Called on the listening worker. Existing logical clients migrate without
     * waiting for a stalled body to release the mode gate. */
    override val sharedReadAheadActive get() = sharedReadAhead != null
    override fun shareReadAhead(onRead: (Int) -> Unit) = readMode.write {
        check(!closed)
        if (sharedReadAhead == null && archivePacer == null && rangeWindow == Long.MAX_VALUE) {
            // Mark retirement before disconnect: an interrupted read must not
            // auto-reconnect its old body while shared ownership is published.
            readers.forEach { it.retireOrigin() }
            val origin = object : StreamSource {
                override val size get() = this@CloudStreamSource.size
                override fun open(): StreamSource.Reader = synchronized(this@CloudStreamSource) {
                    check(!closed)
                    RemoteReader(backing = true).also { readers.add(it) }
                }
                override fun close() { readers.filter { it.backing }.forEach { it.close() } }
            }
            // Bounded RAM only, scoped to this media lease; no plaintext disk
            // cache. Header, tail index, playback and ASR can all be active;
            // four smaller windows keep the same 32-MiB transport budget.
            // 115 allows two long bodies per file: playback and ASR each keep
            // a sequential one instead of reconnecting the other at every turn.
            // A 4-MiB gap reads through the widest audio interleave seen (3.4 MB).
            sharedReadAhead = InterleaveReadCache(origin, 8 * 1024 * 1024, onRead,
                maxForwardGapBytes = 4 * 1024 * 1024, upstreams = 2, readAheadBytes = 2 * 1024 * 1024,
                windowCount = 4,readAheadBudgetMs = 500)
        }
    }
    fun readAheadStats(): Map<String, Long>? = sharedReadAhead?.stats()
    override fun readSnapshot(): Map<String,Long> = sharedReadAhead?.readSnapshot() ?: emptyMap()
    override fun retainAudio(spans: List<AudioReadSpan>) { sharedReadAhead?.retainAudio(spans) }
    private var archivePacer: ArchiveRangePacer? = null
    private var completeRanges = false
    fun forArchiveReading(): CloudStreamSource { archivePacer = ArchiveRangePacer(); return this }
    fun forPdfReading(): CloudStreamSource { forArchiveReading(); completeRanges = true; return this }

    fun prepare() { currentLink() }
    /** Open-ended media ranges only: archive pacing retires readers per range, bounded reads release slots. */
    val continuable: Boolean @Synchronized get() = archivePacer == null && rangeWindow == Long.MAX_VALUE
    /** Independent reader ownership, retaining this immutable object's resolver and
     * identity-bound connection factory. The caller registers the new media lease. */
    @Synchronized override fun fork(): CloudStreamSource {
        check(!closed)
        return CloudStreamSource(size, resolve, connect).also {
            it.linkConnection = linkConnection; it.rangeWindow = rangeWindow
            it.archivePacer = archivePacer
            it.completeRanges = completeRanges
            it.link = link; it.resolvedAt = resolvedAt
        }
    }
    /** Configure before publication. Short reference reads must release CDN slots promptly. */
    @Synchronized fun boundedRanges(bytes: Long): CloudStreamSource {
        require(bytes>0);check(!closed&&link==null&&readers.isEmpty())
        rangeWindow=bytes;return this
    }
    @Synchronized private fun currentLink(failed: CloudLink? = null): CloudLink {
        if (closed) throw CloudFailure()
        // OpenList's loopback capability owns provider ticket expiry. Reusing it
        // avoids another stat/download lookup after an idle period or CDN expiry.
        val proxyRefresh = archivePacer != null && linkConnection != null && failed === link
        if (link == null || failed === link && !proxyRefresh || archivePacer == null && System.nanoTime() - resolvedAt > 300_000_000_000L) {
            val resolved = resolve()
            if (closed) throw CloudFailure()
            link = resolved; resolvedAt = System.nanoTime()
        }
        return link!!
    }
    override fun open(): StreamSource.Reader = openReader(false)
    override fun openAudio(): StreamSource.Reader = openReader(true)
    private fun openReader(preferAudio: Boolean): StreamSource.Reader = synchronized(this) {
        if (closed) throw CloudFailure()
        // A cancelled loopback client may disappear while the old handler is
        // waiting for pacing/headers. Retire it before the next archive range.
        if (archivePacer != null) readers.forEach { it.close() }
        RemoteReader(completeRange = completeRanges,preferAudio=preferAudio).also { readers.add(it) }
    }
    /** Explicit, bounded small-RAR transfer; ordinary archive ranges retain their cap. */
    fun openSmallRarDownload(): StreamSource.Reader = synchronized(this) {
        check(!closed && archivePacer != null && size in 8L..SmallRarCache.MAX_BYTES)
        readers.forEach { it.close() }
        RemoteReader(size, completeRange = true).also { readers.add(it) }
    }
    override fun close() {
        closed = true
        // KeySetView.forEach tolerates concurrent removals. Kotlin toList's
        // size==1 shortcut can call next() after the last reader disappears.
        readers.forEach { it.close() }
        sharedReadAhead?.close()
        link = null
    }

    private inner class RemoteReader(private val windowBytes: Long = rangeWindow,
        private val completeRange: Boolean = false, val backing: Boolean = false,
        private val preferAudio: Boolean = false) : BoundedStreamReader, OriginProgress {
        @Volatile override var awaitingResponse = false
        @Volatile private var done = false
        @Volatile private var originRetired = false
        @Volatile private var connection: HttpURLConnection? = null
        private var input: InputStream? = null
        private var shared: StreamSource.Reader? = null
        private var next = -1L
        private var end = -1L
        private var rangeEnd = size - 1
        override fun counters(): Map<String,Long> = shared?.counters() ?: emptyMap()
        override fun setRangeEnd(endInclusive: Long) {
            if (archivePacer != null) rangeEnd = minOf(endInclusive, size - 1)
        }

        override fun read(offset: Long, buffer: ByteArray, length: Int): Int {
            while (true) {
                // Only choose ownership under the gate. Network IO never keeps
                // shareReadAhead's writer waiting for the 20-second read timeout.
                val cache = readMode.read {
                    if (closed || done || Thread.currentThread().isInterrupted) throw cancelled()
                    if (backing) null else sharedReadAhead
                }
                if (cache != null) {
                    val delegate = shared ?: (if(preferAudio)cache.openAudio() else cache.open()).also { shared = it }
                    return delegate.read(offset, buffer, length)
                }
                try { return readOrigin(offset, buffer, length) }
                catch (_: OriginSwitched) { /* Retry this byte through the published shared cache. */ }
            }
        }
        private fun readOrigin(offset: Long, buffer: ByteArray, length: Int): Int {
            try {
                if (closed || done || originRetired || Thread.currentThread().isInterrupted) throw cancelled()
                require(offset in 0 until size && length in 1..buffer.size)
                if (offset != next || offset > end || input == null) openRange(offset)
                var count = 0
                for (attempt in 0..1) {
                    try {
                        count = input!!.read(buffer, 0, minOf(length.toLong(), end - offset + 1).toInt())
                        if (count <= 0) throw PlaybackFailureException(PlaybackFailure("stream_interrupted", "reading", "Upstream stream ended before the requested range"))
                        break
                    } catch (error: IOException) {
                        if (archivePacer != null || attempt != 0 || closed || done || originRetired || Thread.currentThread().isInterrupted) throw error
                        // A server may close an idle body while playback is
                        // paused. Resume at the first byte not returned to the
                        // caller; never restart or duplicate already read audio.
                        disconnect()
                        openRange(offset)
                    }
                }
                next = offset + count
                return count
            } catch (error: Exception) {
                if (originRetired && !closed && !done && !Thread.currentThread().isInterrupted) {
                    disconnect(); throw OriginSwitched()
                }
                val wasCancelled = closed || done || Thread.currentThread().isInterrupted
                close()
                if (wasCancelled) throw cancelled()
                throw if (error is PlaybackFailureException) error else PlaybackFailureException(PlaybackFailure.from(error, "reading"), error)
            }
        }

        private fun openRange(offset: Long) {
            awaitingResponse = true
            try { requestRange(offset) } finally { awaitingResponse = false }
        }
        private fun requestRange(offset: Long) {
            disconnect()
            var selected = currentLink()
            var refreshed=false;var gatewayRetried=false;var busyRetries=0
            val requestedEnd=minOf(rangeEnd, offset+minOf(windowBytes,size-offset)-1)
            while(true) {
                var retry=false
                var target = URI(selected.url)
                for (redirect in 0..5) {
                    if (closed || done || originRetired || Thread.currentThread().isInterrupted) throw cancelled()
                    archivePacer?.await { closed || done }
                    val request = linkConnection?.invoke(target, selected) ?: connect(target)
                    synchronized(this) {
                        if (closed || done || originRetired) { request.disconnect(); throw cancelled() }
                        connection = request
                    }
                    request.connectTimeout = 15000; request.readTimeout = 20000
                    request.instanceFollowRedirects = false; request.useCaches = false
                    request.setRequestProperty("Accept-Encoding", "identity")
                    selected.headers(target).forEach { (name, value) -> request.setRequestProperty(name, value) }
                    request.setRequestProperty("Range", if(windowBytes==Long.MAX_VALUE && archivePacer==null)"bytes=$offset-" else "bytes=$offset-$requestedEnd")
                    if (archivePacer != null && linkConnection != null && target.host == "127.0.0.1")
                        request.setRequestProperty("X-Thru3D-Archive-Read", "1")
                    val status = request.responseCode
                    if (status in setOf(301, 302, 303, 307, 308)) {
                        val location = request.getHeaderField("Location") ?: throw PlaybackFailureException(PlaybackFailure("invalid_response", "reading", "Redirect has no Location header", httpStatus = status))
                        target = target.resolve(location)
                        disconnect()
                        continue
                    }
                    val reason=request.getHeaderField("X-Thru3D-Upstream-Reason").orEmpty().takeIf { it in upstreamReasons }.orEmpty()
                    if(archivePacer == null && status in setOf(403,429,503)&&reason=="cdn_connections_limited"&&busyRetries<6) {
                        disconnect();Thread.sleep(250L*++busyRetries);retry=true
                        break
                    }
                    if (status in setOf(401, 403, 410) && reason !in setOf("cdn_connections_limited", "cdn_rate_limited") && !refreshed) {
                        disconnect(); selected = currentLink(selected);refreshed=true;retry=true
                        break
                    }
                    if (archivePacer == null && status in setOf(502, 503, 504) && reason!="cdn_connections_limited" && !gatewayRetried) {
                        // A transient proxy failure must not become a corrupt MP4
                        // packet in FFmpeg. Retry this exact range once; keep the
                        // verified link instead of repeating provider metadata work.
                        disconnect()
                        Thread.sleep(200);gatewayRetried=true;retry=true
                        break
                    }
                    if (status !in setOf(200, 206)) {
                        throw PlaybackFailureException(PlaybackFailure.http(status).copy(sourceCode=reason))
                    }
                    val type = request.contentType.orEmpty().lowercase()
                    if (type.contains("text/html") || type.contains("application/json")) throw PlaybackFailureException(PlaybackFailure("not_media", "reading", "Upstream returned HTML or JSON instead of media", httpStatus = status))
                    if (status == 206) {
                        val match = Regex("bytes (\\d+)-(\\d+)/(\\d+)").matchEntire(request.getHeaderField("Content-Range") ?: "") ?: throw invalidRange(status)
                        val start = match.groupValues[1].toLongOrNull() ?: throw invalidRange(status)
                        end = match.groupValues[2].toLongOrNull() ?: throw invalidRange(status)
                        if (start != offset || end < offset || end > requestedEnd || match.groupValues[3].toLongOrNull() != size) throw invalidRange(status)
                        // Do not silently turn the one-body cache transfer into hundreds of ranges.
                        if (completeRange && end != requestedEnd) throw invalidRange(status)
                        val length = request.getHeaderField("Content-Length")?.toLongOrNull()
                        if (length != null && length != end - offset + 1) throw invalidRange(status)
                    } else if (archivePacer == null && status == 200 && offset == 0L && requestedEnd==size-1 && request.getHeaderField("Content-Length")?.toLongOrNull() == size) {
                        end = size - 1
                    } else throw PlaybackFailureException(PlaybackFailure("range_unsupported", "reading", "Upstream ignored the requested byte range", httpStatus = status))
                    synchronized(this) {
                        if (closed || done || originRetired) { request.disconnect(); throw cancelled() }
                        input = request.inputStream
                        next = offset
                    }
                    return
                }
                if(!retry)throw PlaybackFailureException(PlaybackFailure("redirect_failed", "reading", "Upstream redirect limit exceeded"))
            }
        }
        fun disconnect() {
            // Disconnect first to unblock a pending read during logout or player shutdown.
            connection?.disconnect(); connection = null
            runCatching { input?.close() }; input = null
        }
        fun retireOrigin() = synchronized(this) { originRetired = true; disconnect() }
        override fun close() {
            synchronized(this) { done = true; disconnect() }
            shared?.close()
            readers.remove(this)
        }
    }
    companion object {
        private class OriginSwitched : IOException("Origin ownership changed")
        val upstreamReasons=setOf("upstream_error","cdn_cookie_missing","cdn_cookie_invalid","cdn_ua_missing","cdn_expired","cdn_signature_invalid","cdn_signature_missing","cdn_ip_mismatch","cdn_rate_limited","cdn_connections_limited")
        private fun cancelled() = PlaybackFailureException(PlaybackFailure("cancelled", "reading", "Request cancelled"))
        private fun invalidRange(status: Int) = PlaybackFailureException(PlaybackFailure("invalid_range", "reading", "Upstream returned an invalid byte range", httpStatus = status))
        private fun openMediaConnection(uri: URI): HttpURLConnection {
            if (!CloudDrive.allowedMediaUri(uri)) throw CloudFailure()
            return CancellableMediaConnection.open(uri)
        }
    }
}
