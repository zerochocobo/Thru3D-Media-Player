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
                        if (SphericalVideoMetadata.headerComplete(data, data.size) && (WebVideoContainer.parse(data)?.duration ?: 0.0) > 0 ||
                            WebVideoContainer.transportStream(data) != null) break
                    }
                }
                if (!prefix) require(output.size() < limit || input.read() == -1)
                output.toByteArray()
            }
            if (!prefix && connection.responseCode == 206) {
                val match = Regex("bytes 0-([0-9]+)/([0-9]+)").matchEntire(connection.getHeaderField("Content-Range").orEmpty())
                require(match != null && match.groupValues[1].toLong() + 1 == bytes.size.toLong() && match.groupValues[2].toLong() == bytes.size.toLong())
            }
            return connection.url.toURI() to bytes
        } finally { http.release(connection) }
    }
}
