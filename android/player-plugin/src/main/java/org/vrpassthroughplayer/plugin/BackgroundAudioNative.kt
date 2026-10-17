package org.vrpassthroughplayer.plugin

import android.content.Context
import org.json.JSONObject
import java.io.File

internal object BackgroundAudioNative {
    private val available = try { System.loadLibrary("quest_mpv"); true } catch (_: UnsatisfiedLinkError) { false }
    fun supported() = available
    @JvmStatic external fun open(context: Context, path: String, probe: Boolean): Long
    @JvmStatic external fun status(handle: Long): String
    @JvmStatic external fun control(handle: Long, playing: Boolean, volume: Double, seek: Double): Boolean
    @JvmStatic external fun close(handle: Long)
    fun validate(context: Context, file: File, cancelled: () -> Boolean): Boolean {
        if (!available) return false
        val handle = open(context, file.path, true)
        if (handle == 0L) return false
        try {
            val deadline = System.nanoTime() + 10_000_000_000L
            while (!cancelled() && System.nanoTime() < deadline) {
                val state = JSONObject(status(handle))
                if (state.optString("state") == "ready") return state.optDouble("duration", 0.0) > 0
                if (state.optString("state") in setOf("failed", "ended")) return false
                Thread.sleep(20)
            }
            return false
        } finally { close(handle) }
    }
}
