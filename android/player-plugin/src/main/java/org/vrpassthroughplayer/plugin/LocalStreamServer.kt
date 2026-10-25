package org.vrpassthroughplayer.plugin

import java.io.BufferedInputStream
import java.io.Closeable
import java.io.OutputStream
import java.net.InetAddress
import java.net.ServerSocket
import java.net.Socket
import java.net.URLEncoder
import java.security.SecureRandom
import java.util.concurrent.ConcurrentHashMap
import java.util.concurrent.Executors

/** Random-access byte source (SMB or cloud). Each HTTP connection opens its own reader. */
internal interface StreamSource : Closeable {
    val size: Long
    fun open(): Reader
    /** An independent source for the same bytes (a playback view outlives its parent), or null. */
    fun fork(): StreamSource? = null
    /** Reopenable byte sources that can carry the read cache and a playback view. */
    val forkable: Boolean get() = false
    override fun close() {}
    interface Reader : Closeable { fun read(offset: Long, buffer: ByteArray, length: Int): Int }
}

/** Optional capability: ordinary video, ISO and subtitle readers keep their existing ABI. */
internal interface BoundedStreamReader : StreamSource.Reader { fun setRangeEnd(endInclusive: Long) }

/** Loopback-only HTTP/1.1 server that lets MPV/FFmpeg read network files with seeks
 * (Range requests). Paths are unguessable tokens; nothing listens beyond 127.0.0.1. */
internal class LocalStreamServer : Closeable {
    private val socket = ServerSocket(0, 16, InetAddress.getByName("127.0.0.1"))
    private val sources = ConcurrentHashMap<String, StreamSource>()
    private val meters = ConcurrentHashMap<String, TransferMeter>()
    private class Diagnostics {
        private var sequence = 0L
        private var success = 0L
        private var failed = 0L
        private var cause: PlaybackFailure? = null
        @Synchronized fun begin() = ++sequence
        @Synchronized fun success(attempt: Long) {
            success = maxOf(success, attempt)
            if (attempt >= failed) cause = null
        }
        @Synchronized fun fail(attempt: Long, value: PlaybackFailure) {
            if (attempt > success && attempt >= failed) { failed = attempt; cause = value }
        }
        @Synchronized fun failure(): PlaybackFailure? = cause
    }
    private val diagnostics = ConcurrentHashMap<String, Diagnostics>()
    private val clients = ConcurrentHashMap.newKeySet<Socket>()
    private val pool = Executors.newCachedThreadPool { Thread(it, "QuestStreamServer").apply { isDaemon = true } }
    private val random = SecureRandom()
    @Volatile private var closed = false

    init {
        pool.execute {
            while (!closed) {
                val client = try { socket.accept() } catch (_: Throwable) { break }
                clients.add(client)
                pool.execute { serve(client) }
            }
        }
    }

    /** Returns http://127.0.0.1:port/<token>/<name> for MPV; the name only helps container probing. */
    /** isoMemory: a stable disc identity whose metadata blocks may outlive this lease (IsoMetadataMemory). */
    fun publish(source: StreamSource, name: String, isoMemory: String? = null): String {
        val token = ByteArray(16).also(random::nextBytes).joinToString("") { "%02x".format(it) }
        meters[token] = TransferMeter()
        diagnostics[token] = Diagnostics()
        sources[token] = if (source is CloudStreamSource || source is HttpRangeStreamSource || source.forkable) {
            if (name.endsWith(".iso", true)) IsoReadCache(source, isoMemory) { meters[token]?.add(it) }
            else AdaptiveInterleaveSource(source, meters[token])
        } else source
        return "http://127.0.0.1:${socket.localPort}/$token/${URLEncoder.encode(name, "UTF-8").replace("+", "%20")}"
    }

    private fun token(url: String) = url.takeIf { it.startsWith("http://127.0.0.1:${socket.localPort}/") }
        ?.substringAfter(":${socket.localPort}/")?.substringBefore('/')
    fun hasSource(url: String): Boolean = token(url)?.let { sources.containsKey(it) } == true
    fun cachedArchive(url: String): Boolean = token(url)?.let { sources[it] is CachedRarSource } == true
    fun progress(url: String): TransferMeter.Snapshot? = token(url)?.let { meters[it]?.snapshot() }
    fun failure(url: String): PlaybackFailure? = token(url)?.let { diagnostics[it]?.failure() }
    fun enableInterleaveCache(url: String): Boolean = enableInterleaveCache(url, emptyList())
    fun enableInterleaveCache(url: String, audioChunks: List<AudioReadSpan>): Boolean = token(url)?.let {
        (sources[it] as? AdaptiveInterleaveSource)?.enable(audioChunks)
    } ?: false
    fun interleaveCacheStats(url: String): Map<String, Long>? = token(url)?.let {
        when (val source = sources[it]) {
            is AdaptiveInterleaveSource -> source.stats()
            is Mp4PlaybackSource -> source.stats()
            else -> null
        }
    }
    /** Independent ownership: releasing the old decoder cannot close this input. */
    fun playbackView(url: String, layout: Mp4PlaybackLayout): String? {
        if (closed) return null
        val parent = token(url)?.let { sources[it] } ?: return null
        val fork = when (parent) {
            is AdaptiveInterleaveSource -> parent.forkOrigin()
            is Mp4PlaybackSource -> parent.forkOrigin()
            else -> null
        } ?: return null
        return try {
            require(fork.size == layout.originalSize)
            val meter = TransferMeter()
            val source = Mp4PlaybackSource(fork, layout) { meter.add(it) }
            (publish(source, "playback.mp4") + "?thru3d_interleaved=1").also { meters[token(it)!!] = meter }
        } catch (error: Exception) { fork.close(); throw error }
    }
    /** Cloud inputs keep their account/logout boundary (CloudLibrary.playbackView). */
    fun cloudBacked(url: String): Boolean = when (val source = token(url)?.let { sources[it] }) {
        is AdaptiveInterleaveSource -> source.cloud
        is Mp4PlaybackSource -> source.cloud
        else -> false
    }
    fun finishIsoPreflight(url: String) { token(url)?.let { (sources[it] as? IsoReadCache)?.finishPreflight() } }
    fun isoCacheStats(url: String): Map<String, Long>? = token(url)?.let { (sources[it] as? IsoReadCache)?.stats() }
    fun revoke(url: String) { token(url)?.let { meters.remove(it); sources.remove(it)?.close(); diagnostics.remove(it) } }

    private fun record(token: String, source: StreamSource, attempt: Long, error: Exception) {
        if (!closed && sources[token] === source && !Thread.currentThread().isInterrupted && !PlaybackFailure.cancelled(error)) {
            val failure=PlaybackFailure.from(error, "reading")
            diagnostics[token]?.fail(attempt, failure)
            // Another range can recover before the caller samples failure().
            // Keep fixed error fields for diagnosing concurrent readers, with
            // no capability, URL, headers, filename or upstream response body.
            if(BuildConfig.DEBUG && PlaybackPrivacy.diagnostics) runCatching {
                val code=failure.sourceCode.takeIf {it in CloudStreamSource.upstreamReasons}.orEmpty()
                android.util.Log.w("Thru3DNetworkRead","reason=${failure.reason} http_status=${failure.httpStatus} source_code=$code exception=${failure.exceptionType}")
            }
        }
    }

    private fun read(token: String, source: StreamSource, reader: StreamSource.Reader, offset: Long, buffer: ByteArray, length: Int): Int {
        val state = diagnostics[token]
        val attempt = state?.begin() ?: 0
        try {
            val count = reader.read(offset, buffer, length)
            if (count <= 0) throw PlaybackFailureException(PlaybackFailure("stream_interrupted", "reading", "Upstream stream ended before the requested range"))
            state?.success(attempt) // A late failure from an older seek cannot undo this recovery.
            return count
        } catch (error: Exception) { record(token, source, attempt, error); throw error }
    }

    private fun serve(client: Socket) = client.use {
        try {
            client.soTimeout = 30_000
            val input = BufferedInputStream(client.getInputStream())
            val request = readLine(input) ?: return
            val headers = HashMap<String, String>()
            while (true) {
                val line = readLine(input) ?: return
                if (line.isEmpty()) break
                val colon = line.indexOf(':')
                if (colon > 0) headers[line.substring(0, colon).trim().lowercase()] = line.substring(colon + 1).trim()
            }
            val parts = request.split(' ')
            val output = client.getOutputStream()
            if (parts.size < 3 || parts[0] !in setOf("GET", "HEAD")) return respond(output, 405, "Method Not Allowed")
            val token = parts[1].trimStart('/').substringBefore('/')
            val source = sources[token] ?: return respond(output, 404, "Not Found")
            val meter = meters[token]
            val range = parseRange(headers["range"], source.size) ?: return respond(output, 416, "Range Not Satisfiable",
                "Content-Range: bytes */${source.size}\r\n")
            val start = range.first
            val partial = headers.containsKey("range")
            val bounded = headers["range"]?.substringAfter('=')?.trim()?.let { !it.startsWith('-') && !it.endsWith('-') } == true
            // A cached audio packet must not start another CDN read merely
            // because the transient curl client requested 32 MiB after it.
            // MPV's bounded curl requests resume at the advertised Range end.
            // Unbounded FFmpeg HTTP reads can interpret an early response end
            // as EOF. Only bounded clients (MPV curl) can resume this segment.
            val end = if (bounded) (source as? AdaptiveInterleaveSource)?.responseEnd(start, range.second) ?: range.second else range.second
            val head = StringBuilder()
                .append("HTTP/1.1 ").append(if (partial) "206 Partial Content" else "200 OK").append("\r\n")
                .append("Content-Type: application/octet-stream\r\nAccept-Ranges: bytes\r\n")
                .append("Content-Length: ").append(end - start + 1).append("\r\n")
            if (partial) head.append("Content-Range: bytes ").append(start).append('-').append(end).append('/').append(source.size).append("\r\n")
            val responseHead = head.append("Connection: close\r\n\r\n").toString().toByteArray()
            if (parts[0] == "HEAD") { output.write(responseHead); return }
            val opening = diagnostics[token]?.begin() ?: 0
            val opened = try { source.open() } catch (error: Exception) { record(token, source, opening, error); return respond(output, 502, "Bad Gateway") }
            opened.use { reader ->
                if (reader is BoundedStreamReader) reader.setRangeEnd(end)
                val buffer = ByteArray(if (reader is UpstreamMeteredReader) 64 * 1024 else 512 * 1024)
                var offset = start
                // Validate the upstream status/range before committing a successful HTTP response.
                val first = try { read(token, source, reader, offset, buffer, minOf(buffer.size.toLong(), end - offset + 1).toInt()) }
                    catch (_: Exception) { return respond(output, 502, "Bad Gateway") }
                if (first <= 0) return respond(output, 502, "Bad Gateway")
                if (reader !is UpstreamMeteredReader) meter?.add(first)
                output.write(responseHead)
                output.write(buffer, 0, first); offset += first
                while (offset <= end && !closed) {
                    val count = read(token, source, reader, offset, buffer, minOf(buffer.size.toLong(), end - offset + 1).toInt())
                    if (count <= 0) break
                    if (reader !is UpstreamMeteredReader) meter?.add(count)
                    output.write(buffer, 0, count)
                    offset += count
                }
                output.flush()
            }
        } catch (_: Throwable) {
            // Client seeks close connections mid-body; that is normal for MPV.
        } finally { clients.remove(client) }
    }

    private fun respond(output: OutputStream, code: Int, text: String, extra: String = "") {
        output.write("HTTP/1.1 $code $text\r\n${extra}Content-Length: 0\r\nConnection: close\r\n\r\n".toByteArray())
    }

    private fun readLine(input: BufferedInputStream): String? {
        val line = StringBuilder()
        while (true) {
            val c = input.read()
            if (c < 0) return if (line.isEmpty()) null else line.toString()
            if (c == '\n'.code) return line.toString().trimEnd('\r')
            if (line.length > 8192) return null
            line.append(c.toChar())
        }
    }

    override fun close() {
        closed = true
        try { socket.close() } catch (_: Throwable) {}
        pool.shutdownNow()
        clients.toList().forEach { runCatching { it.close() } }; clients.clear()
        sources.values.forEach { runCatching { it.close() } }
        diagnostics.clear()
        sources.clear()
        meters.clear()
    }

    companion object {
        /** Inclusive [start, end] for a single "bytes=" range, whole file when absent; null if unsatisfiable. */
        fun parseRange(header: String?, size: Long): Pair<Long, Long>? {
            if (size <= 0) return null
            if (header == null) return 0L to size - 1
            if (',' in header) return null
            val spec = header.trim().removePrefix("bytes=").trim()
            val dash = spec.indexOf('-')
            if (!header.trim().startsWith("bytes=") || dash < 0) return null
            val first = spec.substring(0, dash).trim(); val last = spec.substring(dash + 1).trim()
            return try {
                if (first.isEmpty()) {
                    val suffix = last.toLong()
                    if (suffix <= 0) null else maxOf(0L, size - suffix) to size - 1
                } else {
                    val start = first.toLong()
                    val end = if (last.isEmpty()) size - 1 else minOf(last.toLong(), size - 1)
                    if (start < 0 || start >= size || start > end) null else start to end
                }
            } catch (_: NumberFormatException) { null }
        }
    }
}
