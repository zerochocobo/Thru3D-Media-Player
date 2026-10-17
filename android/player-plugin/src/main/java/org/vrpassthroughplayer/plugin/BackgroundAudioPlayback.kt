package org.vrpassthroughplayer.plugin

import android.content.Context
import org.json.JSONObject
import java.io.Closeable
import java.io.File
import java.util.concurrent.Executors
import java.util.concurrent.TimeUnit

/** Independent audio-only MPV, bounded decoder buffers; Godot never waits on decoding. */
internal class BackgroundAudioPlayback(private val context: () -> Context?) : Closeable {
    private val worker = Executors.newSingleThreadScheduledExecutor { Thread(it, "Thru3DMusic") }
    private var generation = 0
    private var path = ""
    private var playing = false
    private var foreground = true
    private var volume = 0.0
    private var seek = -1.0
    private var closed = false
    private var handle = 0L // worker only
    private var loadedGeneration = -1
    private var loadDeadline = 0L
    @Volatile private var snapshot = "{}"
    init { worker.scheduleWithFixedDelay({ tick() }, 0, 40, TimeUnit.MILLISECONDS) }

    @Synchronized fun load(value: String, position: Double): Int {
        val app = context() ?: return 0
        val file = runCatching { File(value).canonicalFile }.getOrNull() ?: return 0
        if (closed || file.parentFile != File(app.filesDir, "background-audio").canonicalFile || !file.isFile || !position.isFinite()) return 0
        generation++; path = file.path; playing = false; volume = 0.0; seek = position.coerceAtLeast(0.0)
        snapshot = JSONObject().put("generation", generation).put("state", "loading").toString()
        return generation
    }
    @Synchronized fun control(id: Int, play: Boolean, gain: Double, position: Double): Boolean {
        if (closed || id != generation || !gain.isFinite() || !position.isFinite()) return false
        playing = play; volume = gain.coerceIn(0.0, 100.0)
        if (position >= 0) seek = position
        return true
    }
    @Synchronized fun stop() { generation++; path = ""; playing = false; snapshot = "{}" }
    @Synchronized fun foreground(value: Boolean) { foreground = value }
    fun status() = snapshot
    private data class Desired(val id: Int, val path: String, val play: Boolean, val volume: Double)
    private fun tick() {
        val desired = synchronized(this) { if (closed) return; Desired(generation, path, playing && foreground, volume) }
        try {
            if (loadedGeneration != desired.id) {
                if (handle != 0L) BackgroundAudioNative.close(handle)
                handle = 0; loadedGeneration = desired.id
                if (desired.path.isEmpty()) return
                check(BackgroundAudioNative.supported())
                handle = BackgroundAudioNative.open(context() ?: error("No context"), desired.path, false)
                check(handle != 0L); loadDeadline = System.nanoTime() + 15_000_000_000L
            }
            if (handle == 0L) return
            val state = JSONObject(BackgroundAudioNative.status(handle))
            if (state.optString("state") == "loading") check(System.nanoTime() < loadDeadline)
            if (state.optString("state") == "ready") {
                // Recheck ownership after native calls; late loads cannot start superseded tracks.
                synchronized(this) {
                    if (!closed && generation == desired.id) {
                        check(BackgroundAudioNative.control(handle, playing && foreground, volume, seek))
                        seek = -1.0
                    }
                }
            }
            synchronized(this) { if (!closed && generation == desired.id) snapshot = state.put("generation", desired.id).toString() }
        } catch (_: Exception) {
            if (handle != 0L) BackgroundAudioNative.close(handle)
            handle = 0
            synchronized(this) { if (generation == desired.id) snapshot = JSONObject().put("generation", desired.id).put("state", "failed").toString() }
        }
    }
    override fun close() {
        synchronized(this) { if (closed) return; closed = true; playing = false }
        worker.execute { if (handle != 0L) BackgroundAudioNative.close(handle); handle = 0 }
        worker.shutdown()
    }
}
