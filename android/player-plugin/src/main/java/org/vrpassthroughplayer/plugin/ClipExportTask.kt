package org.vrpassthroughplayer.plugin

/** Cancellation and publication share one gate: an accepted cancel can never publish a file. */
internal class ClipExportTask {
    @Volatile var cancelled = false
        private set
    private var finished = false

    @Synchronized fun cancel(interrupt: () -> Unit): Boolean {
        if (finished || cancelled) return false
        cancelled = true
        interrupt()
        return true
    }

    fun checkActive() = check(!cancelled) { "Clip export cancelled" }

    @Synchronized fun commit(publish: () -> Unit) {
        checkActive()
        publish()
        finished = true
    }

    /** Called after cleanup, before the terminal result and free worker slot become visible. */
    @Synchronized fun finish(): Boolean {
        finished = true
        return cancelled
    }
}
