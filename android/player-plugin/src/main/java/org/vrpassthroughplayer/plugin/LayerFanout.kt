package org.vrpassthroughplayer.plugin

import android.graphics.ImageFormat
import android.hardware.HardwareBuffer
import android.media.Image
import android.media.ImageReader
import android.media.ImageWriter
import android.os.Handler
import android.os.HandlerThread
import android.os.SystemClock
import android.view.Surface
import org.json.JSONObject
import java.util.ArrayDeque
import java.util.concurrent.atomic.AtomicLong

/**
 * Alpha plan B: the decoder writes into an ImageReader instead of the compositor layer's surface, and
 * every frame is handed on to that surface without a copy (ImageWriter attaches the reader's buffer).
 * In between, the frame's HardwareBuffer is the RVM input, so the video stays on the decoder surface
 * layer while Alpha still sees each frame.
 *
 * [hold] (Alpha): frames wait until the mask of their own or a later frame is on the mask layer
 * ([releaseThrough]), so a frame and its mask reach the compositor together; MPV delays the audio by
 * the measured wait. Frames held past a limit (no mask coming: paused model, seek) go on regardless.
 */
internal class LayerFanout(target: Surface, width: Int, height: Int, private val holdable: Boolean = false) : LayerFrames {
    private val thread = HandlerThread("LayerFanout").apply { start() }
    // Debug experiment (debug.vrpp.layer.fanout_images "reader,writer"): how many buffers each side may hold.
    private val counts = debugCounts() ?: (if (holdable) HELD_IMAGES else MAX_IMAGES).let { it to it }
    private val reader = ImageReader.newInstance(width, height, ImageFormat.PRIVATE, counts.first,
        HardwareBuffer.USAGE_GPU_SAMPLED_IMAGE)
    private val writer = ImageWriter.newInstance(target, counts.second, ImageFormat.PRIVATE)
    private val arrived = AtomicLong()
    private val queued = AtomicLong()
    private val failed = AtomicLong()
    private val buffers = AtomicLong()
    private val forced = AtomicLong()
    private val released = AtomicLong()
    /** Distinct decoder buffers seen (HardwareBuffer ids): a bounded set means they are reused. */
    private val bufferIds = java.util.Collections.synchronizedSet(HashSet<Long>())
    @Volatile private var lastSize = ""
    @Volatile private var lastError = ""
    @Volatile private var closed = false
    private class Held(val image: Image, val sequence: Long, val arrivedMs: Long)
    private var latest: LayerFrame? = null // guarded by this
    private val held = ArrayDeque<Held>() // guarded by this, oldest first
    @Volatile override var keepFrames = false
    /** Hold frames for their masks (an Alpha session); turning it off sends every held frame on at once. */
    @Volatile override var hold = false
        set(value) {
            val enabled = value && holdable
            if (field == enabled) return
            field = enabled
            if (!enabled) releaseStale(-1)
        }
    /** Average wait from arrival to release of held frames (ms), the audio delay MPV should apply. */
    @Volatile override var holdMs = 0.0
        private set
    override val presentsLater = false
    override val presented get() = Long.MAX_VALUE

    /** The decoder's output surface. */
    override val surface: Surface get() = reader.surface

    init {
        reader.setOnImageAvailableListener({ source ->
            val image = runCatching { source.acquireNextImage() }.getOrNull() ?: return@setOnImageAvailableListener
            val sequence = arrived.incrementAndGet()
            lastSize = "${image.width}x${image.height}"
            if (closed) { image.close(); return@setOnImageAvailableListener }
            // The buffer the RVM input pass samples (an EGLImage in the render bridge). The decoder cycles
            // its buffers, so this one is rewritten several frames later, after the GL thread took it.
            runCatching { image.hardwareBuffer }.getOrNull()?.let { buffer ->
                buffers.incrementAndGet()
                if (android.os.Build.VERSION.SDK_INT >= 31) bufferIds.add(buffer.id)
                if (!keepFrames) { buffer.close(); return@let }
                val crop = image.cropRect
                val frame = LayerFrame(buffer, crop.width().takeIf { it > 0 } ?: image.width, crop.height().takeIf { it > 0 } ?: image.height,
                    image.width, image.height, sequence, image.timestamp)
                synchronized(this) { latest?.release(); latest = frame }
            }
            if (!hold) { queue(image); return@setOnImageAvailableListener }
            val overflow = synchronized(this) {
                held.addLast(Held(image, sequence, SystemClock.uptimeMillis()))
                // Keep buffers for the decoder: past the limit the oldest goes on without its mask.
                if (held.size > HELD_LIMIT) held.removeFirst() else null
            }
            overflow?.let { forced.incrementAndGet(); release(it) }
        }, Handler(thread.looper))
        writer.setOnImageReleasedListener({ released.incrementAndGet() }, Handler(thread.looper))
    }

    /** The newest frame not taken yet; the caller closes its buffer. */
    override fun take(): LayerFrame? = synchronized(this) { latest.also { latest = null } }

    /** Every held frame up to [sequence]: their mask (or a later one) is on the mask layer now. */
    override fun releaseThrough(sequence: Long) {
        val ready = synchronized(this) {
            val out = ArrayList<Held>()
            while (held.isNotEmpty() && held.peekFirst()!!.sequence <= sequence) out.add(held.removeFirst())
            out
        }
        ready.forEach { release(it) }
    }

    /** Frames held longer than [limitMs] go on without a mask of their own (no result coming). */
    override fun releaseStale(limitMs: Long) {
        val now = SystemClock.uptimeMillis()
        val stale = synchronized(this) {
            val out = ArrayList<Held>()
            while (held.isNotEmpty() && now - held.peekFirst()!!.arrivedMs > limitMs) out.add(held.removeFirst())
            out
        }
        if (stale.isNotEmpty()) forced.addAndGet(stale.size.toLong())
        stale.forEach { release(it) }
    }

    private fun release(frame: Held) {
        val waited = (SystemClock.uptimeMillis() - frame.arrivedMs).toDouble()
        holdMs = if (holdMs == 0.0) waited else holdMs * 0.9 + waited * 0.1
        queue(frame.image)
    }

    private fun queue(image: Image) {
        try {
            // The reader thread (overflow) and the GL thread (masks) both release frames.
            synchronized(writer) { writer.queueInputImage(image) } // closes the image; the buffer moves on
            queued.incrementAndGet()
        } catch (failure: Throwable) {
            failed.incrementAndGet(); lastError = failure.toString().take(160)
            runCatching { image.close() }
        }
    }

    override fun stats(): JSONObject = JSONObject().put("arrived", arrived.get()).put("queued", queued.get())
        .put("failed", failed.get()).put("hardware_buffers", buffers.get()).put("size", lastSize).put("error", lastError)
        .put("hold", hold).put("held", synchronized(this) { held.size }).put("forced", forced.get()).put("hold_ms", holdMs)
        .put("released", released.get()).put("distinct_buffers", bufferIds.size)
        .put("reader_images", counts.first).put("writer_images", counts.second)

    override fun close() {
        closed = true
        synchronized(this) {
            latest?.release(); latest = null
            held.forEach { runCatching { it.image.close() } }; held.clear()
        }
        reader.setOnImageAvailableListener(null, null)
        runCatching { writer.close() }
        runCatching { reader.close() }
        thread.quitSafely()
    }

    companion object {
        private fun debugCounts(): Pair<Int, Int>? = if (!BuildConfig.DEBUG) null else runCatching {
            val value = Class.forName("android.os.SystemProperties").getMethod("get", String::class.java)
                .invoke(null, "debug.vrpp.layer.fanout_images") as String
            val parts = value.split(",").map { it.trim().toInt() }
            if (parts.size == 2 && parts.all { it in 1..16 }) parts[0] to parts[1] else null
        }.getOrNull()
        private const val MAX_IMAGES = 5
        private const val HELD_IMAGES = 10
        private const val HELD_LIMIT = 6 // held at once; the rest are the decoder's and the compositor's
    }
}
