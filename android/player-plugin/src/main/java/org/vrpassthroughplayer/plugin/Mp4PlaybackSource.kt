package org.vrpassthroughplayer.plugin

import java.io.IOException

/** A lossless address map. Only chunk offsets change; sample bytes, clocks,
 * codec configuration, edit lists and track identities stay unchanged. */
internal class Mp4PlaybackLayout(val originalSize: Long, val header: ByteArray,
    val chunks: List<Chunk>, val audioChunks: List<AudioReadSpan>) {
    data class Chunk(val start: Long, val origin: Long, val length: Long)
    val size = Math.addExact(chunks.last().start, chunks.last().length)
    init {
        require(header.isNotEmpty() && chunks.isNotEmpty() && chunks.first().start == header.size.toLong())
        chunks.forEachIndexed { i, c ->
            require(c.origin >= 0 && c.length > 0 && c.origin <= originalSize - c.length)
            if (i > 0) require(chunks[i - 1].start + chunks[i - 1].length == c.start)
        }
    }
    fun chunk(offset: Long): Chunk {
        var low = 0; var high = chunks.size
        while (low < high) {
            val mid = (low + high) ushr 1
            if (chunks[mid].start + chunks[mid].length <= offset) low = mid + 1 else high = mid
        }
        return chunks[low]
    }
}

/** MPV sees an ordinary interleaved MP4, backed by bounded original-file reads.
 * No transcoding, rewritten cloud file, disk copy, or full-file download. */
internal class Mp4PlaybackSource(private val origin: StreamSource, val layout: Mp4PlaybackLayout,
    onRead: (Int) -> Unit = {}) : StreamSource {
    override val size = layout.size
    private val transport = InterleaveReadCache(origin, onRead = onRead, audioChunks = layout.audioChunks,
        maxForwardGapBytes = 1024 * 1024)
    @Volatile private var closed = false
    init { require(origin.size == layout.originalSize) }
    val cloud get() = origin is CloudStreamSource
    fun forkOrigin(): StreamSource? = origin.fork()
    fun stats() = transport.stats()
    override fun open(): StreamSource.Reader {
        check(!closed)
        val reader = transport.open()
        return object : UpstreamMeteredReader {
            @Volatile private var done = false
            private val scratch = ByteArray(64 * 1024)
            override fun read(offset: Long, buffer: ByteArray, length: Int): Int {
                if (closed || done || Thread.currentThread().isInterrupted) throw IOException("Request cancelled")
                require(offset in 0 until size && length in 1..buffer.size)
                var count = 0
                val wanted = minOf(length.toLong(), size - offset).toInt()
                while (count < wanted) {
                    if (closed || done || Thread.currentThread().isInterrupted) throw IOException("Request cancelled")
                    val at = offset + count
                    if (at < layout.header.size) {
                        val n = minOf(wanted - count, layout.header.size - at.toInt())
                        layout.header.copyInto(buffer, count, at.toInt(), at.toInt() + n); count += n
                    } else {
                        val chunk = layout.chunk(at)
                        val relative = at - chunk.start
                        val n = reader.read(chunk.origin + relative, scratch,
                            minOf((wanted - count).toLong(), chunk.length - relative, scratch.size.toLong()).toInt())
                        if (n <= 0) throw IOException("Invalid MP4 source read")
                        scratch.copyInto(buffer, count, 0, n); count += n
                    }
                }
                return count
            }
            override fun close() { done = true; reader.close() }
        }
    }
    override fun close() { closed = true; transport.close() }
}
