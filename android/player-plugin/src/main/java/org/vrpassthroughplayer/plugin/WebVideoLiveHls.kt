package org.vrpassthroughplayer.plugin

import java.io.Closeable
import java.net.URI

/** Rolling, independently revocable HLS lease for one already identified rendition. */
internal class WebVideoLiveHls(
    private val server: LocalStreamServer,
    private val upstream: URI,
    private val playlistHeaders: Map<String, String>,
    private val resourceHeaders: (URI) -> Map<String, String>,
    private val nowMillis: () -> Long = { System.nanoTime() / 1_000_000L },
    private val validateInitialization: (ByteArray) -> Unit,
) : Closeable {
    private val http = RemoteMediaHttp()
    private val resources = LinkedHashMap<URI, Resource>()
    private val playlistLock = Any()
    private val transfers = java.util.concurrent.Semaphore(4)
    @Volatile private var closed = false
    private var localUrl: String? = null
    private var current: WebVideoLivePlaylist? = null
    private var currentBytes: ByteArray? = null
    private var mediaPlaylist: URI? = null
    private var initializationBytes: ByteArray? = null
    private var nextRefresh = 0L
    private var refreshCount = 0
    private var firstSequence: Long? = null
    private var lastRefreshError: String? = null
    private var startupSequence: Long? = null
    private var startupFragment: Pair<URI, ByteArray>? = null
    private var firstFetch = true

    private class Resource(val local: String, var lastUsed: Long)

    fun prepare(): String {
        snapshot()
        synchronized(this) {
            check(!closed)
            check(localUrl == null)
            return server.publish(object : StreamSnapshotSource {
                override fun snapshot() = servePlaylist()
                override val size get() = error("Playlist needs a request snapshot")
                override fun open(): StreamSource.Reader = error("Playlist needs a request snapshot")
            }, "live.m3u8").also { localUrl = it }
        }
    }

    fun progress(): Pair<Int, Long> = synchronized(playlistLock) {
        refreshCount to ((current?.sequence ?: 0) - (firstSequence ?: 0))
    }

    fun startsAtSync(): Boolean = synchronized(playlistLock) { startupSequence != null }

    fun refreshError(): String? = synchronized(playlistLock) { lastRefreshError }

    private fun snapshot(): StreamSource = synchronized(playlistLock) {
        check(!closed)
        val now = nowMillis()
        if (currentBytes == null || !firstFetch && now >= nextRefresh) {
            val source = mediaPlaylist ?: upstream
            var (base, bytes) = fetch(source, if (source == upstream) playlistHeaders else resourceHeaders(source), WebVideoLivePlaylist.MAX_BYTES)
            val selectedPlaylist = if (mediaPlaylist == null) {
                val rendition = WebVideoLivePlaylist.singleRendition(base, bytes)
                if (rendition != null) {
                    val response = fetch(rendition, resourceHeaders(rendition), WebVideoLivePlaylist.MAX_BYTES)
                    base = response.first; bytes = response.second
                }
                rendition ?: upstream
            } else source
            val incoming = WebVideoLivePlaylist.parse(base, bytes)
            val previous = current
            if (previous == null) {
                val init = fetch(incoming.initialization, resourceHeaders(incoming.initialization), 2 * 1024 * 1024).second
                validateInitialization(init)
                initializationBytes = init
                WebVideoContainer.liveVideoTrack(init)?.let { video ->
                    // Scan a bounded tail of this rendition's first window. A
                    // verified sync fragment avoids feeding a fresh decoder
                    // frames that still reference the previous GOP.
                    val last = incoming.segments.lastIndex
                    val start = (last - 2).coerceAtLeast(0)
                    val deadline = nowMillis() + 2200
                    for (index in (start downTo (start - 3).coerceAtLeast(0)) + ((start + 1)..last)) {
                        if (closed || nowMillis() >= deadline) break
                        val uri = incoming.segments[index].uri
                        val fragment = runCatching { fetch(uri, resourceHeaders(uri), 4 * 1024 * 1024, deadline).second }.getOrNull()
                            ?: continue
                        if (!WebVideoContainer.liveStartsAtSync(fragment, video)) continue
                        startupSequence = incoming.sequence + index
                        startupFragment = uri to fragment
                        break
                    }
                }
            }
            if (previous != null) {
                require(incoming.sequence >= previous.sequence) { "Live sequence moved backwards" }
                require(incoming.initialization == previous.initialization) { "Live initialization changed" }
                val sharedStart = incoming.sequence
                val sharedEnd = minOf(previous.sequence + previous.segments.size, incoming.sequence + incoming.segments.size)
                for (sequence in sharedStart until sharedEnd) {
                    val old = previous.segments[(sequence - previous.sequence).toInt()]
                    val next = incoming.segments[(sequence - incoming.sequence).toInt()]
                    require(old.uri == next.uri && old.durationSeconds == next.durationSeconds) { "Live rendition changed" }
                }
            }
            val advanced = previous == null || incoming.sequence != previous.sequence || incoming.segments.size != previous.segments.size
            synchronized(this) {
                check(!closed)
                val expired = resources.filterValues { now - it.lastUsed > 90_000L }.keys.toList()
                for (uri in expired) resources.remove(uri)?.let { server.revoke(it.local) }
                require((resources.keys + incoming.segments.map { it.uri } + incoming.initialization).size <= 512)
                val skip = ((startupSequence ?: incoming.sequence) - incoming.sequence).coerceAtLeast(0).toInt()
                // FFmpeg/MPV starts at the third segment from the edge. The
                // first snapshot has at most three segments from the sync point.
                // Subsequent refreshes expose the ordinary rolling window.
                val end = if (previous == null && startupSequence != null) minOf(skip + 3, incoming.segments.size)
                    else incoming.segments.size
                currentBytes = incoming.localize(skip, end) { uri, initialization ->
                    resources.getOrPut(uri) { Resource(publishResource(uri, initialization), now) }
                        .also { it.lastUsed = now }.local
                }
            }
            current = incoming
            if (firstSequence == null) firstSequence = incoming.sequence
            refreshCount++
            mediaPlaylist = selectedPlaylist
            nextRefresh = nowMillis() + incoming.targetSeconds * (if (advanced) 1000L else 500L)
        }
        ByteSource(requireNotNull(currentBytes))
    }

    private fun servePlaylist(): StreamSource = try {
        synchronized(playlistLock) {
            snapshot().also { firstFetch = false }
        }
    } catch (error: Exception) {
        synchronized(playlistLock) {
            lastRefreshError = error.message?.takeIf { it in setOf("Live sequence moved backwards", "Live initialization changed", "Live rendition changed") }
                ?: error.javaClass.simpleName
        }
        throw error
    }

    private fun publishResource(uri: URI, initialization: Boolean): String {
        if (initialization) return server.publish(ByteSource(requireNotNull(initializationBytes)), "init.mp4")
        startupFragment?.takeIf { it.first == uri }?.let {
            startupFragment = null
            return server.publish(ByteSource(it.second), "fragment.m4s")
        }
        return server.publish(object : StreamSnapshotSource {
            override fun snapshot(): StreamSource = ByteSource(fetch(uri, resourceHeaders(uri), 16 * 1024 * 1024).second)
            override val size get() = error("Resource needs a request snapshot")
            override fun open(): StreamSource.Reader = error("Resource needs a request snapshot")
        }, "fragment.m4s")
    }

    private fun fetch(uri: URI, headers: Map<String, String>, limit: Int, deadline: Long? = null): Pair<URI, ByteArray> {
        check(!closed && transfers.tryAcquire(10, java.util.concurrent.TimeUnit.SECONDS))
        try {
            val connection = http.open(uri, "", headers, sameOriginOnly = true, quickProbe = deadline != null)
            try {
                require(connection.responseCode == 200 && connection.contentLengthLong <= limit)
                val bytes = connection.inputStream.use { input ->
                    val body = java.io.ByteArrayOutputStream()
                    val buffer = ByteArray(32 * 1024)
                    while (true) {
                        check(!closed && (deadline == null || nowMillis() < deadline))
                        val read = input.read(buffer)
                        if (read < 0) break
                        require(body.size() + read <= limit)
                        body.write(buffer, 0, read)
                    }
                    body.toByteArray()
                }
                require(!closed && bytes.size in 1..limit && (connection.contentLengthLong < 0 || connection.contentLengthLong == bytes.size.toLong()))
                return connection.url.toURI() to bytes
            } finally { http.release(connection) }
        } finally { transfers.release() }
    }

    override fun close() {
        val urls = synchronized(this) {
            closed = true
            startupFragment = null
            (resources.values.map { it.local } + listOfNotNull(localUrl)).also { resources.clear(); localUrl = null }
        }
        http.close()
        urls.forEach(server::revoke)
    }

    private class ByteSource(private val bytes: ByteArray) : StreamSource {
        override val size = bytes.size.toLong()
        override fun open() = object : StreamSource.Reader {
            override fun read(offset: Long, buffer: ByteArray, length: Int): Int {
                if (offset >= size) return -1
                val count = minOf(length, bytes.size - offset.toInt())
                bytes.copyInto(buffer, 0, offset.toInt(), offset.toInt() + count)
                return count
            }
            override fun close() = Unit
        }
    }
}
