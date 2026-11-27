package org.vrpassthroughplayer.plugin

import java.util.concurrent.LinkedBlockingQueue
import java.util.concurrent.ThreadPoolExecutor
import java.util.concurrent.TimeUnit
import java.util.concurrent.Future

/** One active browse, including its HTTP connection. Obsolete work never emits a result. */
internal class CloudBrowseRequests {
    // At most one unwinding worker per account. A cancelled socket in one
    // account cannot consume the execution slot of the next one.
    private val workers = HashMap<String, ThreadPoolExecutor>()
    private var closed = false
    private var activeWorker: ThreadPoolExecutor? = null
    private var active: Pair<Int, CloudCancellation>? = null
    private var future: Future<*>? = null
    @Synchronized fun submit(id: Int, work: (CloudCancellation) -> String, emit: (Int, String) -> Unit, account: String = "") {
        if (closed) return
        cancel()
        val cancellation = CloudCancellation("browse", id)
        cancellation.mark("worker_submit")
        active = id to cancellation
        workers.entries.removeAll { (_, worker) ->
            (worker.poolSize == 0 && worker.queue.isEmpty()).also { if (it) worker.shutdown() }
        }
        val worker = workers.getOrPut(account) {
            ThreadPoolExecutor(1, 1, 30, TimeUnit.SECONDS, LinkedBlockingQueue()) { task ->
                Thread(task, "QuestCloudBrowse")
            }.apply { allowCoreThreadTimeOut(true) }
        }
        activeWorker = worker
        future = worker.submit {
            cancellation.mark("worker_started")
            val result = work(cancellation)
            synchronized(this) {
                if (active?.second === cancellation && !cancellation.cancelled) {
                    active = null
                    emit(id, result)
                }
            }
        }
    }
    @Synchronized fun cancel(id: Int? = null) {
        if (id != null && active?.first != id) return
        future?.let {
            it.cancel(true)
            if (it is Runnable) activeWorker?.remove(it)
        }
        activeWorker = null
        active?.second?.let { it.mark("cancel_requested"); it.cancel() }
        active = null
        future = null
    }
    @Synchronized fun close() {
        closed = true
        cancel()
        workers.values.forEach { it.shutdownNow() }
        workers.clear()
    }
}
