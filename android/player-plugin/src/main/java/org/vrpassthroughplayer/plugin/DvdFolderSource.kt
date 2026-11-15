package org.vrpassthroughplayer.plugin

import java.io.IOException

/** The bytes of a [DvdFolderImage]: its generated header, then each folder file at its extent.
 * Files open on first use, and one reader holds a single file open at a time, so a disc of
 * many parts costs the origin no more handles or connections than one ISO would. */
internal class DvdFolderSource(private val layout: DvdFolderImage.Layout, private val file: (String) -> StreamSource) : StreamSource {
    companion object {
        /** [files]: the folder's raw names and sizes; [file] opens one by the folder's own spelling. */
        fun of(files: List<Pair<String, Long>>, file: (String) -> StreamSource): DvdFolderSource {
            val named = HashMap<String, Pair<String, Long>>()
            for (item in files) {
                val name = DvdFolderImage.canonical(item.first) ?: continue
                if (named.put(name, item) != null) throw DvdFolderImage.Incomplete("duplicate $name")
            }
            val entries = DvdFolderImage.select(named.mapValues { it.value.second })
            val source = DvdFolderSource(DvdFolderImage.layout(entries)) { file(named.getValue(it).first) }
            try { DvdFolderImage.verify(entries, source::head) } catch (error: Exception) { source.close(); throw error }
            return source
        }
    }

    override val size = layout.size
    /** Changes with any file's name or length; keys read caches kept across reopens. */
    val identity: String get() = layout.extents.joinToString("/") { "${it.name}:${it.size}" }
    private val parts = HashMap<String, StreamSource>()
    private var closed = false
    override val forkable get() = true
    override fun fork(): StreamSource = DvdFolderSource(layout, file)

    private fun part(extent: DvdFolderImage.Extent): StreamSource {
        synchronized(parts) {
            if (closed) throw IOException("Request cancelled")
            parts[extent.name]?.let { return it }
        }
        val opened = file(extent.name) // May reach the network; never under the lock.
        if (opened.size != extent.size) { opened.close(); throw IOException("DVD folder changed") }
        return synchronized(parts) {
            val existing = parts[extent.name]
            if (closed || existing != null) { opened.close(); existing ?: throw IOException("Request cancelled") }
            else opened.also { parts[extent.name] = it }
        }
    }

    private fun head(name: String): ByteArray {
        val extent = layout.extents.first { it.name == name }
        val data = ByteArray(minOf(DvdFolderImage.SECTOR.toLong(), extent.size).toInt())
        part(extent).open().use { reader ->
            var at = 0
            while (at < data.size) {
                val chunk = ByteArray(data.size - at)
                val n = reader.read(at.toLong(), chunk, chunk.size)
                if (n !in 1..chunk.size) throw IOException("Invalid DVD folder read")
                chunk.copyInto(data, at, 0, n); at += n
            }
        }
        return data
    }

    override fun open(): StreamSource.Reader = object : StreamSource.Reader {
        private var current: DvdFolderImage.Extent? = null
        private var reader: StreamSource.Reader? = null
        private var done = false
        @Synchronized override fun read(offset: Long, buffer: ByteArray, length: Int): Int {
            if (done) throw IOException("Request cancelled")
            require(offset in 0 until size && length in 1..buffer.size)
            if (offset < layout.header.size) {
                val n = minOf(length.toLong(), layout.header.size - offset).toInt()
                layout.header.copyInto(buffer, 0, offset.toInt(), offset.toInt() + n)
                return n
            }
            var low = 0; var high = layout.extents.size - 1
            while (low < high) { val middle = (low + high + 1) / 2; if (layout.extents[middle].offset <= offset) low = middle else high = middle - 1 }
            val extent = layout.extents[low]
            val inside = offset - extent.offset
            if (inside >= extent.size) { // Sector padding after a file.
                val end = layout.extents.getOrNull(low + 1)?.offset ?: size
                return minOf(length.toLong(), end - offset).toInt().also { buffer.fill(0, 0, it) }
            }
            if (current !== extent) {
                reader?.close(); reader = null; current = null
                reader = part(extent).open(); current = extent
            }
            val wanted = minOf(length.toLong(), extent.size - inside).toInt()
            return reader!!.read(inside, buffer, wanted).also { if (it !in 1..wanted) throw IOException("Invalid DVD folder read") }
        }
        override fun close() {
            val open = synchronized(this) { if (done) return; done = true; reader.also { reader = null; current = null } }
            open?.close()
        }
    }

    override fun close() {
        val open = synchronized(parts) { if (closed) return; closed = true; parts.values.toList().also { parts.clear() } }
        open.forEach { runCatching { it.close() } }
    }
}
