package org.vrpassthroughplayer.plugin

import java.io.Closeable

/** Each track has an independent authenticated Range reader and unguessable local lease.
 * No signed upstream URL reaches mpv logs, Godot preferences, or the media history. */
internal class WebVideoStreams(private val server: () -> LocalStreamServer) : Closeable {
    internal class Lease(val page: String, val video: String, val audio: String?, val manifests: List<WebVideoHls> = emptyList())
    private val descriptors = LinkedHashMap<String, WebVideoDescriptor>()
    private val leases = LinkedHashMap<String, Lease>()
    private val current = HashMap<String, Lease>()
    private val preparing = java.util.concurrent.ConcurrentHashMap.newKeySet<WebVideoHls>()
    private var closed = false

    @Synchronized fun remember(descriptor: WebVideoDescriptor) {
        check(!closed) { "Video session closed" }
        descriptors.remove(descriptor.page.url)
        descriptors[descriptor.page.url] = descriptor
        while (descriptors.size > 16) descriptors.remove(descriptors.keys.first())
    }
    @Synchronized fun descriptor(page: String): WebVideoDescriptor? = descriptors[page]
    @Synchronized fun audio(page: String): List<SidecarAudio.Track> {
        val lease = current[page] ?: error("Video handoff is not ready")
        return lease.audio?.let { listOf(SidecarAudio.Track(it, "Original audio", requiredPrimary = true)) } ?: emptyList()
    }

    /** Network worker only. Publish neither half until both Range probes have succeeded. */
    fun prepare(descriptor: WebVideoDescriptor): String {
        synchronized(this) { check(!closed) { "Video session closed" } }
        val local = server()
        val published = ArrayList<String>()
        val manifests = ArrayList<WebVideoHls>()
        fun publish(track: WebVideoTrack, label: String): String {
            if (track.transport == "hls") {
                val hls = synchronized(this) {
                    check(!closed)
                    WebVideoHls(local).also { manifests.add(it); preparing.add(it) }
                }
                return hls.prepare(track)
            }
            // Deliberately fail an expired lease. Refresh must first prove byte identity; silently
            // reusing old cached bytes for a different representation can corrupt playback.
            val source = HttpRangeStreamSource(MediaServerAccount("web-video", "Web video", "http://127.0.0.1", "")) {
                MediaStreamLink(track.url, "${descriptor.page.id}:${track.formatId}", remote = true, headers = track.headers)
            }
            // Some Bilibili CDN edges accept finite ranges but ignore an open-ended range.
            // Never reinterpret HTTP 200 as a successful nonzero seek.
            source.boundedRanges(track.chunkBytes.takeIf { it > 0 } ?: (1024L * 1024))
            return try { local.publish(source, "$label.${track.extension}").also { published.add(it) } }
            catch (e: Exception) { source.close(); throw e }
        }
        try {
            val audio = descriptor.audio?.let { publish(it, "audio") }
            val video = publish(descriptor.video, "video")
            synchronized(this) {
                check(!closed) { "Video session closed" }
                val lease = Lease(descriptor.page.url, video, audio, manifests)
                leases[video] = lease; current[lease.page] = lease
            }
            return video
        } catch (e: Exception) { published.forEach(local::revoke); manifests.forEach(WebVideoHls::close); throw e }
        finally { manifests.forEach(preparing::remove) }
    }

    fun release(video: String) {
        val lease = synchronized(this) {
            leases.remove(video)?.also { if (current[it.page] === it) current.remove(it.page) }
        } ?: return
        val local = server()
        local.revoke(lease.video); lease.audio?.let(local::revoke)
        lease.manifests.forEach(WebVideoHls::close)
    }

    override fun close() {
        val active = synchronized(this) {
            closed = true; descriptors.clear(); current.clear()
            leases.values.toList().also { leases.clear() }
        }
        preparing.toList().forEach(WebVideoHls::close); preparing.clear()
        if (active.isNotEmpty()) server().let { local -> active.forEach { local.revoke(it.video); it.audio?.let(local::revoke); it.manifests.forEach(WebVideoHls::close) } }
    }
}
