package org.vrpassthroughplayer.plugin

/** Actual upstream bytes, including repeated seek reads. A one-second window decays during stalls. */
internal class TransferMeter(private val clock: () -> Long = { System.nanoTime() / 1_000_000 }) {
    data class Snapshot(val bytes: Long, val bytesPerSecond: Long)
    private val started = clock()
    private val buckets = LongArray(11)
    private val stamps = LongArray(11) { Long.MIN_VALUE }
    private var total = 0L

    @Synchronized fun add(bytes: Int) {
        if (bytes <= 0) return
        val stamp = clock() / 100
        val index = Math.floorMod(stamp, buckets.size.toLong()).toInt()
        if (stamps[index] != stamp) { stamps[index] = stamp; buckets[index] = 0 }
        buckets[index] += bytes; total += bytes
    }

    @Synchronized fun snapshot(): Snapshot {
        val now = clock()
        val stamp = now / 100
        val recent = buckets.indices.sumOf { if (stamps[it] in (stamp - 9)..stamp) buckets[it] else 0L }
        return Snapshot(total, recent * 1000 / (now - started).coerceIn(100, 1000))
    }
}
