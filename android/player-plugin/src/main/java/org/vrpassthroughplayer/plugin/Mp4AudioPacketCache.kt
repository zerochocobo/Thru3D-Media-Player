package org.vrpassthroughplayer.plugin

import java.util.LinkedHashMap

internal data class AudioReadSpan(val start: Long, val end: Long)

/** Retain compressed audio bytes, not the video a socket speculatively emits
 * after them. Called under the owning transport lock. Valid intervals prevent
 * a partial response from publishing unfilled bytes as cached audio. */
internal class Mp4AudioPacketCache(private val spans: List<AudioReadSpan>, private val budget: Int = 8 * 1024 * 1024,
                                 private val maxEntries: Int = 4096) {
    private class Packet(val bytes: ByteArray, var from: Int, var to: Int)
    private val packets = LinkedHashMap<Long, Packet>(32, .75f, true)
    private var bytes = 0L
    init {
        require(budget > 0 && maxEntries > 0)
        spans.forEachIndexed { i, span ->
            require(span.start >= 0 && span.end > span.start && (i == 0 || spans[i - 1].end <= span.start))
        }
    }
    private fun at(offset: Long): Int {
        var low = 0; var high = spans.size
        while (low < high) {
            val middle = (low + high) ushr 1
            if (spans[middle].end <= offset) low = middle + 1 else high = middle
        }
        return low
    }
    fun end(offset: Long): Long? {
        val span = spans.getOrNull(at(offset)) ?: return null
        if (offset < span.start) return null
        val packet = packets[span.start] ?: return null
        val relative = (offset - span.start).toInt()
        return if (relative >= packet.from && relative < packet.to) span.start + packet.to else null
    }
    fun read(offset: Long, buffer: ByteArray, length: Int): Int {
        val end = end(offset) ?: return 0
        val span = spans[at(offset)]; val packet = packets.getValue(span.start)
        val count = minOf(length.toLong(), end - offset).toInt()
        packet.bytes.copyInto(buffer, 0, (offset - span.start).toInt(), (offset - span.start).toInt() + count)
        return count
    }
    fun capture(offset: Long, buffer: ByteArray, length: Int) {
        var index = at(offset); val end = offset + length
        while (index < spans.size && spans[index].start < end) {
            val span = spans[index++]
            val size = span.end - span.start
            if (size > budget) continue // A large chunk still uses the transport; storage stays bounded.
            val from = (maxOf(offset, span.start) - span.start).toInt()
            val to = (minOf(end, span.end) - span.start).toInt()
            var packet = packets[span.start]
            if (packet == null) {
                while (bytes + size > budget || packets.size >= maxEntries) {
                    val old = packets.entries.first(); packets.remove(old.key)
                    bytes -= old.value.bytes.size; old.value.bytes.fill(0)
                }
                packet = Packet(ByteArray(size.toInt()), from, to)
                packets[span.start] = packet; bytes += size
            } else if (from <= packet.to && to >= packet.from) {
                packet.from = minOf(packet.from, from); packet.to = maxOf(packet.to, to)
            } else {
                // Disjoint observations do not prove the intervening bytes.
                // Keep the latest interval until subsequent reads join it.
                packet.from = from; packet.to = to
            }
            buffer.copyInto(packet.bytes, from, (span.start + from - offset).toInt(), (span.start + to - offset).toInt())
        }
    }
    fun sizeBytes(): Long = bytes
    fun close() { packets.values.forEach { it.bytes.fill(0) }; packets.clear(); bytes = 0 }
}
