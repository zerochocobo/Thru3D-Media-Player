package org.vrpassthroughplayer.plugin

import java.io.File
import java.io.FileInputStream
import java.io.FileOutputStream
import java.io.IOException
import java.nio.ByteBuffer

/** One foreground, disposable original-file cache. No background/full-library downloads. */
internal class SmallRarCache(
    private val directory: File,
    private val cancellation: CloudCancellation,
    private val progress: (Long, Long) -> Unit = { _, _ -> },
) {
    val cancelled get() = cancellation.cancelled
    private fun active() { if (cancelled || Thread.currentThread().isInterrupted) throw IOException("Request cancelled") }

    fun prepare(source: CloudStreamSource, name: String, validateAccount: () -> Unit): StreamSource {
        if (source.size !in 8L..MAX_BYTES || name.substringAfterLast('.', "").lowercase() !in setOf("rar", "cbr")) return source
        active()
        cancellation.attachAction { source.close() }
        var pending: File? = null
        try {
            val signature = ByteArray(8)
            source.open().use { reader ->
                (reader as BoundedStreamReader).setRangeEnd(7)
                var offset = 0
                while (offset < signature.size) {
                    active()
                    val buffer = ByteArray(signature.size - offset)
                    val count = reader.read(offset.toLong(), buffer, buffer.size)
                    if (count !in 1..buffer.size) throw IOException("Stream interrupted")
                    buffer.copyInto(signature, offset, 0, count); offset += count
                }
            }
            // RAR5 keeps its much cheaper QO route, including encrypted headers.
            if (!signature.copyOfRange(0, 7).contentEquals(RAR4)) return source
            validateAccount(); active()
            if (!directory.isDirectory && !directory.mkdirs()) throw IOException("Archive cache unavailable")
            if (directory.usableSpace < source.size + (8L shl 20)) throw IOException("Archive cache unavailable")
            val file = File.createTempFile("comic-source-", ".rar", directory)
            pending = file
            var offset = signature.size.toLong()
            var notifiedAt = 0L
            progress(offset, source.size)
            FileOutputStream(file).use { output ->
                output.write(signature)
                source.openSmallRarDownload().use { reader ->
                    val buffer = ByteArray(256 * 1024)
                    while (offset < source.size) {
                        active(); validateAccount()
                        val wanted = minOf(buffer.size.toLong(), source.size - offset).toInt()
                        val count = reader.read(offset, buffer, wanted)
                        if (count !in 1..wanted) throw IOException("Stream interrupted")
                        output.write(buffer, 0, count); offset += count
                        val now = System.nanoTime()
                        if (now - notifiedAt >= 250_000_000L) { progress(offset, source.size); notifiedAt = now }
                    }
                }
            }
            active(); validateAccount()
            if (file.length() != source.size) throw IOException("Stream interrupted")
            val cached = CachedRarSource(file, source, validateAccount)
            try {
                progress(offset, source.size)
                pending = null
                return cached
            } catch (error: Exception) { cached.close(); throw error }
        } finally {
            cancellation.detachAction()
            pending?.delete()
        }
    }

    companion object {
        const val MAX_BYTES = 256L * 1024 * 1024
        private val RAR4 = byteArrayOf(0x52, 0x61, 0x72, 0x21, 0x1a, 0x07, 0x00)
    }
}

/** Positional reads keep the old decoder/range path; only a complete cache is published. */
internal class CachedRarSource(
    private val file: File,
    private val origin: StreamSource,
    private val validateAccount: () -> Unit,
) : StreamSource {
    private val input = FileInputStream(file)
    override val size = file.length()
    @Volatile private var closed = false
    override fun open(): StreamSource.Reader {
        check(!closed); validateAccount()
        return object : StreamSource.Reader {
            @Volatile private var done = false
            override fun read(offset: Long, buffer: ByteArray, length: Int): Int {
                if (closed || done || Thread.currentThread().isInterrupted) throw IOException("Request cancelled")
                validateAccount()
                require(offset in 0 until size && length in 1..buffer.size)
                return input.channel.read(ByteBuffer.wrap(buffer, 0, minOf(length.toLong(), size-offset).toInt()), offset)
            }
            override fun close() { done = true }
        }
    }
    override fun close() {
        closed = true
        try { input.close() } finally { try { origin.close() } finally { file.delete() } }
    }
}
