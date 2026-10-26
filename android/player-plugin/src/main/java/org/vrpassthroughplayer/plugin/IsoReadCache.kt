package org.vrpassthroughplayer.plugin

import java.io.IOException
import java.util.LinkedHashMap

/** One immutable ISO lease, shared by preflight and playback HTTP contexts.
 * Keep seek landing blocks, not every byte the loopback socket reads ahead.
 * Metadata: 8 MiB (up to 6 MiB protected after preflight); transport: 16 MiB.
 * Neither cache changes the ISO address space or the demuxer's seek targets. */
internal class IsoReadCache(source: StreamSource, private val memoryKey: String? = null, onRead: (Int) -> Unit = {}) : StreamSource {
    companion object {
        const val BLOCK_BYTES = 64 * 1024
        const val MAX_BLOCKS = 128
        private const val PROTECTED_BLOCKS = 96
    }
    override val size = source.size
    private val origin = source
    override fun shareReadAhead(onRead: (Int) -> Unit) = origin.shareReadAhead(onRead)
    override val sharedReadAheadActive get() = origin.sharedReadAheadActive
    private val transport = InterleaveReadCache(source, onRead = { if (!origin.sharedReadAheadActive) onRead(it) })
    private val lock = Any()
    private class Block(val data: ByteArray, var protected: Boolean = false)
    private val blocks = LinkedHashMap<Long, Block>(MAX_BLOCKS, .75f, true)
    private val scratch = ByteArray(BLOCK_BYTES)
    @Volatile private var closed = false
    private var playback = false
    private var metadataHits = 0L
    private var metadataLoads = 0L
    private var recalledBlocks = 0L

    init {
        // A reopen of the same disc starts from the previous lease's blocks.
        memoryKey?.let(IsoMetadataMemory::recall)?.entries?.take(MAX_BLOCKS)?.forEach { (key, data) ->
            if (key in 0..(size - 1) / BLOCK_BYTES && data.size == minOf(BLOCK_BYTES.toLong(), size - key * BLOCK_BYTES).toInt()) {
                blocks[key] = Block(data); recalledBlocks++
            }
        }
    }

    fun finishPreflight() = synchronized(lock) {
        if (!closed && !playback) {
            // Preserve the most recent landing blocks. Leave room for CLPI or
            // clip metadata first encountered by later playback and seeks.
            blocks.values.toList().takeLast(PROTECTED_BLOCKS).forEach { it.protected = true }
            playback = true
        }
    }

    fun stats(): Map<String, Long> = synchronized(lock) {
        transport.stats() + mapOf("metadata_hits" to metadataHits, "metadata_loads" to metadataLoads,
            "metadata_bytes" to blocks.values.sumOf { it.data.size.toLong() },
            "protected_blocks" to blocks.values.count { it.protected }.toLong(),
            "playback_phase" to if (playback) 1L else 0L, "recalled_blocks" to recalledBlocks)
    }

    override fun open(): StreamSource.Reader {
        check(!closed)
        val reader = transport.open()
        return object : UpstreamMeteredReader {
            @Volatile private var done = false
            private var firstBlock = -1L
            override fun read(offset: Long, buffer: ByteArray, length: Int): Int = synchronized(lock) {
                if (closed || done || Thread.currentThread().isInterrupted) throw IOException("Request cancelled")
                require(offset in 0 until size && length in 1..buffer.size)
                val key = offset / BLOCK_BYTES
                if (firstBlock < 0) firstBlock = key
                val skip = (offset % BLOCK_BYTES).toInt()
                var cached = blocks[key]
                if (cached != null) metadataHits++
                // Admit only the first two landing blocks per HTTP client.
                // An aborted index request can otherwise pollute the entire
                // metadata cache with megabytes of speculative socket output.
                if (cached == null && key - firstBlock in 0L..1L) {
                    val start = key * BLOCK_BYTES
                    val bytes = ByteArray(minOf(BLOCK_BYTES.toLong(), size - start).toInt())
                    var at = 0
                    while (at < bytes.size) {
                        val wanted = minOf(scratch.size, bytes.size - at)
                        val n = reader.read(start + at, scratch, wanted)
                        if (n !in 1..wanted) throw IOException("Invalid ISO block read")
                        scratch.copyInto(bytes, at, 0, n); at += n
                    }
                    if (blocks.size == MAX_BLOCKS) {
                        val evicted = blocks.entries.first { !it.value.protected }
                        blocks.remove(evicted.key)?.data?.fill(0)
                    }
                    cached = Block(bytes)
                    blocks[key] = cached; metadataLoads++
                }
                if (cached != null) {
                    val n = minOf(length, cached.data.size - skip)
                    cached.data.copyInto(buffer, 0, skip, skip + n)
                    n
                } else reader.read(offset, buffer, length)
            }
            override fun close() { done = true; reader.close() }
        }
    }

    override fun close() {
        closed = true
        // transport closes the origin before waiting for a blocked IO lock.
        try { transport.close() } finally {
            synchronized(lock) {
                memoryKey?.let { IsoMetadataMemory.keep(it, blocks.mapValues { entry -> entry.value.data }) }
                blocks.values.forEach { it.data.fill(0) }; blocks.clear()
            }
        }
    }
}
