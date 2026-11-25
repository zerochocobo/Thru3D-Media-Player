package org.vrpassthroughplayer.plugin

import java.io.InputStream
import java.net.HttpURLConnection
import java.net.URI
import java.util.concurrent.ConcurrentHashMap

internal data class MediaSubtitleLink(val url: URI, val title: String, val extension: String = "srt", val language: String = "")
internal data class MediaAudioLink(val url: URI, val identity: String, val title: String)
internal data class MediaStreamLink(val url: URI, val identity: String,
    val subtitles: List<MediaSubtitleLink> = emptyList(), val audio: List<MediaAudioLink> = emptyList(), val basename: String = "",
    val remote: Boolean = false, val headers: Map<String, String> = emptyMap(),
    val playback: MediaServerPlaybackContext? = null)

/** Authenticated, seekable original-file streaming. Only the local token is given to MPV. */
internal class HttpRangeStreamSource(
    account: MediaServerAccount,
    private val externalVideo: Boolean = false,
    private val resolve: (MediaServerHttp) -> MediaStreamLink,
) : StreamSource {
    private val http = MediaServerHttp(account)
    private val remoteHttp = RemoteMediaHttp()
    private fun open(link: MediaStreamLink, range: String) = if (link.remote) remoteHttp.open(link.url, range, link.headers) else http.open(link.url, range)
    private fun release(connection: HttpURLConnection) { http.release(connection); remoteHttp.release(connection) }
    private var link: MediaStreamLink
    override val size: Long
    val wholeFileResponse: Boolean
    private var firstBody: HttpURLConnection? = null
    @Volatile private var closed = false
    private val readers = ConcurrentHashMap.newKeySet<RemoteReader>()
    private var rangeWindow = Long.MAX_VALUE
    private var archivePacer: ArchiveRangePacer? = null
    fun forArchiveReading(): HttpRangeStreamSource { archivePacer = ArchiveRangePacer(); return this }
    fun boundedRanges(bytes: Long): HttpRangeStreamSource {
        require(bytes > 0); rangeWindow = bytes; return this
    }
    init {
        try {
            link = resolve(http)
            val c = open(link, "bytes=0-0")
            try {
                val range = responseRange(c, 0, 0, probe = true)
                size = range.third
                wholeFileResponse = c.responseCode == 200
                // A full response may be large or single-use. Hand this very body to the first reader.
                if (wholeFileResponse) firstBody = c
            } finally { if (firstBody !== c) release(c) }
        } catch (e: Exception) { http.close(); remoteHttp.close(); throw e }
    }
    @Synchronized private fun takeFirstBody(): HttpURLConnection? = firstBody.also { firstBody = null }

    private fun responseRange(c: HttpURLConnection, offset: Long, requestedEnd: Long, probe: Boolean = false): Triple<Long, Long, Long> {
        try {
            if (externalVideo) {
                mediaRequire(c.contentEncoding.isNullOrBlank() || c.contentEncoding.equals("identity", true), "Invalid media response")
                if (c.responseCode == 200) {
                    validateMediaType(c)
                    mediaRequire(c.getHeaderField("Content-Range") == null, "Invalid byte range")
                    val length = c.contentLengthLong
                    mediaRequire(length != 0L, "Invalid media response")
                    return Triple(0L, length - 1, length)
                }
            }
            val range = validate(c, offset)
            if (!externalVideo && range.second > requestedEnd)
                throw MediaServerFailure(if (probe) "Server does not support seeking" else "Invalid byte range")
            return range
        } catch (error: MediaServerFailure) {
            if (!externalVideo) throw error
            val failure = PlaybackFailure.from(error, if (probe) "resolving" else "reading")
            val raw = c.getHeaderField("Content-Range")
            val returned = when {
                raw == null -> "absent"
                SAFE_CONTENT_RANGE.matches(raw) -> raw
                else -> "malformed"
            }
            throw PlaybackFailureException(failure.copy(httpStatus = c.responseCode,
                detail = "Requested bytes $offset-$requestedEnd, HTTP ${c.responseCode}, Content-Range $returned, length ${c.contentLengthLong}"), error)
        }
    }

    /** A 200 without a known length is an EOF-delimited stream, with no random-access contract. */
    fun withSequentialBody(consume: (InputStream) -> Unit) {
        check(size < 0)
        val selected = current()
        val c = takeFirstBody() ?: open(selected, "")
        try {
            mediaRequire(c.responseCode == 200, "Invalid media response")
            responseRange(c, 0, Long.MAX_VALUE)
            consume(c.inputStream)
        } finally { release(c) }
    }
    @Synchronized private fun current(failed: MediaStreamLink? = null): MediaStreamLink {
        mediaRequire(!closed, "Request cancelled")
        if (failed === link) {
            val fresh = resolve(http)
            mediaRequire(fresh.identity == link.identity, "Video changed; reopen it")
            link = fresh
        }
        return link
    }
    fun original(): MediaStreamLink = current()
    override fun open(): StreamSource.Reader = synchronized(this) {
        mediaRequire(!closed, "Request cancelled")
        if (archivePacer != null) readers.forEach { it.close() }
        RemoteReader().also { readers.add(it) }
    }
    override fun close() {
        closed = true
        http.close() // unblock readers before acquiring their state
        remoteHttp.close()
        takeFirstBody()
        java.util.ArrayList(readers).forEach { it.close() }
    }
    private inner class RemoteReader : BoundedStreamReader {
        @Volatile private var done = false
        private var connection: HttpURLConnection? = null
        private var input: InputStream? = null
        private var next = -1L
        private var end = -1L
        private var rangeEnd = size - 1
        override fun setRangeEnd(endInclusive: Long) {
            if (archivePacer != null) rangeEnd = minOf(endInclusive, size - 1)
        }
        override fun read(offset: Long, buffer: ByteArray, length: Int): Int {
            mediaRequire(!closed && !done && offset in 0 until size && length in 1..buffer.size)
            if (next != offset || offset > end || input == null) {
                disconnect()
                var selected = current()
                var c: HttpURLConnection? = null
                val requestedEnd = minOf(rangeEnd, offset + minOf(rangeWindow, size-offset)-1)
                val rangeRequest = if (rangeWindow == Long.MAX_VALUE && archivePacer == null) "bytes=$offset-" else "bytes=$offset-$requestedEnd"
                try {
                    archivePacer?.await { closed || done }
                    c = (if (wholeFileResponse) takeFirstBody() else null) ?: open(selected, rangeRequest)
                }
                catch (e: MediaServerFailure) {
                    if (e.code !in setOf("Server authentication required", "Remote media access denied")) throw e
                    selected = current(selected)
                    archivePacer?.await { closed || done }
                    c = open(selected, rangeRequest)
                }
                val opened = c!!
                try {
                    val range = responseRange(opened, offset, requestedEnd)
                    val full = opened.responseCode == 200
                    mediaRequire(range.third == size || (full && range.third < 0), "Video changed; reopen it")
                    val body = opened.inputStream
                    // A server that ignores a seek starts at byte zero. Consume the real prefix
                    // before serving the requested bytes, including when the container index is at EOF.
                    var remaining = offset - range.first
                    while (remaining > 0) {
                        mediaRequire(!closed && !done, "Request cancelled")
                        val count = body.read(buffer, 0, minOf(buffer.size.toLong(), remaining).toInt())
                        mediaRequire(count > 0, "Stream interrupted")
                        remaining -= count
                    }
                    synchronized(this) {
                        mediaRequire(!closed && !done, "Request cancelled")
                        connection = opened; input = body; next = offset
                        end = if (full) size - 1 else minOf(range.second, requestedEnd)
                    }
                } catch (e: Exception) { release(opened); throw e }
            }
            val n = input!!.read(buffer, 0, minOf(length.toLong(), end - offset + 1).toInt())
            mediaRequire(n > 0, "Stream interrupted")
            next = offset + n
            return n
        }
        private fun disconnect() {
            connection?.let(::release); connection = null
            runCatching { input?.close() }; input = null
        }
        override fun close() { synchronized(this) { done = true; disconnect() }; readers.remove(this) }
    }
    companion object {
        private val SAFE_CONTENT_RANGE = Regex("bytes [0-9]{1,19}-[0-9]{1,19}/[0-9]{1,19}")
        fun remote(uri: URI): HttpRangeStreamSource = HttpRangeStreamSource(
            // No saved account or token belongs to a standalone remote URL.
            MediaServerAccount("remote", "Remote", "http://127.0.0.1", "")) {
            MediaStreamLink(uri, "remote", remote = true)
        }
        fun validate(c: HttpURLConnection, offset: Long): Triple<Long, Long, Long> {
            mediaRequire(c.responseCode == 206, "Server does not support seeking")
            val m = Regex("bytes (\\d+)-(\\d+)/(\\d+)").matchEntire(c.getHeaderField("Content-Range").orEmpty())
                ?: throw MediaServerFailure("Invalid byte range")
            val start = m.groupValues[1].toLongOrNull() ?: -1
            val end = m.groupValues[2].toLongOrNull() ?: -1
            val total = m.groupValues[3].toLongOrNull() ?: -1
            mediaRequire(start == offset && end >= start && total > end, "Invalid byte range")
            mediaRequire(c.contentLengthLong == -1L || c.contentLengthLong == end - start + 1, "Invalid byte range")
            validateMediaType(c)
            return Triple(start, end, total)
        }
        private fun validateMediaType(c: HttpURLConnection) {
            val type = c.contentType.orEmpty().lowercase()
            mediaRequire(!type.contains("text/") && !type.contains("json"), "Invalid media response")
        }
    }
}
