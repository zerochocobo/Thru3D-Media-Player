package org.vrpassthroughplayer.plugin

import android.content.Context
import android.net.Uri
import org.json.JSONObject
import java.io.Closeable
import java.io.File
import java.io.InputStream
import java.net.HttpURLConnection
import java.net.URL
import java.util.concurrent.Executors
import java.util.concurrent.atomic.AtomicInteger
import java.util.concurrent.atomic.AtomicBoolean

/** Downloading never shares the video's exclusive cloud stream or the disposable photo cache. */
internal class BackgroundAudioImport(
    private val context: () -> Context?, private val resolve: (String) -> String,
    private val release: (String) -> Unit, private val emit: (Int, String) -> Unit,
) : Closeable {
    private val ids = AtomicInteger()
    private val worker = Executors.newSingleThreadExecutor { Thread(it, "Thru3DAudioImport") }
    private val storageWorker = Executors.newSingleThreadExecutor { Thread(it, "Thru3DMusicStorage") }
    private val storagePending = AtomicBoolean()
    @Volatile private var storageSnapshot = "{}"
    @Volatile private var storageAt = 0L
    @Volatile private var active = 0
    @Volatile private var closed = false
    @Volatile private var connection: HttpURLConnection? = null
    @Volatile private var bytes = 0L
    @Volatile private var length = -1L

    @Synchronized fun start(uri: String, title: String): Int {
        if (closed || active != 0) return -1
        val extension = title.substringAfterLast('.', "").lowercase()
        if (extension !in BackgroundAudioFiles.extensions) return -1
        val id = ids.incrementAndGet(); active = id; bytes = 0; length = -1
        worker.execute {
            var resolved = ""
            var http: HttpURLConnection? = null
            var savedFile: BackgroundAudioFiles.Saved? = null
            val result = try {
                val app = context() ?: error("Audio import unavailable")
                resolved = resolve(uri)
                check(active == id && !closed) { "AUDIO_CANCELLED" }
                val location = Uri.parse(resolved)
                val input: InputStream = when (location.scheme) {
                    "file" -> File(location.path ?: error("Audio import unavailable")).also { length = it.length() }.inputStream()
                    "content" -> {
                        app.contentResolver.openAssetFileDescriptor(location, "r")?.use { length = it.length }
                        app.contentResolver.openInputStream(location) ?: error("Audio import unavailable")
                    }
                    "http", "https" -> {
                        http = (URL(resolved).openConnection() as HttpURLConnection).apply {
                            connection = this; connectTimeout = 15000; readTimeout = 30000
                            check(responseCode == 200) { "Could not download audio" }
                            length = contentLengthLong
                        }
                        http!!.inputStream
                    }
                    else -> error("Audio import unavailable")
                }
                val saved = input.use { BackgroundAudioFiles.copy(it, File(app.filesDir, "background-audio"), extension, length,
                    cancelled = { active != id || closed }, progress = { count, _ -> bytes = count },
                    validate = { file -> BackgroundAudioNative.validate(app, file) { active != id || closed } }) }
                savedFile = saved
                JSONObject().put("state", "ready").put("id", saved.id).put("path", saved.file.path)
                    .put("label", title.take(160)).put("bytes", saved.bytes).put("created", saved.created).put("decoded", true)
            } catch (error: Exception) {
                val cancelled = closed || active != id || error.message == "AUDIO_CANCELLED"
                val allowed = setOf("Audio file is empty or larger than 512 MB", "Not enough space to save audio", "Incomplete audio download", "Unsupported or damaged audio", "Could not save audio")
                JSONObject().put("state", "error").put("cancelled", cancelled)
                    .put("error", error.message?.takeIf { it in allowed } ?: "Could not download audio")
            } finally {
                http?.disconnect(); if (connection === http) connection = null
                if (resolved.isNotEmpty()) release(resolved)
            }
            synchronized(this) {
                if (!closed && active == id) { active = 0; emit(id, result.toString()) }
                else savedFile?.takeIf { it.created }?.file?.delete()
            }
        }
        return id
    }

    @Synchronized fun cancel(id: Int) { if (active == id) { active = 0; connection?.disconnect() } }
    fun progress(id: Int): Double = if (active == id && length > 0) (bytes.toDouble() / length).coerceIn(0.0, 1.0) else if (active == id) -1.0 else 0.0
    fun remove(path: String): Boolean = runCatching { context()?.let { BackgroundAudioFiles.remove(File(it.filesDir, "background-audio"), path) } ?: false }.getOrDefault(false)
    fun storage(): String {
        if (!closed && (storageAt == 0L || System.nanoTime() - storageAt >= 1_000_000_000L) && storagePending.compareAndSet(false, true)) {
            try { storageWorker.execute {
                try {
                    context()?.let { app ->
                        val value = BackgroundAudioFiles.storage(File(app.filesDir, "background-audio"))
                        storageSnapshot = JSONObject().put("used_bytes", value.used).put("free_bytes", value.free)
                            .put("total_bytes", value.total).put("max_file_bytes", BackgroundAudioFiles.MAX_BYTES).toString()
                    }
                } catch (_: Exception) { /* Retain the last known storage snapshot. */ }
                finally { storageAt = System.nanoTime(); storagePending.set(false) }
            } } catch (_: java.util.concurrent.RejectedExecutionException) { storagePending.set(false) }
        }
        return storageSnapshot
    }
    override fun close() { closed = true; active = 0; connection?.disconnect(); worker.shutdownNow(); storageWorker.shutdownNow() }
}
