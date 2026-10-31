package org.vrpassthroughplayer.plugin

import java.util.concurrent.CountDownLatch
import java.util.concurrent.TimeUnit

/** A worker may wait for UI teardown; the frame/UI thread only creates/completes tickets. */
class WebBrowserMediaRelease {
    class Ticket {
        private val done = CountDownLatch(1)
        @Volatile private var success = false
        fun complete(released: Boolean) { success = released; done.countDown() }
        fun await(timeoutMs: Long): Boolean = try {
            done.await(timeoutMs, TimeUnit.MILLISECONDS) && success
        } catch (_: InterruptedException) { Thread.currentThread().interrupt(); false }
    }
    @Volatile private var latest = Ticket().apply { complete(true) }
    fun begin(): Ticket = Ticket().also { latest = it }
    fun await(timeoutMs: Long): Boolean = latest.await(timeoutMs)
}
