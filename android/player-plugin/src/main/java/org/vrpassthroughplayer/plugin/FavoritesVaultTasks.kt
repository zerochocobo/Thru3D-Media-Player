package org.vrpassthroughplayer.plugin

import org.json.JSONObject
import java.util.concurrent.ExecutorService
import java.util.concurrent.Executors
import java.util.concurrent.RejectedExecutionException

/** JNI calls only dispatch or collect; password derivation never holds up the Godot thread. */
internal class FavoritesVaultTasks(
    private val vault: FavoritesVault,
    private val executor: ExecutorService = Executors.newSingleThreadExecutor { task ->
        Thread(task, "FavoritesVault").apply { isDaemon = true }
    }
) {
    private data class Job(val id: Int, var response: String? = null)
    private var sequence = 0
    private var job: Job? = null
    private var closed = false

    @Synchronized fun busy(): Boolean = job != null

    @Synchronized fun begin(operation: String, path: String, pin: String, payload: String): Int {
        if (closed || job != null || operation !in setOf("create", "open")) return 0
        val pending = Job(++sequence)
        job = pending
        try {
            executor.execute {
                val response = try {
                    val data = if (operation == "create") vault.create(path, pin, payload) else vault.open(path, pin)
                    JSONObject().put("ok", true).put("data", data).toString()
                } catch (failure: Exception) {
                    val error = when {
                        failure.message == "Try again shortly" -> "Try again shortly"
                        operation == "create" -> "Favorites save failed"
                        else -> "Incorrect password or damaged favorites"
                    }
                    JSONObject().put("error", error).toString()
                }
                synchronized(this) {
                    if (!closed && job === pending) pending.response = response
                    else vault.lock()
                }
            }
        } catch (_: RejectedExecutionException) {
            job = null
            return 0
        }
        return pending.id
    }

    @Synchronized fun take(id: Int): String {
        val pending = job
        if (closed || pending == null || pending.id != id) return JSONObject().put("error", "Favorites unavailable").toString()
        val response = pending.response ?: return JSONObject().put("pending", true).toString()
        job = null
        return response
    }

    @Synchronized fun close() {
        if (closed) return
        closed = true
        job = null
        // Finish any atomic write, then discard the key without blocking the UI on derivation.
        try { executor.execute { vault.lock() } }
        catch (_: RejectedExecutionException) { vault.lock() }
        executor.shutdown()
    }
}
