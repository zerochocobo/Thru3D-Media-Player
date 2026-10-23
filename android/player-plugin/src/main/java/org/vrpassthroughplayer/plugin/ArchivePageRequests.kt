package org.vrpassthroughplayer.plugin

/** The selection is registered before the photo worker runs, so stale work cannot arm a new read. */
internal class ArchivePageRequests(private val settleNanos: Long = 120_000_000L) {
    private class Selection(val id: Int, val uri: String, val readyAt: Long,
                            val cancellation: CloudCancellation = CloudCancellation())
    private var selected: Selection? = null

    fun select(id: Int, uri: String) {
        val previous = synchronized(this) {
            selected.also { selected = Selection(id, uri, System.nanoTime() + settleNanos) }
        }
        previous?.cancellation?.cancel()
    }

    fun begin(id: Int, uri: String): CloudCancellation {
        val request = synchronized(this) { selected?.takeIf { it.id == id && it.uri == uri } }
            ?: throw InterruptedException("Archive reading cancelled or timed out")
        while (true) {
            if (Thread.currentThread().isInterrupted || request.cancellation.cancelled || !isCurrent(id, uri)) throw InterruptedException("Archive reading cancelled or timed out")
            val remaining = request.readyAt - System.nanoTime()
            if (remaining <= 0) return request.cancellation
            Thread.sleep(minOf(20L, (remaining / 1_000_000L).coerceAtLeast(1)))
        }
    }

    @Synchronized fun isCurrent(id: Int, uri: String): Boolean =
        selected?.let { it.id == id && it.uri == uri && !it.cancellation.cancelled } == true

    fun cancel(id: Int? = null) {
        val previous = synchronized(this) {
            selected?.takeIf { id == null || it.id == id }?.also { selected = null }
        }
        previous?.cancellation?.cancel()
    }
}
