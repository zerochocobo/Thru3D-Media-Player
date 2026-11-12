package org.vrpassthroughplayer.plugin

import java.util.Collections
import java.util.concurrent.CountDownLatch
import java.util.concurrent.TimeUnit
import org.junit.Assert.*
import org.junit.Test

class SmbBrowseRequestsTest {
    private class Harness(deadlineMs: Long = 10_000) {
        val emitted: MutableList<Pair<Int, String>> = Collections.synchronizedList(mutableListOf())
        val stalled: MutableList<String> = Collections.synchronizedList(mutableListOf())
        val delivered = CountDownLatch(1)
        val requests = SmbBrowseRequests(deadlineMs, { stalled.add(it) }) { id, json -> emitted.add(id to json); delivered.countDown() }
    }

    @Test fun newerListingIsNotQueuedBehindAStalledOne() {
        val h = Harness()
        val release = CountDownLatch(1)
        val started = CountDownLatch(1)
        val oldInterrupted = CountDownLatch(1)
        h.requests.submit(1, "nas", {
            started.countDown()
            try { release.await(); "old" } catch (_: InterruptedException) { oldInterrupted.countDown(); "old" }
        }, { "timeout" })
        // Exercise interruption of a running listing, not cancellation before the worker starts.
        assertTrue(started.await(2, TimeUnit.SECONDS))
        h.requests.submit(2, "nas", { "new" }, { "timeout" })
        assertTrue(h.delivered.await(2, TimeUnit.SECONDS))
        assertTrue(oldInterrupted.await(2, TimeUnit.SECONDS))
        release.countDown()
        Thread.sleep(100)
        assertEquals(listOf(2 to "new"), h.emitted.toList())
        assertTrue(h.stalled.isEmpty()) // Superseding must not reset the pool playback shares.
        h.requests.close()
    }

    @Test fun stalledListingReportsTimeoutRetiresServerAndDropsLateResult() {
        val h = Harness(deadlineMs = 100)
        val release = CountDownLatch(1)
        h.requests.submit(7, "nas", {
            // JCIFS may ignore interruption while blocked on a silent socket.
            while (release.count > 0) runCatching { release.await() }
            "late"
        }, { "timeout" })
        assertTrue(h.delivered.await(2, TimeUnit.SECONDS))
        release.countDown()
        Thread.sleep(100)
        assertEquals(listOf(7 to "timeout"), h.emitted.toList())
        assertEquals(listOf("nas"), h.stalled.toList())
        h.requests.close()
    }

    @Test fun stuckListingsCannotGrowThreadsWithoutBound() {
        val h = Harness()
        val release = CountDownLatch(1)
        val started = java.util.concurrent.Semaphore(0)
        val running = java.util.concurrent.atomic.AtomicInteger()
        val peak = java.util.concurrent.atomic.AtomicInteger()
        fun stuck(): String {
            peak.accumulateAndGet(running.incrementAndGet(), ::maxOf)
            started.release()
            while (release.count > 0) runCatching { release.await() } // Ignores interruption like a silent socket.
            running.decrementAndGet()
            return "late"
        }
        for (id in 1..SmbBrowseRequests.MAX_WORKERS) { // Each must be running before the next supersedes it.
            h.requests.submit(id, "nas", ::stuck, { "timeout" })
            assertTrue(started.tryAcquire(2, TimeUnit.SECONDS))
        }
        h.requests.submit(99, "nas", ::stuck, { "timeout" })
        assertTrue(h.delivered.await(2, TimeUnit.SECONDS))
        assertEquals(listOf(99 to "timeout"), h.emitted.toList())
        assertEquals(listOf("nas"), h.stalled.toList())
        assertEquals(SmbBrowseRequests.MAX_WORKERS, peak.get())
        release.countDown()
        h.requests.close()
    }

    @Test fun completedListingCancelsItsDeadline() {
        val h = Harness(deadlineMs = 150)
        h.requests.submit(3, "nas", { "entries" }, { "timeout" })
        assertTrue(h.delivered.await(2, TimeUnit.SECONDS))
        Thread.sleep(300)
        assertEquals(listOf(3 to "entries"), h.emitted.toList())
        assertTrue(h.stalled.isEmpty())
        h.requests.close()
    }

    @Test fun closedRequestsEmitNothing() {
        val h = Harness(deadlineMs = 50)
        val release = CountDownLatch(1)
        h.requests.submit(4, "nas", { runCatching { release.await() }; "late" }, { "timeout" })
        h.requests.close()
        release.countDown()
        Thread.sleep(200)
        assertTrue(h.emitted.isEmpty())
        h.requests.submit(5, "nas", { "after" }, { "timeout" })
        Thread.sleep(100)
        assertTrue(h.emitted.isEmpty())
    }

    @Test fun retireCurrentDisposesOnlyTheLivePool() {
        val disposed = mutableListOf<Int>()
        var generation = 0
        val connection = SmbConnection({ ++generation }, { disposed.add(it) })
        connection.retireCurrent() // Nothing open yet.
        assertTrue(disposed.isEmpty())
        assertEquals(1, connection.get())
        connection.retireCurrent()
        assertEquals(listOf(1), disposed)
        assertEquals(2, connection.get())
    }
}
