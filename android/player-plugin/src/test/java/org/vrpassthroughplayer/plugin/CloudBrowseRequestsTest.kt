package org.vrpassthroughplayer.plugin

import org.junit.Assert.*
import org.junit.Test
import java.net.HttpURLConnection
import java.net.URL
import java.util.concurrent.CountDownLatch
import java.util.concurrent.TimeUnit
import java.util.Collections

class CloudBrowseRequestsTest {
    @Test fun switchingDirectoryDisconnectsOldRequestAndOnlyNewPageIsEmitted() {
        val requests = CloudBrowseRequests()
        val started = CountDownLatch(1)
        val disconnected = CountDownLatch(1)
        val done = CountDownLatch(1)
        val emitted = Collections.synchronizedList(ArrayList<Int>())
        val connection = object : HttpURLConnection(URL("https://webapi.115.com/files")) {
            override fun connect() {}
            override fun usingProxy() = false
            override fun disconnect() { disconnected.countDown() }
        }
        try {
            requests.submit(1, { cancellation ->
                cancellation.attach(connection); started.countDown()
                try { disconnected.await(5, TimeUnit.SECONDS) } catch (_: InterruptedException) {}
                "obsolete"
            }, { id, _ -> emitted.add(id) })
            assertTrue(started.await(5, TimeUnit.SECONDS))
            requests.submit(2, { "new page" }, { id, _ -> emitted.add(id); done.countDown() })
            requests.cancel(1) // An old UI callback must not cancel the new directory.
            assertTrue(disconnected.await(5, TimeUnit.SECONDS))
            assertTrue(done.await(5, TimeUnit.SECONDS))
            assertEquals(listOf(2), emitted)
        } finally { requests.close() }
    }
    @Test fun nextDriveCanEmitBeforeTheOldWorkerUnwinds() {
        val requests = CloudBrowseRequests()
        val started = CountDownLatch(1)
        val release = CountDownLatch(1)
        val healthy = CountDownLatch(1)
        val stale = CountDownLatch(1)
        try {
            requests.submit(1, {
                started.countDown()
                while (release.count > 0) {
                    try { release.await() } catch (_: InterruptedException) { }
                }
                "old page"
            }, { _, _ -> stale.countDown() }, "slow")
            assertTrue(started.await(2, TimeUnit.SECONDS))
            requests.submit(2, { "healthy page" }, { _, _ -> healthy.countDown() }, "healthy")
            assertTrue(healthy.await(2, TimeUnit.SECONDS))
        } finally { release.countDown(); requests.close() }
        assertEquals(1L, stale.count)
    }
    @Test fun closingPlaybackAbortsPreparationAndPreservesHandedOffViews() {
        val session = CloudCancellation("playback", 17)
        val cancelled = CountDownLatch(1)
        session.prepare { inFlight ->
            assertEquals(17, inFlight.owner)
            inFlight.attachAction { cancelled.countDown() }
            session.cancel()
            assertTrue(inFlight.cancelled)
        }
        assertTrue(cancelled.await(1, TimeUnit.SECONDS))
        val other = CloudCancellation("playback", 18)
        val retained = other.prepare { it }
        other.cancel()
        assertFalse(retained.cancelled)
    }

    @Test fun cancelledRequestCannotAttachAnotherConnection() {
        val cancellation = CloudCancellation()
        var disconnected = false
        cancellation.cancel()
        val connection = object : HttpURLConnection(URL("https://webapi.115.com/files")) {
            override fun connect() {}
            override fun usingProxy() = false
            override fun disconnect() { disconnected = true }
        }
        try { cancellation.attach(connection); fail() } catch (_: CloudFailure) {}
        assertTrue(disconnected)
    }
}
