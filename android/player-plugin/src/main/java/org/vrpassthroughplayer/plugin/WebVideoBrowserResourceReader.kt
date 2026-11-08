package org.vrpassthroughplayer.plugin

import java.net.URI

/** Bounded media inspection shared by the resolver and the desktop capture probe. */
internal object WebVideoBrowserResourceReader {
    fun read(uri: URI, headers: Map<String, String>, prefix: Boolean, http: RemoteMediaHttp,
        check: () -> Unit): Pair<URI, ByteArray> {
        check()
        val limit = SphericalVideoMetadata.PREFIX_LIMIT
        val connection = http.open(uri, if (prefix) "bytes=0-${limit - 1}" else "", headers)
        try {
            connection.readTimeout = 5000
            if (connection.responseCode == 206) require(connection.getHeaderField("Content-Range").orEmpty().startsWith("bytes 0-"))
            if (!prefix) require(connection.contentLengthLong <= limit)
            val bytes = connection.inputStream.use { input ->
                val output = java.io.ByteArrayOutputStream()
                val buffer = ByteArray(16384)
                while (output.size() < limit) {
                    check()
                    val count = input.read(buffer, 0, minOf(buffer.size, limit - output.size()))
                    if (count < 0) break
                    output.write(buffer, 0, count)
                    if (prefix) {
                        val data = output.toByteArray()
                        val ts = WebVideoContainer.transportStream(data)
                        if (SphericalVideoMetadata.headerComplete(data, data.size) && (WebVideoContainer.parse(data)?.duration ?: 0.0) > 0 ||
                            ts != null && (ts.video == "none" || ts.width > 0 && ts.height > 0 || data.size >= 128 * 1024)) break
                    }
                }
                if (!prefix) require(output.size() < limit || input.read() == -1)
                output.toByteArray()
            }
            if (!prefix && connection.responseCode == 206) {
                val match = Regex("bytes 0-([0-9]+)/([0-9]+)").matchEntire(connection.getHeaderField("Content-Range").orEmpty())
                require(match != null && match.groupValues[1].toLong() + 1 == bytes.size.toLong() && match.groupValues[2].toLong() == bytes.size.toLong())
            }
            val finalUri = connection.url.toURI()
            val inspected = if (prefix && bytes.size >= 16 && String(bytes, 4, 4, Charsets.US_ASCII) == "ftyp" && WebVideoContainer.parse(bytes) == null) {
                val total = if (connection.responseCode == 206) Regex("bytes 0-[0-9]+/([0-9]+)")
                    .matchEntire(connection.getHeaderField("Content-Range").orEmpty())?.groupValues?.get(1)?.toLongOrNull() ?: -1L
                    else connection.contentLengthLong
                val etag = connection.getHeaderField("ETag")?.takeIf { !it.startsWith("W/") }
                if (total > bytes.size) try {
                    WebVideoMp4Header.inspect(object : Mp4InterleavePolicy.Reader {
                        override val size = total
                        override fun read(offset: Long, length: Int): ByteArray {
                            check()
                            // Repeat the original observed URL. RemoteMediaHttp preserves
                            // each redirect's existing credential scope, never the final
                            // CDN URL with credentials borrowed from the original origin.
                            val more = http.open(uri, "bytes=$offset-${offset + length - 1}", headers)
                            try {
                                more.readTimeout = 5000
                                require(more.responseCode == 206 && more.url.toURI() == finalUri)
                                require(more.getHeaderField("Content-Range") == "bytes $offset-${offset + length - 1}/$total")
                                require(etag == null || more.getHeaderField("ETag") == etag)
                                return more.inputStream.use { input ->
                                    val data = ByteArray(length);var at = 0
                                    while (at < length) { check();val n = input.read(data, at, length - at);require(n > 0);at += n }
                                    require(input.read() == -1);data
                                }
                            } finally { http.release(more) }
                        }
                    }, bytes)
                } catch (error: InterruptedException) { throw error }
                catch (_: Exception) { check();bytes }
                else bytes
            } else bytes
            return finalUri to inspected
        } finally { http.release(connection) }
    }
}
