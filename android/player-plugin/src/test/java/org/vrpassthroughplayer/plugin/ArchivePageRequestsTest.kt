package org.vrpassthroughplayer.plugin

import org.junit.Assert.*
import org.junit.Test
import java.util.concurrent.CountDownLatch
import java.util.concurrent.Executors
import java.util.concurrent.TimeUnit
import java.util.concurrent.atomic.AtomicInteger

class ArchivePageRequestsTest {
    @Test fun obsoleteWorkerCannotStartAfterTheNewSelectionWasRegistered() {
        val requests=ArchivePageRequests(0)
        requests.select(1,"comic://book/0")
        requests.select(2,"comic://book/1")
        assertThrows(InterruptedException::class.java) {requests.begin(1,"comic://book/0")}
        assertFalse(requests.begin(2,"comic://book/1").cancelled)
    }

    @Test fun releasingAnOldPhotoCannotCancelTheLatestPage() {
        val requests=ArchivePageRequests(0)
        requests.select(1,"comic://book/0");val old=requests.begin(1,"comic://book/0")
        requests.select(2,"comic://book/1");val latest=requests.begin(2,"comic://book/1")
        assertTrue(old.cancelled)
        requests.cancel(1)
        assertFalse(latest.cancelled);assertTrue(requests.isCurrent(2,"comic://book/1"))
        requests.cancel(2)
        assertTrue(latest.cancelled)
    }

    @Test fun aBurstOfOneHundredPageSelectionsStartsOnlyTheFinalRead() {
        val requests=ArchivePageRequests(80_000_000)
        val worker=Executors.newSingleThreadExecutor()
        val blocked=CountDownLatch(1);val reads=AtomicInteger();val done=CountDownLatch(1)
        try {
            worker.execute {blocked.await()}
            for (id in 1..100) {
                val uri="comic://book/${id%13}"
                requests.select(id,uri)
                worker.execute {
                    try {requests.begin(id,uri);reads.incrementAndGet()}
                    catch (_: InterruptedException) { }
                    finally {if(id==100)done.countDown()}
                }
            }
            blocked.countDown()
            assertTrue(done.await(3,TimeUnit.SECONDS))
            assertEquals(1,reads.get());assertTrue(requests.isCurrent(100,"comic://book/9"))
        } finally {blocked.countDown();worker.shutdownNow()}
    }

    @Test fun aSelectionDuringTheQuietPeriodCancelsBeforeAnyRead() {
        val requests=ArchivePageRequests(300_000_000)
        val worker=Executors.newSingleThreadExecutor();val started=CountDownLatch(1)
        requests.select(1,"comic://book/0")
        try {
            val old=worker.submit<Boolean> {
                started.countDown()
                try {requests.begin(1,"comic://book/0");false} catch (_:InterruptedException){true}
            }
            assertTrue(started.await(1,TimeUnit.SECONDS))
            requests.select(2,"comic://book/1")
            assertTrue(old.get(1,TimeUnit.SECONDS))
        } finally {worker.shutdownNow()}
    }
}
