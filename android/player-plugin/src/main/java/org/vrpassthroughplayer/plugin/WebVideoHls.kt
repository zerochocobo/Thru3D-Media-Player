package org.vrpassthroughplayer.plugin

import java.io.Closeable
import java.net.URI
import java.util.LinkedHashMap

/** VOD manifests and their resources remain behind the existing random-token loopback server. */
internal class WebVideoHls(private val server: LocalStreamServer) : Closeable {
    private val http = RemoteMediaHttp()
    private val published = ArrayList<String>()
    private val manifests = HashMap<URI, String>()
    private val visiting = HashSet<URI>()
    private val cache = LinkedHashMap<URI, ByteArray>(16, .75f, true)
    private var cachedBytes = 0L
    private val transfers = java.util.concurrent.Semaphore(2)
    @Volatile private var closed = false
    private var browserHeaders: WebVideoRequestHeaders? = null

    fun prepare(track: WebVideoTrack): String {
        browserHeaders = track.browserHeaders
        return manifest(track.url, track.headers, 0)
    }

    private fun bytes(uri: URI, headers: Map<String, String>, limit: Int): Pair<URI, ByteArray> {
        check(transfers.tryAcquire(30, java.util.concurrent.TimeUnit.SECONDS)) { "Media transfer busy" }
        try { return fetch(uri, headers, limit) } finally { transfers.release() }
    }

    private fun fetch(uri: URI, headers: Map<String, String>, limit: Int): Pair<URI, ByteArray> {
        // Some headset network paths cut connections in short bursts (Quest 3, 2026-10-29: a
        // resolved Niconico playlist failed on one timeout). Request a complete resource again a
        // little later; a site's own answer (an HTTP status) is final.
        val started = System.nanoTime()
        var attempt = 0
        while (true) {
            try { return fetchOnce(uri, headers, limit) } catch (error: Exception) {
                val transport = error is java.io.IOException || (error is MediaServerFailure && error.transportError.isNotEmpty())
                if (!transport || ++attempt > 2 || closed || System.nanoTime() - started > 20_000_000_000L) throw error
                Thread.sleep(1500L * attempt)
            }
        }
    }

    private fun fetchOnce(uri: URI, headers: Map<String, String>, limit: Int): Pair<URI, ByteArray> {
        check(!closed)
        // Complete bounded resources: dynamic playlist endpoints may implement Range incorrectly.
        val c = http.open(uri, "", headers)
        try {
            require(c.contentLengthLong <= limit) { "Media resource exceeds limit" }
            val body = c.inputStream.use { input ->
                val out = java.io.ByteArrayOutputStream()
                val buffer = ByteArray(32768)
                while (true) {
                    check(!closed && !Thread.currentThread().isInterrupted)
                    val n = input.read(buffer)
                    if (n < 0) break
                    require(out.size() + n <= limit) { "Media resource exceeds limit" }
                    out.write(buffer, 0, n)
                }
                out.toByteArray()
            }
            // A bounded response containing only a prefix is not a complete segment/manifest.
            if (c.responseCode == 206) {
                val range = Regex("bytes 0-([0-9]+)/([0-9]+)").matchEntire(c.getHeaderField("Content-Range").orEmpty())
                require(range != null && range.groupValues[1].toLongOrNull() == body.size.toLong() - 1 &&
                    range.groupValues[2].toLongOrNull() == body.size.toLong()) { "Incomplete media resource" }
            }
            return c.url.toURI() to body
        } finally { http.release(c) }
    }

    private fun headersFor(origin: URI, target: URI, headers: Map<String, String>): Map<String, String> {
        browserHeaders?.let { return it.forUrl(target, headers) }
        fun port(uri: URI) = if (uri.port >= 0) uri.port else if (uri.scheme == "https") 443 else 80
        val same = origin.scheme == target.scheme && origin.host.equals(target.host, true) && port(origin) == port(target)
        return if (same) headers else headers.filterKeys { it.lowercase() in setOf("user-agent", "accept", "accept-language", "referer", "origin") }
    }

    private fun resolve(base: URI, value: String): URI = base.resolve(value).also {
        require(it.scheme in setOf("http", "https") && !it.host.isNullOrEmpty() && it.rawUserInfo == null && it.fragment == null)
        require(it.toString().length <= 16384)
    }

    @Synchronized private fun publish(source: StreamSource, name: String): String {
        check(!closed && published.size < 30000) { "Manifest resource limit" }
        return server.publish(source, name).also(published::add)
    }

    private fun resource(uri: URI, headers: Map<String, String>, key: Boolean = false): String {
        val limit = if (key) 16 else 16 * 1024 * 1024
        val source = object : StreamSource {
            private var length = -1L
            @Synchronized fun load(): ByteArray {
                check(!closed)
                val data = synchronized(cache) { cache[uri] } ?: bytes(uri, headers, limit).second.also { data ->
                    require(data.isNotEmpty() && (!key || data.size == 16)) { "Invalid media resource" }
                    synchronized(cache) {
                        check(!closed)
                        cache.remove(uri)?.let { cachedBytes -= it.size }
                        if (data.size <= 32 * 1024 * 1024) { cache[uri] = data; cachedBytes += data.size }
                        while (cachedBytes > 32 * 1024 * 1024) {
                            val first = cache.entries.iterator(); cachedBytes -= first.next().value.size; first.remove()
                        }
                    }
                }
                require(length == -1L || length == data.size.toLong()) { "Media representation changed" }
                length = data.size.toLong()
                return data
            }
            override val size: Long get() = load().size.toLong()
            override fun open(): StreamSource.Reader {
                val data = load()
                return object : StreamSource.Reader {
                    override fun read(offset: Long, buffer: ByteArray, length: Int): Int {
                        check(!closed)
                        if (offset >= data.size) return -1
                        require(offset >= 0)
                        val n = minOf(length, data.size - offset.toInt())
                        data.copyInto(buffer, 0, offset.toInt(), offset.toInt() + n)
                        return n
                    }
                    override fun close() {}
                }
            }
        }
        val ext = uri.path.substringAfterLast('.', "").takeIf { it in setOf("ts", "mp4", "m4s", "aac", "mp3", "key") } ?: if (key) "key" else "ts"
        return publish(source, "resource.$ext")
    }

    private fun manifest(uri: URI, headers: Map<String, String>, depth: Int): String {
        manifests[uri]?.let { return it }
        require(depth <= 4 && manifests.size < 64 && visiting.add(uri)) { "Invalid manifest graph" }
        try {
            val (base, body) = bytes(uri, headers, 2 * 1024 * 1024)
            val lines = body.toString(Charsets.UTF_8).removePrefix("\uFEFF").lineSequence().map(String::trim).toList()
            require(lines.firstOrNull() == "#EXTM3U") { "Invalid HLS manifest" }
            val master = lines.any { it.startsWith("#EXT-X-STREAM-INF:") }
            require(master || lines.contains("#EXT-X-ENDLIST")) { "Live video stays in the browser" }
            require(lines.none { it.startsWith("#EXT-X-DEFINE:") }) { "Variable manifests are not supported" }
            val safeHeaders = headersFor(uri, base, headers)
            var nextManifest = false
            val rewritten = lines.map { line ->
                when {
                    line.startsWith("#EXT-X-STREAM-INF:") -> { nextManifest = true; line }
                    line.startsWith("#EXT-X-KEY:") || line.startsWith("#EXT-X-SESSION-KEY:") -> {
                        require(Regex("(?:[:,])METHOD=(?:NONE|AES-128)(?:,|$)").containsMatchIn(line) &&
                            (!line.contains("KEYFORMAT=") || line.contains("KEYFORMAT=\"identity\""))) { "Protected media stays in the browser" }
                        rewriteUris(line, base) { target -> resource(target, headersFor(base, target, safeHeaders), true) }
                    }
                    line.startsWith("#EXT-X-MEDIA:") || line.startsWith("#EXT-X-I-FRAME-STREAM-INF:") ->
                        rewriteUris(line, base) { target -> manifest(target, headersFor(base, target, safeHeaders), depth + 1) }
                    line.startsWith("#EXT-X-MAP:") ->
                        rewriteUris(line, base) { target -> resource(target, headersFor(base, target, safeHeaders)) }
                    line.startsWith('#') -> {
                        // Never leave unhandled network locations for FFmpeg to fetch directly.
                        require(!line.contains("URI=")) { "Unsupported manifest reference" }; line
                    }
                    line.isEmpty() -> line
                    else -> {
                        val target = resolve(base, line)
                        if (nextManifest) { nextManifest = false; manifest(target, headersFor(base, target, safeHeaders), depth + 1) }
                        else resource(target, headersFor(base, target, safeHeaders))
                    }
                }
            }.joinToString("\n", postfix = "\n").toByteArray()
            require(!nextManifest) { "Incomplete manifest" }
            return publish(ByteSource(rewritten), "playlist.m3u8").also { manifests[uri] = it }
        } finally { visiting.remove(uri) }
    }

    private fun rewriteUris(line: String, base: URI, rewrite: (URI) -> String): String {
        val pattern = Regex("URI=\"([^\"]+)\"")
        require(!line.contains("URI=") || pattern.containsMatchIn(line)) { "Invalid manifest URI" }
        return pattern.replace(line) { "URI=\"${rewrite(resolve(base, it.groupValues[1]))}\"" }
    }

    private class ByteSource(private val data: ByteArray) : StreamSource {
        override val size = data.size.toLong()
        override fun open() = object : StreamSource.Reader {
            override fun read(offset: Long, buffer: ByteArray, length: Int): Int {
                if (offset >= data.size) return -1
                require(offset >= 0)
                val n = minOf(length, data.size - offset.toInt()); data.copyInto(buffer, 0, offset.toInt(), offset.toInt() + n); return n
            }
            override fun close() {}
        }
    }
    override fun close() {
        val leases = synchronized(this) { closed = true; published.toList().also { published.clear() } }
        http.close()
        leases.forEach(server::revoke)
        synchronized(cache) { cache.clear(); cachedBytes = 0 }
    }
}
