package org.vrpassthroughplayer.plugin

import java.net.HttpURLConnection
import java.net.URI

/** Only the small shortcut is downloaded. Media streaming remains MPV's job. */
internal object StrmHttp {
    fun read(value: String): StrmDocument {
        var uri = URI(value)
        repeat(6) {
            if (uri.scheme !in setOf("http", "https") || uri.host.isNullOrEmpty()) throw StrmFailure("STRM_INVALID_ADDRESS")
            val request = uri.toURL().openConnection() as HttpURLConnection
            try {
                request.connectTimeout = 15000; request.readTimeout = 15000
                request.instanceFollowRedirects = false; request.useCaches = false
                request.setRequestProperty("Accept-Encoding", "identity")
                val status = request.responseCode
                if (status in setOf(301, 302, 303, 307, 308)) {
                    uri = uri.resolve(request.getHeaderField("Location") ?: throw StrmFailure("STRM_READ_FAILED"))
                } else {
                    if (status in setOf(401, 403)) throw StrmFailure("STRM_ACCESS_DENIED")
                    if (status == 404 || status == 410) throw StrmFailure("STRM_NOT_FOUND")
                    if (status != 200) throw StrmFailure("STRM_READ_FAILED")
                    if (request.contentLengthLong > StrmFile.MAX_BYTES) throw StrmFailure("STRM_TOO_LARGE")
                    return StrmDocument(request.inputStream.use(StrmFile::read), uri.toASCIIString())
                }
            } finally { request.disconnect() }
        }
        throw StrmFailure("STRM_READ_FAILED")
    }
}
