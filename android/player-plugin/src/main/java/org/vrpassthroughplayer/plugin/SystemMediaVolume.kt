package org.vrpassthroughplayer.plugin

import android.content.Context
import android.media.AudioManager
import org.json.JSONObject
import java.util.concurrent.Executors
import java.util.concurrent.TimeUnit
import java.util.concurrent.RejectedExecutionException
import java.util.concurrent.atomic.AtomicBoolean
import java.util.concurrent.atomic.AtomicLong
import java.util.concurrent.atomic.AtomicReference
import kotlin.math.roundToInt

/** Media stream only. Binder calls run on one worker; Godot reads a cached snapshot. */
internal class SystemMediaVolume private constructor(private val access: () -> Access?, private val automatic: Boolean) {
    interface Access {
        fun read(): Reading
        fun write(index: Int, mute: Boolean, showUi: Boolean)
    }
    data class Reading(val index: Int, val minimum: Int, val maximum: Int, val muted: Boolean, val fixed: Boolean) {
        fun percent(): Int = if (muted) 0 else if (maximum <= minimum) 100 else
            (((index - minimum).toDouble() / (maximum - minimum)) * 100).roundToInt().coerceIn(0, 100)
        fun index(percent: Double): Int = (minimum + (maximum - minimum) * percent / 100).roundToInt().coerceIn(minimum, maximum)
    }
    private data class Request(val serial: Long, val percent: Double, val showUi: Boolean)
    private val closed = AtomicBoolean(false)
    private val started = AtomicBoolean(false)
    private val foreground = AtomicBoolean(true)
    private val queued = AtomicBoolean(false)
    private val sequence = AtomicLong(0)
    private val pending = AtomicReference<Request?>(null)
    private val worker = Executors.newSingleThreadScheduledExecutor { task -> Thread(task, "SystemMediaVolume") }
    @Volatile private var cached = "{\"available\":false,\"writable\":false}"
    private var writeSerial = 0L
    private var writeOk = true

    constructor(context: () -> Context?) : this({ context()?.getSystemService(AudioManager::class.java)?.let { manager ->
        object : Access {
            override fun read() = Reading(manager.getStreamVolume(AudioManager.STREAM_MUSIC),
                manager.getStreamMinVolume(AudioManager.STREAM_MUSIC), manager.getStreamMaxVolume(AudioManager.STREAM_MUSIC),
                manager.isStreamMute(AudioManager.STREAM_MUSIC), manager.isVolumeFixed)
            override fun write(index: Int, mute: Boolean, showUi: Boolean) {
                val flags = if (showUi) AudioManager.FLAG_SHOW_UI else 0
                if (!mute && manager.isStreamMute(AudioManager.STREAM_MUSIC))
                    manager.adjustStreamVolume(AudioManager.STREAM_MUSIC, AudioManager.ADJUST_UNMUTE, 0)
                manager.setStreamVolume(AudioManager.STREAM_MUSIC, index, flags)
                if (mute && manager.getStreamMinVolume(AudioManager.STREAM_MUSIC) > 0)
                    manager.adjustStreamVolume(AudioManager.STREAM_MUSIC, AudioManager.ADJUST_MUTE, flags)
            }
        }
    } }, true)

    internal constructor(access: Access) : this({ access }, false)

    private fun start() {
        if (automatic && !closed.get() && started.compareAndSet(false, true)) {
            try { worker.scheduleWithFixedDelay({ if (foreground.get()) poll() }, 0, 150, TimeUnit.MILLISECONDS) }
            catch (_: RejectedExecutionException) { started.set(false) }
        }
    }
    fun status(): String { start(); return cached }
    fun set(percent: Double, showUi: Boolean): Long {
        if (closed.get() || !percent.isFinite() || percent !in 0.0..100.0) return 0
        start()
        val serial = sequence.incrementAndGet()
        pending.set(Request(serial, percent, showUi))
        if (automatic && queued.compareAndSet(false, true)) {
            try { worker.execute { queued.set(false); poll() } }
            catch (_: RejectedExecutionException) { queued.set(false); return 0 }
        }
        return serial
    }
    @Synchronized internal fun poll() {
        if (closed.get()) return
        val request = pending.getAndSet(null)
        if (request != null) writeSerial = request.serial
        try {
            val backend = access() ?: error("unavailable")
            var reading = backend.read()
            if (reading.minimum < 0 || reading.maximum < reading.minimum) error("invalid range")
            if (request != null) {
                writeOk = !reading.fixed && reading.maximum > reading.minimum
                if (writeOk) {
                    backend.write(reading.index(request.percent), request.percent == 0.0, request.showUi)
                    reading = backend.read()
                }
            }
            cached = JSONObject().put("available", true).put("writable", !reading.fixed && reading.maximum > reading.minimum)
                .put("percent", reading.percent()).put("index", reading.index).put("minimum", reading.minimum)
                .put("maximum", reading.maximum).put("muted", reading.muted || reading.percent() == 0)
                .put("write_serial", writeSerial).put("write_ok", writeOk).toString()
        } catch (_: Exception) {
            writeOk = false
            cached = JSONObject().put("available", false).put("writable", false).put("write_serial", writeSerial)
                .put("write_ok", false).put("error", "system_volume_unavailable").toString()
        }
    }
    fun foreground(active: Boolean) { foreground.set(active); if (active) start() }
    fun close() { if (closed.compareAndSet(false, true)) { pending.set(null); worker.shutdownNow() } }
}
