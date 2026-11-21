package org.vrpassthroughplayer.plugin

import androidx.annotation.Keep
import android.graphics.Bitmap
import android.graphics.BitmapFactory
import java.io.IOException
import java.io.InputStream
import java.net.HttpURLConnection
import java.net.URI
import java.util.concurrent.atomic.AtomicReference

/** The native demuxer cannot open URLs. It asks this request-scoped reader for bounded ranges. */
@Keep
internal class ThumbnailVideoReader(
    private val job: LocalThumbnailPrefetch.Work,
    private val reader: StreamSource.Reader,
) {
    fun readAt(offset: Long, buffer: ByteArray, length: Int): Int {
        job.checkActive()
        return reader.read(offset, buffer, length).also { if (it > 0) job.mediaBytes += it }
    }

    fun isCancelled(): Boolean = job.cancelled.get()

    fun report(outcome: String, format: String, codec: String) {
        job.container = format
        job.codec = codec
        if (outcome == "embedded_cover" || outcome == "video_frame") job.stage = outcome
        else job.reason = outcome
    }

    fun decodeCover(bytes: ByteArray): Bitmap? {
        job.checkActive()
        val bounds = BitmapFactory.Options().apply { inJustDecodeBounds = true }
        BitmapFactory.decodeByteArray(bytes, 0, bytes.size, bounds)
        val sample = LocalThumbnailPrefetch.sampleSize(bounds.outWidth, bounds.outHeight) ?: return null
        return BitmapFactory.decodeByteArray(bytes, 0, bytes.size, BitmapFactory.Options().apply { inSampleSize = sample })
    }
}

/** A server without Range gets one bounded sequential read from the beginning. */
internal class DlnaThumbnailReader(private val uri: URI) : StreamSource.Reader {
    private val active = AtomicReference<HttpURLConnection?>()
    @Volatile private var closed = false
    private var requests = 0
    private var prefix: InputStream? = null
    private var prefixOffset = 0L
    var size = -1L
        private set
    var httpStatus = 0
        private set
    val sequential: Boolean get() = prefix != null

    fun probe(): Int = range(0, ByteArray(1), 1, allowPrefix = true)

    override fun read(offset: Long, buffer: ByteArray, length: Int): Int {
        if (closed) throw IOException("DLNA preview cancelled")
        val input = prefix ?: return range(offset, buffer, length, allowPrefix = false)
        if (offset != prefixOffset) return -1
        val count = input.read(buffer, 0, length)
        if (count > 0) prefixOffset += count
        return count.coerceAtLeast(0)
    }

    private fun range(offset: Long, buffer: ByteArray, length: Int, allowPrefix: Boolean): Int {
        if (closed || ++requests > 32) throw IOException("DLNA preview range limit")
        val end = offset + length - 1
        val connection = uri.toURL().openConnection(java.net.Proxy.NO_PROXY) as HttpURLConnection
        connection.instanceFollowRedirects = false
        connection.connectTimeout = 650
        connection.readTimeout = 650
        connection.setRequestProperty("Range", "bytes=$offset-$end")
        connection.setRequestProperty("Accept-Encoding", "identity")
        active.set(connection)
        try {
            if (closed) throw IOException("DLNA preview cancelled")
            httpStatus = connection.responseCode
            if (connection.contentEncoding?.equals("identity", ignoreCase = true) == false) return -1
            if (allowPrefix && httpStatus == 200) {
                val type = connection.contentType.orEmpty().lowercase()
                if (type.startsWith("text/") || type.contains("json") || type.contains("xml")) return -1
                size = connection.contentLengthLong
                prefix = connection.inputStream
                return 0
            }
            val range = try { HttpRangeStreamSource.validate(connection, offset) }
                catch (_: MediaServerFailure) { return -1 }
            if (range.second > end || (size >= 0 && range.third != size)) return -1
            size = range.third
            val count = (range.second - offset + 1).toInt()
            return connection.inputStream.use { input ->
                var received = 0
                while (received < count) {
                    if (closed) throw IOException("DLNA preview cancelled")
                    val next = input.read(buffer, received, count - received)
                    if (next <= 0) throw IOException("Short DLNA preview range")
                    received += next
                }
                received
            }
        } finally {
            if (prefix == null && active.compareAndSet(connection, null)) connection.disconnect()
        }
    }

    override fun close() {
        closed = true
        active.getAndSet(null)?.disconnect()
    }
}
