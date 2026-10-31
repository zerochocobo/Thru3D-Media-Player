package org.vrpassthroughplayer.plugin

import java.io.IOException
import java.net.URI
import java.util.concurrent.atomic.AtomicBoolean

/** Reuse the independently owned SMB loopback lease; never switch the active video. */
internal object PdfSmbSource {
    // The SMB browser deliberately stores literal filenames, including spaces, [] and %.
    // java.net.URI must not interpret those names as escaped paths, queries or fragments.
    fun supported(uri: String): Boolean {
        if (!uri.startsWith("smb://") || uri.any { it.isISOControl() }) return false
        val rest = uri.removePrefix("smb://")
        val server = rest.substringBefore('/')
        val path = rest.substringAfter('/', "").split('/')
        return server.matches(Regex("[A-Za-z0-9-]+")) && path.size >= 2 &&
            path.none { it.isEmpty() || it == "." || it == ".." || '\\' in it }
    }

    fun open(uri: String, cancellation: CloudCancellation,
        publish: (String) -> Pair<String, Long>, release: (String) -> Unit,
        available: (String) -> Boolean): PdfNetworkSource {
        require(supported(uri)) { "PDF_UNAVAILABLE" }
        if (cancellation.cancelled) throw IOException("PDF_NETWORK_UNAVAILABLE")
        val (lease, size) = try { publish(uri) }
            catch (error: Exception) { throw IOException("PDF_NETWORK_UNAVAILABLE", error) }
        val finished = AtomicBoolean()
        var transport: CloudStreamSource? = null
        val dispose = {
            if (finished.compareAndSet(false, true)) {
                try { transport?.close() } finally { release(lease) }
            }
        }
        try {
            val target = URI(lease)
            require(target.scheme == "http" && target.host == "127.0.0.1" &&
                target.rawUserInfo == null && target.port in 1..65535 && size > 0) { "PDF_NETWORK_UNAVAILABLE" }
            // The local SMB server serves exact ranges; no CDN request pacing is needed.
            val source = CloudStreamSource(size, { CloudLink(lease) { emptyMap() } }, linkConnection = { requested, link ->
                require(requested.toASCIIString() == lease && link.url == lease) { "PDF_NETWORK_UNAVAILABLE" }
                CancellableMediaConnection.open(requested)
            })
                .boundedRanges(PdfReadCache.BLOCK_BYTES.toLong())
            transport = source
            cancellation.attachAction { dispose() }
            val owned = object : StreamSource by source { override fun close() { dispose() } }
            return PdfNetworkSource(owned) {
                if (finished.get() || cancellation.cancelled || !available(lease))
                    throw IOException("PDF_NETWORK_UNAVAILABLE")
            }
        } catch (error: Exception) { dispose(); throw error }
    }
}
