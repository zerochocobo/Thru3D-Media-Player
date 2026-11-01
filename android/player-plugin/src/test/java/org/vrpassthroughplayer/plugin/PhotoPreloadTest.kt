package org.vrpassthroughplayer.plugin

import java.io.File
import java.nio.file.Files
import org.junit.Assert.*
import org.junit.Test

class PhotoPreloadTest {
    private fun bridge() = PhotoBridge({ null }, { it }, {}, emit = { _, _, _ -> })
    private fun source(root: File, id: Int) = File(root, "$id/source").apply {
        parentFile!!.mkdirs(); writeText("photo $id")
    }

    @Test fun preloadPromotionTransfersFileOwnershipWithoutDeletingIt() {
        val root = Files.createTempDirectory("vrpp-photo-preload").toFile()
        val foreground = bridge(); val background = bridge()
        try {
            val first = source(root, 1); val next = source(root, 2)
            assertTrue(foreground.adopt(1, first))
            assertTrue(background.adopt(2, next))
            assertTrue(foreground.activate(1))
            assertTrue(background.promoteTo(2, foreground))
            background.release(2); background.close()
            assertTrue("Background cleanup must not unlink the displayed photo", next.isFile)
            assertTrue(foreground.activate(1))
            foreground.release(2)
            assertFalse(next.parentFile!!.exists())
            assertTrue(first.isFile)
        } finally { foreground.close(); background.close(); root.deleteRecursively() }
    }

    @Test fun nativeStereoCannotEnterDepthInferenceAfterPromotion() {
        val root = Files.createTempDirectory("vrpp-native-stereo").toFile()
        val work = mutableListOf<Runnable>()
        fun queuedBridge() = PhotoBridge({ null }, { it }, {}, postDepth = { task, _ -> work.add(task) }, emit = { _, _, _ -> })
        val foreground = queuedBridge(); val background = queuedBridge()
        try {
            val next = source(root, 12)
            assertTrue(background.adopt(12, next, nativeStereo=true))
            assertFalse(background.depth(12))
            assertTrue(background.promoteTo(12, foreground))
            assertFalse(foreground.depth(12, 1f, true))
            assertTrue("Native stereo never enqueues model work", work.isEmpty())
        } finally { foreground.close(); background.close(); root.deleteRecursively() }
    }

    @Test fun cancelledAndClosedCacheEntriesCannotBeActivated() {
        val root = Files.createTempDirectory("vrpp-photo-cancel").toFile()
        val background = bridge()
        try {
            assertFalse(background.activate(99))
            val next = source(root, 3)
            assertTrue(background.adopt(3, next))
            background.cancel(3)
            assertFalse(background.activate(3)); assertFalse(next.exists())
            background.close()
            val fresh = source(root, 4)
            assertFalse(background.adopt(4, fresh))
            assertTrue("Failed adoption leaves source with its caller", fresh.exists())
        } finally { background.close(); root.deleteRecursively() }
    }

    @Test fun promotionJoinsQueuedConversionAndCancellationKeepsItsFileLeased() {
        val root = Files.createTempDirectory("vrpp-photo-depth-promotion").toFile()
        val work = mutableListOf<Runnable>()
        fun queuedBridge() = PhotoBridge({ null }, { it }, {}, postDepth = { task, _ -> work.add(task) }, emit = { _, _, _ -> })
        val foreground = queuedBridge(); val background = queuedBridge()
        try {
            val next = source(root, 8)
            assertTrue(background.adopt(8, next))
            assertTrue(background.depth(8, 1f, true))
            assertEquals(1, work.size)
            assertTrue(background.promoteTo(8, foreground))
            background.cancelDepth(); background.close()
            assertTrue(foreground.depth(8, 1f, true))
            assertEquals("Promotion must join the original task", 1, work.size)
            foreground.cancel(8)
            assertTrue("Cancelled work owns the source until it returns", next.isFile)
            assertTrue(foreground.cacheDirectories().contains(next.parentFile!!))
            work.single().run()
            work.clear()
            assertFalse(next.parentFile!!.exists())
        } finally {
            foreground.close(); background.close(); work.forEach { it.run() }; root.deleteRecursively()
        }
    }

    @Test fun strengthUpdatesJoinWorkAndClosedPromotionCannotDeleteAnActiveSource() {
        val root = Files.createTempDirectory("vrpp-photo-depth-strength").toFile()
        val work = mutableListOf<Runnable>()
        val foreground = PhotoBridge({ null }, { it }, {}, postDepth = { task, _ -> work.add(task) }, emit = { _, _, _ -> })
        val closed = bridge().apply { close() }
        try {
            val first = source(root, 9)
            assertTrue(foreground.adopt(9, first))
            assertTrue(foreground.depth(9, 1f, true))
            assertFalse(foreground.promoteTo(9, closed))
            assertTrue(foreground.depth(9, .75f, true))
            assertEquals("Changing strength must not restart depth inference", 1, work.size)
            foreground.cancel(9)
            work[0].run(); assertFalse(first.exists())
            work.clear()
        } finally { foreground.close(); closed.close(); work.forEach { it.run() }; root.deleteRecursively() }
    }

    @Test fun backgroundDepthIsRejectedWithoutQueuingOrDisturbingCurrentWork() {
        val root = Files.createTempDirectory("vrpp-photo-depth-priority").toFile()
        val work = mutableListOf<Runnable>()
        val priorities = mutableListOf<Boolean>()
        val foreground = PhotoBridge({ null }, { it }, {}, postDepth = { task, priority ->
            work.add(task); priorities.add(priority)
        }, emit = { _, _, _ -> })
        try {
            assertTrue(foreground.adopt(1, source(root, 1)))
            assertTrue(foreground.adopt(2, source(root, 2)))
            assertTrue(foreground.depth(1, 1f, true))
            assertFalse(foreground.depth(2, 1f, true, true))
            assertEquals(listOf(true), priorities)
            foreground.cancelBackgroundDepth()
            assertTrue(foreground.depth(1, .8f, true))
            assertEquals("Foreground work must still be joined", 1, work.size)
            assertFalse(foreground.depth(2, .8f, true, true))
            assertEquals("Background retry cannot allocate or queue", 1, work.size)
            assertTrue(foreground.activate(2))
            assertTrue(foreground.depth(2, .8f, true))
            assertEquals("Only activation permits a new foreground task", 2, work.size)
        } finally { foreground.close(); work.forEach { it.run() }; root.deleteRecursively() }
    }

    @Test fun discardedDepthWaitsForWorkerAndPreservesOriginalSource() {
        val root = Files.createTempDirectory("vrpp-photo-depth-discard").toFile()
        try {
            val original = source(root, 1)
            val owner = PhotoSource(original)
            val worker = owner.retain()
            val depth = File(original.parentFile, "depth.bin").apply { writeText("depth") }
            val pair = File(original.parentFile, "stereo-v2-100-2048x1536.rgba").apply { writeText("pair") }
            val matte = File(original.parentFile,"portrait/matte.r8").apply { parentFile!!.mkdirs(); writeText("matte") }
            owner.discardDepth()
            assertTrue("An active worker retains its files", depth.isFile && pair.isFile)
            worker.release()
            assertFalse(depth.exists()); assertFalse(pair.exists())
            assertFalse("Discard also releases the generated portrait cache", matte.exists())
            assertTrue(original.isFile)
            owner.release(); assertFalse(original.exists())
        } finally { root.deleteRecursively() }
    }

    @Test fun budgetOnlyGatesSpeculativeWorkAndPromotionKeepsForegroundUnrestricted() {
        val root = Files.createTempDirectory("vrpp-photo-budget").toFile()
        val work = mutableListOf<Runnable>(); val priorities = mutableListOf<Boolean>()
        var allowed = false
        fun queued(preload: Boolean) = PhotoBridge({ null }, { it }, {}, preload = preload,
            postDepth = { task, priority -> work.add(task); priorities.add(priority) },
            backgroundAllowed = { allowed }, emit = { _, _, _ -> })
        val foreground = queued(false); val background = queued(true)
        try {
            assertTrue(background.adopt(20, source(root, 20)))
            assertFalse(background.depth(20, 1f, true))
            assertTrue(work.isEmpty())
            allowed = true
            assertTrue(background.depth(20, 1f, true))
            assertEquals(listOf(false), priorities)
            allowed = false
            assertTrue(background.promoteTo(20, foreground))
            assertTrue("Promotion joins work despite exhausted background budget", foreground.depth(20, 1f, true))
            assertEquals(1, work.size)
            assertTrue(foreground.adopt(21, source(root, 21)))
            assertTrue("Direct user selection never uses the optional-work gate", foreground.depth(21, 1f, true))
            assertEquals(listOf(false, true), priorities)
        } finally { foreground.close(); background.close(); work.forEach { it.run() }; root.deleteRecursively() }
    }

    @Test fun queuedBackgroundRechecksHeadroomAndReleasesItsLeaseOnDeferral() {
        val root = Files.createTempDirectory("vrpp-photo-budget-recheck").toFile()
        val work = mutableListOf<Runnable>(); val events = mutableListOf<String>()
        var allowed = true
        val background = PhotoBridge({ null }, { it }, {}, preload = true,
            postDepth = { task, _ -> work.add(task) }, backgroundAllowed = { allowed },
            emit = { _, _, value -> events.add(value) })
        try {
            val original = source(root, 30)
            assertTrue(background.adopt(30, original)); assertTrue(background.depth(30, 1f, true))
            allowed = false
            work.removeAt(0).run()
            assertTrue(org.json.JSONObject(events.single()).getBoolean("deferred"))
            assertTrue("A deferred cache task leaves the source accessible", original.isFile)
            background.release(30)
            assertFalse("The finished worker must not leak its lease", original.exists())
        } finally { background.close(); work.forEach { it.run() }; root.deleteRecursively() }
    }

    @Test fun portraitBudgetOnlyGatesBackgroundAndCancellationRetainsWorkerSources() {
        val root = Files.createTempDirectory("vrpp-portrait-budget").toFile()
        val work = mutableListOf<Runnable>()
        var allowed = false
        val foreground = PhotoBridge({ null }, { it }, {}, backgroundAllowed = { allowed },
            postPortrait = { work.add(it) }, emit = { _, _, _ -> })
        val background = PhotoBridge({ null }, { it }, {}, preload = true, backgroundAllowed = { allowed },
            postPortrait = { work.add(it) }, emit = { _, _, _ -> })
        try {
            val first = source(root, 40); val next = source(root, 41)
            assertTrue(foreground.adopt(40,first)); assertTrue(background.adopt(41,next))
            assertTrue("Normal matting is independent of cache headroom", foreground.portrait(40,1,1f))
            assertFalse(background.portrait(41,41,1f,true))
            assertEquals(1,work.size)
            allowed = true; assertTrue(background.portrait(41,41,1f,true))
            assertEquals(2,work.size)
            background.cancelBackgroundPortrait(); background.release(41)
            assertTrue("Cancellation keeps the active source leased", next.isFile)
            foreground.cancelPortrait(1); foreground.release(40)
            work.removeAt(0).run(); work.removeAt(0).run()
            assertFalse(first.exists()); assertFalse(next.exists())
        } finally { foreground.close(); background.close(); work.forEach { it.run() }; root.deleteRecursively() }
    }

    @Test fun deferredPortraitLeavesItsOriginalAccessible() {
        val root = Files.createTempDirectory("vrpp-portrait-recheck").toFile()
        val work = mutableListOf<Runnable>(); val events = mutableListOf<String>(); var allowed = true
        val background = PhotoBridge({ null }, { it }, {}, preload = true, backgroundAllowed = { allowed },
            postPortrait = { work.add(it) }, emit = { _, _, value -> events.add(value) })
        try {
            val original = source(root,50); assertTrue(background.adopt(50,original))
            assertTrue(background.portrait(50,50,1f,true)); allowed = false
            work.removeAt(0).run()
            assertTrue(org.json.JSONObject(events.single()).getBoolean("deferred"))
            assertTrue(original.isFile); background.release(50); assertFalse(original.exists())
        } finally { background.close(); work.forEach { it.run() }; root.deleteRecursively() }
    }
}
