package org.vrpassthroughplayer.plugin

/** Pace actual upstream requests, including multiple CDN windows inside one local Range. */
internal class ArchiveRangePacer(private val intervalNanos: Long = 250_000_000L) {
    private var next = 0L
    @Synchronized fun await(cancelled: () -> Boolean) {
        while (true) {
            if (cancelled() || Thread.currentThread().isInterrupted) throw InterruptedException()
            val remaining = next - System.nanoTime()
            if (remaining <= 0) break
            Thread.sleep(minOf(50L, (remaining / 1_000_000L).coerceAtLeast(1)))
        }
        next = System.nanoTime() + intervalNanos
    }
}
