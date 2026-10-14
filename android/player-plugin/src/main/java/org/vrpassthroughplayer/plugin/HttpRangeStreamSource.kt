package org.vrpassthroughplayer.plugin

import java.io.InputStream
import java.net.HttpURLConnection
import java.net.URI
import java.util.concurrent.ConcurrentHashMap

internal data class MediaSubtitleLink(val url: URI, val title: String, val extension: String = "srt")
internal data class MediaAudioLink(val url: URI, val identity: String, val title: String)
internal data class MediaStreamLink(val url: URI, val identity: String,
    val subtitles: List<MediaSubtitleLink> = emptyList(), val audio: List<MediaAudioLink> = emptyList(), val basename: String = "",
    val remote: Boolean = false, val headers: Map<String, String> = emptyMap())

/** Authenticated, seekable original-file streaming. Only the local token is given to MPV. */
internal class HttpRangeStreamSource(
    account: MediaServerAccount,
    private val resolve: (MediaServerHttp) -> MediaStreamLink,
) : StreamSource {
    private val http = MediaServerHttp(account)
    private val remoteHttp = RemoteMediaHttp()
    private fun open(link: MediaStreamLink, range: String) = if (link.remote) remoteHttp.open(link.url, range, link.headers) else http.open(link.url, range)
    private fun release(connection: HttpURLConnection) { http.release(connection); remoteHttp.release(connection) }
    private var link: MediaStreamLink
    override val size: Long
    @Volatile private var closed = false
    private val readers = ConcurrentHashMap.newKeySet<RemoteReader>()
    init {
        try {
            link = resolve(http)
            val c = open(link, "bytes=0-0")
            try {
                val range = validate(c, 0)
                mediaRequire(range.second == 0L, "Server does not support seeking")
                size = range.third
            } finally { release(c) }
        } catch (e: Exception) { http.close(); remoteHttp.close(); throw e }
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
        RemoteReader().also { readers.add(it) }
    }
    override fun close() {
        closed = true
        http.close() // unblock readers before acquiring their state
        remoteHttp.close()
        java.util.ArrayList(readers).forEach { it.close() }
    }
    private inner class RemoteReader : StreamSource.Reader {
        @Volatile private var done = false
        private var connection: HttpURLConnection? = null
        private var input: InputStream? = null
        private var next = -1L
        private var end = -1L
        override fun read(offset: Long, buffer: ByteArray, length: Int): Int {
            mediaRequire(!closed && !done && offset in 0 until size && length in 1..buffer.size)
            if (next != offset || offset > end || input == null) {
                disconnect()
                var selected = current()
                var c: HttpURLConnection? = null
                try { c = open(selected, "bytes=$offset-") }
                catch (e: MediaServerFailure) {
                    if (e.code !in setOf("Server authentication required", "Remote media access denied")) throw e
                    selected = current(selected)
                    c = open(selected, "bytes=$offset-")
                }
                val opened = c!!
                try {
                    val range = validate(opened, offset)
                    mediaRequire(range.third == size, "Video changed; reopen it")
                    synchronized(this) {
                        mediaRequire(!closed && !done, "Request cancelled")
                        connection = opened; input = opened.inputStream; next = offset; end = range.second
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
        fun remote(uri: URI): HttpRangeStreamSource = HttpRangeStreamSource(
            // No saved account or token belongs to a standalone remote URL.
            MediaServerAccount("remote", "Remote", "http://127.0.0.1", ""),
            { MediaStreamLink(uri, "remote", remote = true) })
        fun validate(c: HttpURLConnection, offset: Long): Triple<Long, Long, Long> {
            mediaRequire(c.responseCode == 206, "Server does not support seeking")
            val m = Regex("bytes (\\d+)-(\\d+)/(\\d+)").matchEntire(c.getHeaderField("Content-Range").orEmpty())
                ?: throw MediaServerFailure("Invalid byte range")
            val start = m.groupValues[1].toLongOrNull() ?: -1
            val end = m.groupValues[2].toLongOrNull() ?: -1
            val total = m.groupValues[3].toLongOrNull() ?: -1
            mediaRequire(start == offset && end >= start && total > end, "Invalid byte range")
            mediaRequire(c.contentLengthLong == -1L || c.contentLengthLong == end - start + 1, "Invalid byte range")
            val type = c.contentType.orEmpty().lowercase()
            mediaRequire(!type.contains("text/") && !type.contains("json"), "Invalid media response")
            return Triple(start, end, total)
        }
    }
}
