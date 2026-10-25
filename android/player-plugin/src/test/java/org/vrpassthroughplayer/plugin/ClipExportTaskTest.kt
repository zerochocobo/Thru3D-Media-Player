package org.vrpassthroughplayer.plugin

import org.junit.Assert.*
import org.junit.Test
import java.util.concurrent.CountDownLatch
import java.util.concurrent.Executors
import java.util.concurrent.TimeUnit

class ClipExportTaskTest {
    @Test fun acceptedCancellationInterruptsOnceAndPreventsPublication() {
        val task = ClipExportTask()
        var interrupts = 0
        assertTrue(task.cancel { interrupts++ })
        assertFalse(task.cancel { interrupts++ })
        assertEquals(1, interrupts)
        var published = false
        try { task.commit { published = true }; fail("Cancelled clip published") }
        catch (expected: IllegalStateException) { assertEquals("Clip export cancelled", expected.message) }
        assertFalse(published)
        assertTrue(task.finish())
    }

    @Test fun completedOrFailedJobsRejectLateCancellation() {
        val saved = ClipExportTask()
        saved.commit { }
        assertFalse(saved.cancel { fail("Saved clip interrupted") })
        assertFalse(saved.finish())
        val failed = ClipExportTask()
        assertFalse(failed.finish())
        assertFalse(failed.cancel { fail("Finished job interrupted") })
    }

    @Test fun publicationAndCancellationCannotBothWin() {
        val pool = Executors.newFixedThreadPool(2)
        try {
            repeat(100) {
                val task = ClipExportTask()
                val start = CountDownLatch(1)
                val publication = pool.submit<Boolean> {
                    assertTrue(start.await(5, TimeUnit.SECONDS))
                    try { task.commit { }; true } catch (_: IllegalStateException) { false }
                }
                val cancellation = pool.submit<Boolean> {
                    assertTrue(start.await(5, TimeUnit.SECONDS))
                    task.cancel { }
                }
                start.countDown()
                assertNotEquals(publication.get(5, TimeUnit.SECONDS), cancellation.get(5, TimeUnit.SECONDS))
            }
        } finally { pool.shutdownNow() }
    }
}
