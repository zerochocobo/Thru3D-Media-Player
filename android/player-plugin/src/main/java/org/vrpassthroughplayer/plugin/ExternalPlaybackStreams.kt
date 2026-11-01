package org.vrpassthroughplayer.plugin

import android.net.Uri
import org.json.JSONObject
import java.io.Closeable
import java.io.File
import java.net.URI
import java.util.UUID

/** External credentials and temporary provider locators stay in Android memory, behind opaque ids. */
internal class ExternalPlaybackStreams(private val server: () -> LocalStreamServer) : Closeable {
    private val requests = LinkedHashMap<String, ExternalPlaybackRequest>()
    private val hls = HashMap<String, WebVideoHls>()
    private val preparing = java.util.concurrent.ConcurrentHashMap.newKeySet<WebVideoHls>()
    @Volatile private var closed = false

    @Synchronized fun receive(request: ExternalPlaybackRequest, startMs: Int): String {
        check(!closed)
        val stable = request.scheme == "file"
        val uri = if (stable) Uri.fromFile(File(URI(request.uri)).canonicalFile).toString()
            else "externalvideo://${UUID.randomUUID()}/video"
        if (!stable) {
            requests[uri] = request
            while (requests.size > 8) requests.remove(requests.keys.first())
        }
        val title = request.title.ifBlank {
            if (stable) File(URI(request.uri)).name else "Video"
        }
        return JSONObject().put("uri", uri).put("title", title).put("start_ms", startMs)
            .put("temporary", !stable).toString()
    }

    /** Playback worker only. Existing RemoteMediaHttp strips sensitive headers on cross-origin redirects. */
    fun playable(uri: String): String? {
        if (!uri.startsWith("externalvideo://")) return null
        val request = synchronized(this) { check(!closed); requests[uri] } ?: error("External video expired; open it again")
        if (request.scheme == "content") return request.uri
        val address = URI(request.uri)
        val local = server()
        if (request.mime.lowercase() in setOf("application/vnd.apple.mpegurl", "application/x-mpegurl") ||
            address.path.orEmpty().endsWith(".m3u8", true)) {
            val manifest = synchronized(this) { check(!closed); WebVideoHls(local, strictOriginHeaders = true).also { preparing.add(it) } }
            return try {
                manifest.prepare(WebVideoTrack("external", address, request.headers, "mp4", "", "", 0, 0, 0.0,
                    transport = "hls")).also { synchronized(this) { check(!closed); hls[it] = manifest } }
            } catch (failure: Exception) { manifest.close(); throw failure }
            finally { preparing.remove(manifest) }
        }
        val source = HttpRangeStreamSource(MediaServerAccount("external-video", "External video", "http://127.0.0.1", "")) {
            MediaStreamLink(address, uri, remote = true, headers = request.headers)
        }.boundedRanges(1024 * 1024L)
        return try { local.publish(source, "video.mp4") }
        catch (failure: Exception) { source.close(); throw failure }
    }

    fun release(uri: String) { synchronized(this) { hls.remove(uri) }?.close() }
    override fun close() {
        val active = synchronized(this) { closed = true; requests.clear(); hls.values.toList().also { hls.clear() } }
        preparing.forEach(WebVideoHls::close)
        active.forEach(WebVideoHls::close)
    }
}
