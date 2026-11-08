package org.vrpassthroughplayer.plugin

/** Encoded packets only; never retain a decoded frame or an unbounded sender backlog. */
internal class AirplayPackets(private val limit: Int = 2 * 1024 * 1024) {
    data class Packet(val video: Boolean, val data: ByteArray, val ns: Long, val codec: Int)
    private val packets = java.util.ArrayDeque<Packet>()
    private var bytes = 0
    @Volatile var config = ByteArray(0); private set
    private var sps = ByteArray(0)
    private var pps = ByteArray(0)
    private var waitingKey = true
    private val replay = java.util.ArrayDeque<Packet>()
    private var replayBytes = 0
    private var replayValid = false
    private var parked = false
    @Synchronized fun offer(p: Packet): Boolean {
        if (p.data.isEmpty() || p.data.size > limit) return false
        if (p.video) {
            if (p.codec != 264) return false
            val previousConfig = config
            val units = nals(p.data)
            val headers = units.filter { (p.data[it.first].toInt() and 31) in 7..8 }
            for (span in headers) {
                if (span.last - span.first > 65535) return false
                val unit = byteArrayOf(0, 0, 0, 1) + p.data.copyOfRange(span.first, span.last + 1)
                if ((p.data[span.first].toInt() and 31) == 7) sps = unit else pps = unit
            }
            config = if (sps.isNotEmpty() && pps.isNotEmpty()) sps + pps else ByteArray(0)
            if (previousConfig.isNotEmpty() && !previousConfig.contentEquals(config)) {
                packets.clear(); bytes = 0; waitingKey = true
                replay.clear(); replayBytes = 0; replayValid = false
            }
            val key = units.any { (p.data[it.first].toInt() and 31) == 5 }
            if (key) { replay.clear(); replayBytes = 0; replayValid = true }
            if (replayValid) {
                if (replayBytes + p.data.size > limit) { replay.clear(); replayBytes = 0; replayValid = false }
                else { replay.addLast(p); replayBytes += p.data.size }
            }
            if (parked) return replayValid
            if (bytes + p.data.size > limit) { packets.clear(); bytes = 0; waitingKey = true }
            if (waitingKey && !key) return false
            waitingKey = false
        } else if (parked || waitingKey || p.codec !in listOf(0, 4, 8)) return false
        if (bytes + p.data.size > limit) return false
        packets.addLast(p); bytes += p.data.size; return true
    }
    @Synchronized fun take(): Packet? = packets.pollFirst()?.also { bytes -= it.data.size }
    @Synchronized fun take(video: Boolean): Packet? {
        val iterator = packets.iterator()
        while (iterator.hasNext()) {
            val next = iterator.next()
            if (next.video == video) { iterator.remove(); bytes -= next.data.size; return next }
        }
        return null
    }
    /** Keep a bounded latest GOP in RAM so headset sleep can stop XR writes without dropping TCP. */
    @Synchronized fun park() { parked = true; packets.clear(); bytes = 0; waitingKey = true }
    @Synchronized fun resume(): Long {
        if (!parked) return 0
        parked = false
        if (replayValid) { packets.addAll(replay); bytes = replayBytes; waitingKey = false }
        return replay.peekLast()?.ns ?: 0
    }
    @Synchronized fun videoReady() = config.isNotEmpty() && (if (parked) replayValid else !waitingKey)
    @Synchronized fun discontinuity(video: Boolean) {
        val iterator = packets.iterator()
        while (iterator.hasNext()) { val packet = iterator.next(); if (packet.video == video) { bytes -= packet.data.size; iterator.remove() } }
        if (video) { waitingKey = true; replay.clear(); replayBytes = 0; replayValid = false }
    }
    @Synchronized fun clear() { packets.clear(); bytes = 0; config = ByteArray(0); sps = ByteArray(0); pps = ByteArray(0); waitingKey = true; replay.clear(); replayBytes = 0; replayValid = false; parked = false }
    @Synchronized fun sizeBytes() = bytes
    @Synchronized fun retainedBytes() = bytes + replayBytes
    /** Reopen only the video producer from its latest GOP; leave queued audio in order. */
    @Synchronized fun restartVideo(): Boolean {
        val iterator = packets.iterator()
        while (iterator.hasNext()) {
            val next = iterator.next()
            if (next.video) { bytes -= next.data.size; iterator.remove() }
        }
        waitingKey = !replayValid
        if (!replayValid) return false
        while (bytes + replayBytes > limit) packets.pollFirst()?.let { bytes -= it.data.size }
        packets.addAll(replay); bytes += replayBytes
        return true
    }
    companion object {
        fun nals(data: ByteArray): List<IntRange> {
            val starts = ArrayList<Pair<Int, Int>>()
            var i = 0
            while (i + 3 < data.size) {
                if (data[i] == 0.toByte() && data[i+1] == 0.toByte() && data[i+2] == 1.toByte()) { starts.add(i to i+3); i += 3 }
                else if (data[i] == 0.toByte() && data[i+1] == 0.toByte() && data[i+2] == 0.toByte() && data[i+3] == 1.toByte()) { starts.add(i to i+4); i += 4 }
                else i++
            }
            return starts.mapIndexedNotNull { index, item ->
                val end = (starts.getOrNull(index+1)?.first ?: data.size) - 1
                if (item.second <= end) item.second..end else null
            }
        }
    }
}
