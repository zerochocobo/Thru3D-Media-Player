package org.vrpassthroughplayer.plugin

import org.json.JSONObject
import org.junit.Assert.*
import org.junit.Test
import java.nio.file.Files
import java.util.concurrent.AbstractExecutorService
import java.util.concurrent.RejectedExecutionException
import java.util.concurrent.TimeUnit

class FavoritesVaultTasksTest {
	@Test fun realWorkerCreatesAndReopensAnEncryptedCatalog() {
		val directory = Files.createTempDirectory("favorites-worker-").toFile()
		val tasks = FavoritesVaultTasks(FavoritesVault())
		val path = directory.resolve("favorites.vault").path
		val payload = "{\"version\":1,\"entries\":{}}"
		fun collect(id: Int): JSONObject {
			assertTrue(id > 0)
			val deadline = System.nanoTime() + TimeUnit.SECONDS.toNanos(20)
			while (System.nanoTime() < deadline) {
				val result = JSONObject(tasks.take(id))
				if (!result.optBoolean("pending")) return result
				Thread.sleep(2)
			}
			throw AssertionError("Native password task did not complete")
		}
		try {
			assertEquals(payload, collect(tasks.begin("create", path, "0123", payload)).getString("data"))
			assertEquals(payload, collect(tasks.begin("open", path, "0123", "")).getString("data"))
			assertEquals(payload, FavoritesVault().open(path, "0123"))
		} finally { tasks.close(); directory.deleteRecursively() }
	}
    private class Queue : AbstractExecutorService() {
        private val work = ArrayDeque<Runnable>()
        private var stopped = false
        override fun execute(task: Runnable) { if (stopped) throw RejectedExecutionException(); work.add(task) }
        override fun shutdown() { stopped = true }
        override fun shutdownNow(): MutableList<Runnable> { stopped = true; return work.toMutableList().also { work.clear() } }
        override fun isShutdown() = stopped
        override fun isTerminated() = stopped && work.isEmpty()
        override fun awaitTermination(timeout: Long, unit: TimeUnit) = isTerminated
        fun runAll() { while (work.isNotEmpty()) work.removeFirst().run() }
    }
    private fun fixture(run: (FavoritesVault, Queue, FavoritesVaultTasks, String) -> Unit) {
        val directory = Files.createTempDirectory("favorites-tasks-").toFile()
        val vault = FavoritesVault(); val queue = Queue(); val tasks = FavoritesVaultTasks(vault, queue)
        try { run(vault, queue, tasks, directory.resolve("favorites.vault").path) }
        finally { tasks.close(); queue.runAll(); directory.deleteRecursively() }
    }

    @Test fun dispatchAndPendingPollNeverRunDerivationOnCaller() = fixture { _, queue, tasks, path ->
        val id = tasks.begin("create", path, "0123", "PRIVATE_CONTENT")
        assertTrue(id > 0)
        assertFalse(java.io.File(path).exists())
        assertTrue(JSONObject(tasks.take(id)).getBoolean("pending"))
        assertEquals(0, tasks.begin("create", path, "1234", "replacement"))
        queue.runAll()
        assertTrue(tasks.busy()) // A result must be collected before another mutation can start.
        assertEquals("PRIVATE_CONTENT", JSONObject(tasks.take(id)).getString("data"))
        assertFalse(tasks.busy())
        assertEquals("PRIVATE_CONTENT", FavoritesVault().open(path, "0123"))
        assertFalse(java.io.File(path).readText(Charsets.ISO_8859_1).contains("PRIVATE_CONTENT"))
    }

    @Test fun wrongPinCompletesWithErrorAndAllowsRetry() = fixture { vault, queue, tasks, path ->
        vault.create(path, "0123", "contents"); vault.lock()
        val wrong = tasks.begin("open", path, "9999", "")
        queue.runAll()
        assertTrue(JSONObject(tasks.take(wrong)).has("error"))
        assertFalse(tasks.busy())
        val retry = tasks.begin("open", path, "0123", "")
        queue.runAll()
        assertEquals("contents", JSONObject(tasks.take(retry)).getString("data"))
    }

    @Test fun staleRequestCannotConsumeCurrentResult() = fixture { _, queue, tasks, path ->
        val id = tasks.begin("create", path, "0123", "contents")
        assertTrue(JSONObject(tasks.take(id + 1)).has("error"))
        queue.runAll()
        assertTrue(JSONObject(tasks.take(id)).getBoolean("ok"))
        assertTrue(JSONObject(tasks.take(id)).has("error"))
    }

    @Test fun closeDiscardsLateResultsAndLocksTheKey() = fixture { vault, queue, tasks, path ->
        val id = tasks.begin("create", path, "0123", "contents")
        tasks.close()
        assertEquals(0, tasks.begin("open", path, "0123", ""))
        queue.runAll()
        assertTrue(JSONObject(tasks.take(id)).has("error"))
        assertThrows(IllegalStateException::class.java) { vault.save(path, "replacement") }
        assertEquals("contents", FavoritesVault().open(path, "0123"))
    }

    @Test fun rejectedDispatchDoesNotLeaveBusyState() = fixture { _, queue, tasks, path ->
        queue.shutdown()
        assertEquals(0, tasks.begin("create", path, "0123", "contents"))
        assertFalse(tasks.busy())
    }
}
