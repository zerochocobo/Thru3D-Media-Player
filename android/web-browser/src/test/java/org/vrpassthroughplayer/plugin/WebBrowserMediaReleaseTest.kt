package org.vrpassthroughplayer.plugin

import org.junit.Assert.*
import org.junit.Test
import java.util.concurrent.CountDownLatch
import java.util.concurrent.TimeUnit

class WebBrowserMediaReleaseTest {
    @Test fun workerCannotPassPendingUiTeardownButCanStartAfterConfirmation() {
        val release = WebBrowserMediaRelease()
        assertTrue(release.await(0))
        val ticket = release.begin()
        assertFalse(release.await(0))
        val entered = CountDownLatch(1)
        val finished = CountDownLatch(1)
        var result = false
        val worker = Thread { entered.countDown(); result = release.await(2000); finished.countDown() }
        worker.start()
        assertTrue(entered.await(1, TimeUnit.SECONDS))
        assertFalse(finished.await(20, TimeUnit.MILLISECONDS))
        ticket.complete(true)
        assertTrue(finished.await(1, TimeUnit.SECONDS))
        worker.join()
        assertTrue(result)
    }
    @Test fun oldCompletionCannotReleaseANewerPendingBrowserClose() {
        val release = WebBrowserMediaRelease()
        val old = release.begin()
        val latest = release.begin()
        old.complete(true)
        assertFalse(release.await(0))
        latest.complete(true)
        assertTrue(release.await(0))
    }
    @Test fun timeoutAndFailedTeardownDoNotSilentlyStartAnotherDecoder() {
        val release = WebBrowserMediaRelease()
        val ticket = release.begin()
        assertFalse(release.await(1))
        ticket.complete(false)
        assertFalse(release.await(0))
        release.begin().complete(true)
        assertTrue(release.await(0))
    }
}
