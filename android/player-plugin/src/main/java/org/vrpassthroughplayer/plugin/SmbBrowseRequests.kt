package org.vrpassthroughplayer.plugin

import java.util.concurrent.Executors
import java.util.concurrent.Future
import java.util.concurrent.RejectedExecutionException
import java.util.concurrent.ScheduledFuture
import java.util.concurrent.SynchronousQueue
import java.util.concurrent.ThreadPoolExecutor
import java.util.concurrent.TimeUnit

/** The newest SMB listing wins. Each runs on its own thread, so a stalled server never queues the
 * next folder behind it, and a listing that outlives [deadlineMs] reports [timeout] instead of
 * leaving the menu loading. [stalled] lets the owner drop that server's pool. Abandoned listings
 * may stay blocked in JCIFS until its own timeout, so at most [MAX_WORKERS] threads exist; when all
 * are still stuck the server is treated as stalled at once instead of starting another. */
internal class SmbBrowseRequests(private val deadlineMs: Long = DEADLINE_MS,
    private val stalled: (String) -> Unit, private val emit: (Int, String) -> Unit) {
    private val workers = ThreadPoolExecutor(0, MAX_WORKERS, 30, TimeUnit.SECONDS, SynchronousQueue()) {
        Thread(it, "QuestSmbBrowse").apply { isDaemon = true }
    }
    private val watchdog = Executors.newSingleThreadScheduledExecutor { Thread(it, "QuestSmbBrowseDeadline").apply { isDaemon = true } }
    private class Request(val id: Int) { var work: Future<*>? = null; var deadline: ScheduledFuture<*>? = null }
    private var active: Request? = null
    private var closed = false

    @Synchronized fun submit(id: Int, server: String, work: () -> String, timeout: () -> String) {
        if (closed) return
        cancel()
        val request = Request(id)
        active = request
        try { request.work = workers.submit { work().let { finish(request, it) } } }
        catch (_: RejectedExecutionException) {
            if (!workers.isShutdown && finish(request, timeout())) stalled(server)
            return
        }
        request.deadline = watchdog.schedule({
            if (finish(request, timeout())) { request.work?.cancel(true); stalled(server) }
        }, deadlineMs, TimeUnit.MILLISECONDS)
    }

    private fun finish(request: Request, result: String): Boolean = synchronized(this) {
        if (active !== request) return false
        active = null
        request.deadline?.cancel(false)
        emit(request.id, result)
        true
    }

    /** A superseded listing is abandoned, not reported; the shared pool stays for playback. */
    @Synchronized fun cancel() {
        val previous = active ?: return
        active = null
        previous.deadline?.cancel(false)
        previous.work?.cancel(true)
    }

    @Synchronized fun close() { cancel(); closed = true; workers.shutdownNow(); watchdog.shutdownNow() }

    companion object {
        /** Covers one 15 s response timeout plus a reconnect, as SmbConnection.read retries once. */
        const val DEADLINE_MS = 25_000L
        const val MAX_WORKERS = 4
    }
}
