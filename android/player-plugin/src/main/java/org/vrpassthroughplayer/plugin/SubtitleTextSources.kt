package org.vrpassthroughplayer.plugin

import java.io.Closeable
import java.io.File
import java.net.HttpURLConnection
import java.net.URI

/** Session-owned, memory-only UTF-8 leases. Re-encoding always starts from original
 * bytes and publishes a new immutable URL, shared by display and narration. */
internal class SubtitleTextSources(private val detect: (ByteArray) -> List<SubtitleEncoding.Guess>) : Closeable {
    data class Entry(val original: ByteArray, val track: SidecarSubtitles.Track,
                     val encoding: String, val choice: String, val identity: String, val decodedSize: Int)
    private val entries = LinkedHashMap<String, Entry>()
    private var server: LocalStreamServer? = null
    private var closed = false
    @Synchronized fun get(url: String): Entry? = entries[url]
    fun prepare(track: SidecarSubtitles.Track): SidecarSubtitles.Track {
        val raw = read(track.location)
        return publish(raw, track, "auto", filename(track.location).ifBlank { track.title })
    }
    fun recode(url: String, choice: String): SidecarSubtitles.Track {
        val entry = get(url) ?: error("Subtitle unavailable")
        return publish(entry.original, entry.track, choice, entry.identity)
    }
    private fun publish(raw: ByteArray, track: SidecarSubtitles.Track, choice: String, identity: String): SidecarSubtitles.Track {
        val decoded = SubtitleEncoding.decode(raw, choice, track.language, detect)
        synchronized(this) {
            check(!closed)
            require(entries.size < 64 && entries.values.sumOf { it.original.size.toLong() + it.decodedSize } + raw.size + decoded.bytes.size <= 64L * 1024 * 1024)
            val bytes = decoded.bytes
            val source = object : StreamSource {
                override val size = bytes.size.toLong()
                override fun open() = object : StreamSource.Reader {
                    override fun read(offset: Long, buffer: ByteArray, length: Int): Int {
                        require(offset >= 0 && length in 1..buffer.size)
                        if (offset >= bytes.size) return -1
                        val count = minOf(length, bytes.size - offset.toInt())
                        bytes.copyInto(buffer, 0, offset.toInt(), offset.toInt() + count)
                        return count
                    }
                    override fun close() {}
                }
            }
            val stream = server ?: LocalStreamServer().also { server = it }
            val location = stream.publish(source, identity)
            val normalized = track.copy(location = location)
            entries[location] = Entry(raw, normalized, decoded.charset, choice, identity, bytes.size)
            return normalized
        }
    }
    @Synchronized fun release(url: String) { entries.remove(url); server?.revoke(url) }
    @Synchronized override fun close() { closed = true; entries.clear(); server?.close(); server = null }
    companion object {
        private fun filename(location: String): String = if (location.startsWith("http://"))
            URI(location).path.substringAfterLast('/') else File(location).name
        private fun read(location: String): ByteArray {
            if (!location.contains("://")) return File(location).inputStream().use(::bounded)
            val uri = URI(location)
            // Raw network subtitles already have an authenticated, scoped loopback lease.
            require(uri.scheme == "http" && uri.host == "127.0.0.1" && uri.userInfo == null)
            val connection = uri.toURL().openConnection() as HttpURLConnection
            connection.connectTimeout = 3000; connection.readTimeout = 8000
            connection.instanceFollowRedirects = false
            return try {
                require(connection.responseCode == 200 && connection.contentLengthLong <= SubtitleEncoding.MAX_BYTES)
                connection.inputStream.use(::bounded)
            } finally { connection.disconnect() }
        }
        private fun bounded(input: java.io.InputStream): ByteArray {
            val output = java.io.ByteArrayOutputStream()
            val buffer = ByteArray(8192)
            while (true) {
                val count = input.read(buffer)
                if (count < 0) break
                require(output.size() + count <= SubtitleEncoding.MAX_BYTES)
                output.write(buffer, 0, count)
            }
            val bytes = output.toByteArray()
            require(bytes.isNotEmpty() && bytes.size <= SubtitleEncoding.MAX_BYTES)
            return bytes
        }
    }
}
