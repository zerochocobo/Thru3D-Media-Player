package org.vrpassthroughplayer.plugin

import java.io.Closeable
import java.io.File
import java.io.IOException
import java.io.RandomAccessFile

/** Stable, independently owned source. Validation also runs on cache hits after logout. */
internal class PdfNetworkSource(val source: StreamSource, val validate: () -> Unit) : Closeable {
    var identity = org.json.JSONObject()
    override fun close() = source.close()
}

/** Bounded on-disk blocks turn PDF's tiny backward/forward reads into reusable ranges.
 * A partial/failed block is never published; slots are packed, not a full-size sparse PDF.
 * Access and close are serialized by the proxy descriptor's IO handler. */
internal class PdfReadCache(
    private val input: PdfNetworkSource,
    private val file: File,
    private val blockSize: Int = BLOCK_BYTES,
    private val capacity: Int = CACHE_BLOCKS,
    private val available: () -> Long = { file.parentFile.usableSpace },
) : Closeable {
    val size = input.source.size
    private val disk = run { require(size > 0 && blockSize > 0 && capacity > 0); RandomAccessFile(file, "rw") }
    private val blocks = LinkedHashMap<Long, Int>(16, 0.75f, true)
    private var reader: StreamSource.Reader? = null
    @Volatile private var closed = false

    fun validate() {
        if (closed || Thread.currentThread().isInterrupted) throw IOException("PDF_UNAVAILABLE")
        input.validate()
    }

    @Synchronized fun read(offset: Long, buffer: ByteArray, length: Int): Int {
        validate()
        require(offset >= 0 && length in 0..buffer.size)
        if (offset >= size || length == 0) return 0
        val wanted = minOf(length.toLong(), size - offset).toInt()
        var copied = 0
        while (copied < wanted) {
            val position = offset + copied
            val block = position / blockSize
            val slot = blocks[block] ?: fetch(block)
            val within = (position % blockSize).toInt()
            val count = minOf(wanted - copied, blockSize - within)
            disk.seek(slot.toLong() * blockSize + within)
            disk.readFully(buffer, copied, count)
            copied += count
        }
        validate()
        return copied
    }

    private fun fetch(block: Long): Int {
        validate()
        val start = block * blockSize
        val count = minOf(blockSize.toLong(), size - start).toInt()
        if (available() < count + RESERVE_BYTES) throw IOException("PDF_CACHE_FULL")
        val bytes = ByteArray(count)
        // One bounded upstream body per cache miss, regardless of PDF read sizes.
        val remote = reader ?: input.source.open().also { reader = it }
        (remote as? BoundedStreamReader)?.setRangeEnd(start + count - 1)
        var received = 0
        val chunk = ByteArray(minOf(count, 64 * 1024))
        try {
            while (received < count) {
                validate()
                val wanted = minOf(chunk.size, count - received)
                val n = remote.read(start + received, chunk, wanted)
                if (n !in 1..wanted) throw IOException("PDF_NETWORK_UNAVAILABLE")
                chunk.copyInto(bytes, received, 0, n); received += n
            }
            validate()
        } catch (error: Exception) {
            runCatching { remote.close() }; reader = null
            throw error
        }
        val slot = (0 until capacity).firstOrNull { it !in blocks.values } ?: run {
            val oldest = blocks.entries.iterator().next()
            oldest.value.also { blocks.remove(oldest.key) }
        }
        disk.seek(slot.toLong() * blockSize); disk.write(bytes)
        blocks[block] = slot
        return slot
    }

    @Synchronized override fun close() {
        if (closed) return
        closed = true
        try { input.close() } finally {
            try { reader?.close() } finally { try { disk.close() } finally { file.delete() } }
        }
        reader = null; blocks.clear()
    }

    companion object {
        const val BLOCK_BYTES = 1024 * 1024
        const val CACHE_BLOCKS = 128 // At most 128 MiB per live document, released at final close.
        const val RESERVE_BYTES = 64L * 1024 * 1024
    }
}
