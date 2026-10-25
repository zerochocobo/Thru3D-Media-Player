package org.vrpassthroughplayer.plugin

import org.junit.Assert.*
import org.junit.Test
import java.io.File
import java.util.concurrent.CountDownLatch
import java.util.concurrent.Executors
import java.util.concurrent.TimeUnit
import java.util.concurrent.atomic.AtomicBoolean
import java.util.concurrent.atomic.AtomicInteger

class ReadingPageCacheTest {
    @Test fun renderLeaseNeverLoadsAMissAndSurvivesEviction() {
        val loads = AtomicInteger()
        val valid = AtomicBoolean(true)
        val cache = ReadingPageCache({ _, _ -> loads.incrementAndGet(); output() },
            { check(valid.get()) }, { it.delete() })
        try {
            assertFalse(cache.cached(page(0)))
            assertTrue(runCatching { cache.acquireCached(page(0)) }.isFailure)
            assertEquals(0, loads.get())
            cache.window(listOf(page(0)), emptyList())
            val foreground = read(cache, 0)
            val speculative = cache.acquireCached(page(0))
            assertEquals(foreground, speculative)
            cache.release(foreground)
            valid.set(false)
            assertTrue("Warm render lease validates the live source", runCatching { cache.acquireCached(page(0)) }.isFailure)
            cache.window(emptyList(), emptyList())
            assertFalse(cache.cached(page(0)))
            val file = File(java.net.URI(speculative))
            assertTrue(file.exists())
            cache.release(speculative)
            assertFalse(file.exists())
            assertEquals(1, loads.get())
        } finally { cache.close() }
    }
    private fun page(at: Int) = "pdfpage://book/$at"
    private fun output(bytes: Int = 8): File {
        val root = File("../../build/output/reading-cache/fixtures").apply { mkdirs() }
        return File.createTempFile("page-", ".jpg", root).apply { writeBytes(ByteArray(bytes) { 42 }) }
    }
    private fun await(label: String, predicate: () -> Boolean) {
        val until = System.nanoTime() + TimeUnit.SECONDS.toNanos(4)
        while (!predicate() && System.nanoTime() < until) Thread.sleep(5)
        assertTrue(label, predicate())
    }
    private fun read(cache: ReadingPageCache, at: Int): String {
        cache.select(at + 1, page(at))
        return cache.resolve(at + 1, page(at)).also { assertTrue(File(java.net.URI(it)).isFile) }
    }

    @Test fun sixOriginalPagesSurviveDoubleSpreadAndOutsideFilesAreReleased() {
        val loads = AtomicInteger()
        val cache = ReadingPageCache({ _, _ -> loads.incrementAndGet(); output() }, {}, { it.delete() }, settleMillis = 1)
        try {
            cache.window((0..5).map(::page), emptyList())
            for (at in 0..5) cache.release(read(cache, at))
            assertEquals(6, cache.files().size)
            for (at in 0..5) cache.release(read(cache, at))
            assertEquals("Back/forward use original files without rerendering", 6, loads.get())
            val previous = cache.files()
            cache.window((2..7).map(::page), emptyList())
            assertEquals(4, cache.files().size)
            assertEquals(2, previous.count { !it.exists() })
            cache.window(listOf(page(3), page(4), page(2)), emptyList())
            assertEquals("Single-page mode contracts to three originals", 3, cache.files().size)
        } finally { cache.close() }
        assertTrue(cache.files().isEmpty())
    }

    @Test fun evictionAndCloseWaitForTheForegroundCopyLease() {
        val cache = ReadingPageCache({ _, _ -> output() }, {}, { it.delete() })
        cache.window(listOf(page(0)), emptyList())
        val path = read(cache, 0); val file = File(java.net.URI(path))
        cache.window(emptyList(), emptyList()); cache.close()
        assertTrue(file.exists())
        assertTrue(cache.release(path)); assertFalse(file.exists()); assertFalse(cache.release(path))
    }

    @Test fun nextTwoFilesLoadSeriallyAndPromotionReusesAnInflightPage() {
        val entered = CountDownLatch(1); val finish = CountDownLatch(1)
        val loads = AtomicInteger(); val simultaneous = AtomicInteger()
        val cache = ReadingPageCache({ uri, _ ->
            assertEquals(1, simultaneous.incrementAndGet())
            loads.incrementAndGet()
            try { if (uri == page(2)) { entered.countDown(); assertTrue(finish.await(3, TimeUnit.SECONDS)) }; output() }
            finally { simultaneous.decrementAndGet() }
        }, {}, { it.delete() }, settleMillis = 1)
        val reader = Executors.newSingleThreadExecutor()
        try {
            cache.window((0..5).map(::page), listOf(page(2), page(3)))
            assertTrue(entered.await(3, TimeUnit.SECONDS))
            cache.select(3, page(2))
            val result = reader.submit<String> { cache.resolve(3, page(2)) }
            finish.countDown()
            val path = result.get(3, TimeUnit.SECONDS)
            assertEquals("In-flight target is reused", 1, loads.get())
            cache.release(path)
            cache.window((0..5).map(::page), listOf(page(3)))
            await("second page prepared") { cache.files().size == 2 }
            cache.release(read(cache, 3)); assertEquals(2, loads.get())
        } finally { finish.countDown(); cache.close(); reader.shutdownNow() }
    }

    @Test fun rapidJumpCancelsOldPrefetchAndDiscardsLateUninterruptibleRender() {
        val entered = CountDownLatch(1); val cancelled = CountDownLatch(1); val resume = CountDownLatch(1)
        var obsolete: File? = null
        val cache = ReadingPageCache({ uri, cancel ->
            if (uri == page(1)) {
                cancel.attachAction { cancelled.countDown() }; entered.countDown()
                assertTrue(resume.await(3, TimeUnit.SECONDS))
                output().also { obsolete = it }
            } else output()
        }, {}, { it.delete() }, settleMillis = 1)
        val reader = Executors.newSingleThreadExecutor()
        try {
            cache.window(listOf(page(0), page(1)), listOf(page(1)))
            assertTrue(entered.await(3, TimeUnit.SECONDS))
            cache.window(listOf(page(8), page(9)), emptyList()); cache.select(9, page(8))
            assertTrue(cancelled.await(1, TimeUnit.SECONDS))
            val next = reader.submit<String> { cache.resolve(9, page(8)) }
            resume.countDown(); cache.release(next.get(3, TimeUnit.SECONDS))
            assertNotNull(obsolete); assertFalse(obsolete!!.exists()); assertEquals(1, cache.files().size)
        } finally { resume.countDown(); cache.close(); reader.shutdownNow() }
    }

    @Test fun byteBudgetRejectsLargeFilesButForegroundStillWorks() {
        val loads = AtomicInteger()
        val cache = ReadingPageCache({ uri, _ -> loads.incrementAndGet(); output(if (uri == page(3)) 33 else 8) }, {}, { it.delete() }, budget = 16, pageLimit = 32, settleMillis = 1)
        try {
            cache.window((0..3).map(::page), emptyList())
            for (at in 0..2) cache.release(read(cache, at))
            assertEquals(2, cache.files().size)
            val huge = read(cache, 3); val file = File(java.net.URI(huge))
            assertTrue(file.exists()); cache.release(huge); assertFalse(file.exists())
            cache.window(listOf(page(3)), listOf(page(3)))
            await("oversized speculative file attempted once") { loads.get() == 5 }
            cache.window(listOf(page(3)), listOf(page(3)))
            cache.select(1, page(0)); cache.release(cache.resolve(1, page(0))) // worker barrier
            assertEquals(6, loads.get())
        } finally { cache.close() }
    }

    @Test fun cacheHitRevalidatesSessionAndFailuresDoNotPoisonForegroundRetry() {
        val valid = AtomicBoolean(true); val loads = AtomicInteger()
        val cache = ReadingPageCache({ _, _ -> loads.incrementAndGet(); output() }, { check(valid.get()) }, { it.delete() }, settleMillis = 1)
        try {
            cache.window(listOf(page(0)), emptyList()); cache.release(read(cache, 0))
            valid.set(false)
            assertThrows(Exception::class.java) { read(cache, 0) }
            assertEquals(1, loads.get())
            valid.set(true); cache.release(read(cache, 0)); assertEquals(1, loads.get())
        } finally { cache.close() }
    }

    @Test fun pauseDropsFilesAndResumeRestartsTheSameWindow() {
        val cache = ReadingPageCache({ _, _ -> output() }, {}, { it.delete() }, settleMillis = 1)
        try {
            cache.window(listOf(page(1)), listOf(page(1)))
            await("initial prefetch") { cache.files().size == 1 }
            cache.foreground(false); assertTrue(cache.files().isEmpty())
            cache.foreground(true)
            await("resume without a changed Godot signature") { cache.files().size == 1 }
        } finally { cache.close() }
    }

    @Test fun pauseDoesNotTurnAnInFlightForegroundPageIntoALoadingError() {
        val entered = CountDownLatch(1); val resume = CountDownLatch(1)
        val cache = ReadingPageCache({ _, cancel ->
            entered.countDown(); assertTrue(resume.await(3, TimeUnit.SECONDS))
            assertFalse(cancel.cancelled); output()
        }, {}, { it.delete() })
        val reader = Executors.newSingleThreadExecutor()
        try {
            cache.window(listOf(page(0)), emptyList()); cache.select(1, page(0))
            val result = reader.submit<String> { cache.resolve(1, page(0)) }
            assertTrue(entered.await(3, TimeUnit.SECONDS)); cache.foreground(false); resume.countDown()
            val path = result.get(3, TimeUnit.SECONDS)
            assertTrue(File(java.net.URI(path)).exists())
            cache.release(path); assertTrue(cache.files().isEmpty())
        } finally { resume.countDown(); cache.close(); reader.shutdownNow() }
    }
}
