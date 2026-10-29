package org.vrpassthroughplayer.plugin

import java.io.Closeable
import java.net.HttpURLConnection
import java.net.URI
import java.util.concurrent.ConcurrentHashMap

/** An upstream media URL from PlaybackInfo. It never receives the saved media-server token. */
internal class RemoteMediaHttp : Closeable {
    private val live = ConcurrentHashMap.newKeySet<HttpURLConnection>()
    @Volatile private var closed = false

    fun open(uri: URI, range: String, headers: Map<String, String>): HttpURLConnection {
        var target = uri
        var redirects = 0
        var resends = 0
        while (redirects < 6) {
            mediaRequire(target.scheme in setOf("http", "https") && !target.host.isNullOrEmpty() && target.rawUserInfo == null, "Invalid remote media address")
            mediaRequire(!closed && !Thread.currentThread().isInterrupted, "Request cancelled")
            val c = target.toURL().openConnection() as HttpURLConnection
            synchronized(this) {
                mediaRequire(!closed, "Request cancelled")
                live.add(c)
            }
            try {
                c.connectTimeout = 10000; c.readTimeout = 15000
                c.instanceFollowRedirects = false; c.useCaches = false
                headers.forEach { (name, value) ->
                    mediaRequire(name.matches(Regex("[A-Za-z0-9-]{1,128}")) && value.length <= 8192 && value.none { it == '\r' || it == '\n' || it == '\u0000' }, "Invalid remote media headers")
                    val key = name.lowercase()
                    if ((sameOrigin(uri, target) || key in setOf("user-agent", "accept", "accept-language")) && key !in setOf("host", "range", "content-length", "connection", "accept-encoding")) c.setRequestProperty(name, value)
                }
                c.setRequestProperty("Accept-Encoding", "identity")
                if (range.isNotEmpty()) c.setRequestProperty("Range", range)
                val status = c.responseCode
                if (status in setOf(301, 302, 303, 307, 308)) {
                    target = target.resolve(c.getHeaderField("Location") ?: throw MediaServerFailure("Invalid remote media response"))
                    release(c); redirects++
                } else {
                    if (status in setOf(401, 403)) throw MediaServerFailure("Remote media access denied", status)
                    if (status !in 200..299) throw MediaServerFailure("Remote media unavailable", status)
                    return c
                }
            } catch (error: Exception) {
                release(c)
                // Some headset network paths cut connections in short bursts (Quest 3, 2026-10-29:
                // 1 of 10 Twitch CDN requests lost its TLS handshake, failing the whole handoff).
                // A request that never got a response is sent again a little later.
                if (error !is MediaServerFailure && connectionCut(error) && resends < 2 && !closed) {
                    Thread.sleep(1500L * ++resends)
                    continue
                }
                throw if (error is MediaServerFailure) error else MediaServerFailure(when (error) {
                    is javax.net.ssl.SSLException -> "TLS certificate verification failed"
                    is java.net.SocketTimeoutException -> "Network read timed out"
                    else -> "Remote media unavailable"
                }, transportError = error.javaClass.simpleName)
            }
        }
        throw MediaServerFailure("Too many redirects")
    }

    fun release(connection: HttpURLConnection) { live.remove(connection); connection.disconnect() }
    override fun close() { synchronized(this) { closed = true }; live.toList().forEach(::release) }

    private fun connectionCut(error: Exception): Boolean = when (error) {
        // A certificate the path presents is a real answer, not a cut.
        is javax.net.ssl.SSLException -> generateSequence<Throwable>(error) { it.cause }.none { it is java.security.cert.CertificateException }
        is java.net.SocketTimeoutException -> false
        else -> error is java.net.SocketException || error is java.io.EOFException
    }

    private fun sameOrigin(a: URI, b: URI): Boolean {
        fun port(uri: URI) = if (uri.port >= 0) uri.port else if (uri.scheme == "https") 443 else 80
        return a.scheme == b.scheme && a.host?.equals(b.host, true) == true && port(a) == port(b)
    }
}
