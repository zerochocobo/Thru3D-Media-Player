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

/** Copies one user-picked scene file (local, SMB or cloud) into app storage; the import pipeline needs random access. */
internal class SceneFileImport(
    private val context: () -> Context?, private val resolve: (String) -> String,
    private val release: (String) -> Unit, private val emit: (Int, String) -> Unit,
) : Closeable {
    private val ids = AtomicInteger()
    private val worker = Executors.newSingleThreadExecutor { Thread(it, "Thru3DSceneImport") }
    @Volatile private var active = 0
    @Volatile private var closed = false
    @Volatile private var connection: HttpURLConnection? = null
    @Volatile private var bytes = 0L
    @Volatile private var length = -1L

    @Synchronized fun start(uri: String, title: String): Int {
        if (closed || active != 0) return -1
        val extension = title.substringAfterLast('.', "").lowercase()
        if (extension !in extensions) return -1
        val id = ids.incrementAndGet(); active = id; bytes = 0; length = -1
        worker.execute {
            var resolved = ""
            var http: HttpURLConnection? = null
            var partial: File? = null
            val result = try {
                val app = context() ?: error("Scene import unavailable")
                resolved = resolve(uri)
                check(active == id && !closed) { CANCELLED }
                val location = Uri.parse(resolved)
                val input: InputStream = when (location.scheme) {
                    "file" -> File(location.path ?: error("Scene import unavailable")).also { length = it.length() }.inputStream()
                    "content" -> {
                        app.contentResolver.openAssetFileDescriptor(location, "r")?.use { length = it.length }
                        app.contentResolver.openInputStream(location) ?: error("Scene import unavailable")
                    }
                    "http", "https" -> {
                        http = (URL(resolved).openConnection() as HttpURLConnection).apply {
                            connection = this; connectTimeout = 15000; readTimeout = 30000
                            check(responseCode == 200) { "Could not download scene" }
                            length = contentLengthLong
                        }
                        http!!.inputStream
                    }
                    else -> error("Scene import unavailable")
                }
                val directory = File(app.filesDir, "scene_import/sources").apply { mkdirs() }
                input.use { stream ->
                    check(length <= MAX_BYTES) { TOO_LARGE }
                    check(directory.usableSpace > maxOf(length, 0L) + RESERVE_BYTES) { NO_SPACE }
                    val target = File(directory, "${System.nanoTime()}.$extension.part").also { partial = it }
                    target.outputStream().use { output ->
                        val buffer = ByteArray(256 * 1024)
                        while (true) {
                            check(active == id && !closed) { CANCELLED }
                            val count = stream.read(buffer)
                            if (count < 0) break
                            output.write(buffer, 0, count)
                            bytes += count
                            check(bytes <= MAX_BYTES) { TOO_LARGE }
                        }
                    }
                    check(bytes > 0 && (length < 0 || bytes == length)) { "Incomplete scene download" }
                    val saved = File(directory, target.name.removeSuffix(".part"))
                    check(target.renameTo(saved)) { "Could not save scene" }
                    partial = null
                    JSONObject().put("state", "ready").put("path", saved.path).put("title", title.take(160)).put("bytes", bytes)
                }
            } catch (error: Exception) {
                val cancelled = closed || active != id || error.message == CANCELLED
                val allowed = setOf(TOO_LARGE, NO_SPACE, "Incomplete scene download", "Could not save scene")
                JSONObject().put("state", "error").put("cancelled", cancelled)
                    .put("error", error.message?.takeIf { it in allowed } ?: "Could not download scene")
            } finally {
                partial?.delete()
                http?.disconnect(); if (connection === http) connection = null
                if (resolved.isNotEmpty()) release(resolved)
            }
            synchronized(this) {
                if (!closed && active == id) { active = 0; emit(id, result.toString()) }
                else if (result.optString("state") == "ready") File(result.getString("path")).delete()
            }
        }
        return id
    }

    @Synchronized fun cancel(id: Int) { if (active == id) { active = 0; connection?.disconnect() } }
    fun progress(id: Int): Double = if (active == id && length > 0) (bytes.toDouble() / length).coerceIn(0.0, 1.0) else if (active == id) -1.0 else 0.0
    override fun close() { closed = true; connection?.disconnect(); worker.shutdownNow() }

    companion object {
        /** glTF binary, and the names Unity scene bundles travel under. */
        val extensions = setOf("glb", "unity3d", "assetbundle", "bundle", "vrcw", "omission")
        const val MAX_BYTES = 768L * 1024 * 1024
        private const val RESERVE_BYTES = 512L * 1024 * 1024
        private const val CANCELLED = "SCENE_CANCELLED"
        private const val TOO_LARGE = "Scene file is larger than 768 MB"
        private const val NO_SPACE = "Not enough space to save scene"
    }
}
