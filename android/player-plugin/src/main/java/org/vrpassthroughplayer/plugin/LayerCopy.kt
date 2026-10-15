package org.vrpassthroughplayer.plugin

import android.graphics.ImageFormat
import android.hardware.HardwareBuffer
import android.media.Image
import android.media.ImageReader
import android.opengl.EGL14
import android.opengl.EGLConfig
import android.opengl.EGLContext
import android.opengl.EGLDisplay
import android.opengl.EGLExt
import android.opengl.EGLSurface
import android.os.Handler
import android.os.HandlerThread
import android.os.SystemClock
import android.view.Surface
import org.json.JSONObject
import java.util.ArrayDeque
import java.util.concurrent.CountDownLatch
import java.util.concurrent.TimeUnit
import java.util.concurrent.atomic.AtomicLong

/**
 * Alpha plan B, GPU copy: the decoder writes into an ImageReader whose buffers it reuses, and a copy
 * thread draws each frame into the compositor layer's surface with its own EGL context, so both buffer
 * sets stay fixed. (Handing the decoder's buffers to the compositor made it allocate a new one per frame,
 * faster than they were freed.) The cost is one full-size draw per video frame.
 *
 * [hold] (Alpha): every frame is drawn [holdMs] after it arrived, at its own pace, and stays in the reader
 * until then; the owner raises a mask only once [presented] reaches the mask's frame. The delay follows
 * the measured mask latency ([maskLatency]); MPV delays the audio as long.
 */
internal class LayerCopy(private val target: Surface, width: Int, height: Int, private val flip: Boolean = true,
                         private val holdable: Boolean = false, private val heldLimit: Int = HELD_LIMIT,
                         private val maxOutputWidth: Int = 0) : LayerFrames {
    private val thread = HandlerThread("LayerCopy").apply { start() }
    private val handler = Handler(thread.looper)
    private val reader = ImageReader.newInstance(width, height, ImageFormat.PRIVATE, if (holdable) heldLimit + 2 else IMAGES,
        HardwareBuffer.USAGE_GPU_SAMPLED_IMAGE)
    private var display: EGLDisplay = EGL14.EGL_NO_DISPLAY // copy thread
    private var context: EGLContext = EGL14.EGL_NO_CONTEXT
    private var config: EGLConfig? = null
    private var window: EGLSurface = EGL14.EGL_NO_SURFACE
    private var windowSize = 0 to 0
    private class Held(val image: Image, val sequence: Long, val arrivedMs: Long)
    private val held = ArrayDeque<Held>() // copy thread, oldest first
    private var latest: LayerFrame? = null // guarded by this
    private val arrived = AtomicLong()
    private val drawn = AtomicLong()
    private val failed = AtomicLong()
    private val early = AtomicLong() // drawn before their delay because too many were held
    private val skipped = AtomicLong() // above the Alpha frame rate: neither drawn nor shown to RVM
    private var lastKeptNs = Long.MIN_VALUE // copy thread
    private val bufferIds = java.util.Collections.synchronizedSet(HashSet<Long>())
    @Volatile private var drawMs = 0.0
    @Volatile private var lastSize = ""
    @Volatile private var lastError = ""
    @Volatile private var closed = false
    @Volatile private var delayMs = DEFAULT_DELAY_MS

    override val surface: Surface get() = reader.surface
    @Volatile override var keepFrames = false
    @Volatile override var hold = false
        set(value) {
            val enabled = value && holdable
            if (field == enabled) return
            field = enabled
            if (!enabled) handler.post { while (held.isNotEmpty()) draw(held.removeFirst()) }
        }
    override val holdMs: Double get() = if (hold) delayMs.toDouble() else 0.0
    override val presentsLater = true
    @Volatile override var presented = 0L
        private set
    /** Alpha: frames shown per second (the player's Alpha FPS limit); the rest go back to the decoder
     * unseen. Fewer frames between masks keeps the cut-out with the picture, and the copies saved leave
     * the GPU to RVM. 0: every frame. */
    @Volatile var maxFps = 0

    init {
        handler.post { setUp() }
        reader.setOnImageAvailableListener({ source ->
            val image = runCatching { source.acquireNextImage() }.getOrNull() ?: return@setOnImageAvailableListener
            val sequence = arrived.incrementAndGet()
            if (closed) { image.close(); return@setOnImageAvailableListener }
            val cap = maxFps
            if (hold && cap > 0) {
                // Keep a frame once a frame period (less a tenth, for timestamp jitter) has passed.
                val period = 1_000_000_000L / cap
                if (lastKeptNs != Long.MIN_VALUE && image.timestamp - lastKeptNs in 0 until period * 9 / 10) {
                    skipped.incrementAndGet(); image.close(); return@setOnImageAvailableListener
                }
                lastKeptNs = image.timestamp
            } else lastKeptNs = Long.MIN_VALUE
            if (keepFrames) runCatching { image.hardwareBuffer }.getOrNull()?.let { buffer ->
                val crop = image.cropRect
                val frame = LayerFrame(buffer, crop.width().takeIf { it > 0 } ?: image.width, crop.height().takeIf { it > 0 } ?: image.height,
                    image.width, image.height, sequence, image.timestamp)
                synchronized(this) { latest?.buffer?.close(); latest = frame }
            }
            val frame = Held(image, sequence, SystemClock.uptimeMillis())
            if (!hold) { draw(frame); return@setOnImageAvailableListener }
            held.addLast(frame)
            // The reader has room for heldLimit frames besides the decoder's: past it the oldest goes early.
            while (held.size > heldLimit) { early.incrementAndGet(); draw(held.removeFirst()) }
            handler.postAtTime({ drawDue() }, this, frame.arrivedMs + delayMs)
        }, handler)
    }

    /** Draws the held frames whose delay has passed (posted per frame; extra calls find nothing due). */
    private fun drawDue() {
        val now = SystemClock.uptimeMillis()
        while (held.isNotEmpty() && now - held.peekFirst()!!.arrivedMs >= delayMs) draw(held.removeFirst())
    }

    private fun draw(frame: Held) {
        val image = frame.image
        try {
            if (closed || context == EGL14.EGL_NO_CONTEXT) return
            val crop = image.cropRect
            val w = crop.width().takeIf { it > 0 } ?: image.width
            val h = crop.height().takeIf { it > 0 } ?: image.height
            // The compositor surface may be narrower than the video (memory): the copy scales it down.
            val outW = if (maxOutputWidth in 1 until w) maxOutputWidth else w
            val outH = if (outW == w) h else (h.toLong() * outW / w).toInt() and 1.inv()
            lastSize = "${w}x$h of ${image.width}x${image.height} to ${outW}x$outH"
            if (!ensureWindow(outW, outH)) return
            val buffer = image.hardwareBuffer ?: return
            val started = SystemClock.elapsedRealtimeNanos()
            try {
                if (android.os.Build.VERSION.SDK_INT >= 31) bufferIds.add(buffer.id)
                if (!VideoLayerNative.blitBuffer(buffer, w, h, image.width, image.height, outW, outH, flip)) { failed.incrementAndGet(); return }
            } finally { buffer.close() }
            if (EGL14.eglSwapBuffers(display, window)) { drawn.incrementAndGet(); presented = frame.sequence }
            else { failed.incrementAndGet(); lastError = "swap 0x" + Integer.toHexString(EGL14.eglGetError()) }
            val ms = (SystemClock.elapsedRealtimeNanos() - started) / 1e6
            drawMs = if (drawMs == 0.0) ms else drawMs * 0.95 + ms * 0.05
        } catch (failure: Throwable) {
            failed.incrementAndGet(); lastError = failure.toString().take(160)
        } finally {
            image.close() // the buffer goes back to the decoder
        }
    }

    private fun setUp() {
        display = EGL14.eglGetDisplay(EGL14.EGL_DEFAULT_DISPLAY)
        val version = IntArray(2)
        if (!EGL14.eglInitialize(display, version, 0, version, 1)) { lastError = "eglInitialize"; return }
        val attributes = intArrayOf(EGL14.EGL_RED_SIZE, 8, EGL14.EGL_GREEN_SIZE, 8, EGL14.EGL_BLUE_SIZE, 8, EGL14.EGL_ALPHA_SIZE, 8,
            EGL14.EGL_RENDERABLE_TYPE, EGLExt.EGL_OPENGL_ES3_BIT_KHR, EGL14.EGL_SURFACE_TYPE, EGL14.EGL_WINDOW_BIT, EGL14.EGL_NONE)
        val configs = arrayOfNulls<EGLConfig>(1); val count = IntArray(1)
        if (!EGL14.eglChooseConfig(display, attributes, 0, configs, 0, 1, count, 0) || count[0] == 0) { lastError = "eglChooseConfig"; return }
        config = configs[0]
        context = EGL14.eglCreateContext(display, config, EGL14.EGL_NO_CONTEXT,
            intArrayOf(EGL14.EGL_CONTEXT_CLIENT_VERSION, 3, EGL14.EGL_NONE), 0)
        if (context == EGL14.EGL_NO_CONTEXT) lastError = "eglCreateContext"
    }

    /** The compositor surface at the video's size; recreated if the size changes (another file). */
    private fun ensureWindow(w: Int, h: Int): Boolean {
        if (window != EGL14.EGL_NO_SURFACE && windowSize == (w to h)) return true
        if (window != EGL14.EGL_NO_SURFACE) {
            EGL14.eglMakeCurrent(display, EGL14.EGL_NO_SURFACE, EGL14.EGL_NO_SURFACE, EGL14.EGL_NO_CONTEXT)
            EGL14.eglDestroySurface(display, window); window = EGL14.EGL_NO_SURFACE
        }
        if (!VideoLayerNative.setWindowGeometry(target, w, h)) { lastError = "setBuffersGeometry"; return false }
        window = EGL14.eglCreateWindowSurface(display, config, target, intArrayOf(EGL14.EGL_NONE), 0)
        if (window == EGL14.EGL_NO_SURFACE) { lastError = "eglCreateWindowSurface 0x" + Integer.toHexString(EGL14.eglGetError()); return false }
        if (!EGL14.eglMakeCurrent(display, window, window, context)) { lastError = "eglMakeCurrent"; return false }
        EGL14.eglSwapInterval(display, 0) // the compositor takes the newest frame; never wait on its vsync here
        windowSize = w to h
        return true
    }

    override fun take(): LayerFrame? = synchronized(this) { latest.also { latest = null } }
    override fun releaseThrough(sequence: Long) {} // frames go at their own pace; masks wait for them
    override fun releaseStale(limitMs: Long) {}
    override fun maskLatency(ms: Double) {
        if (ms.isFinite()) delayMs = (ms + MARGIN_MS).toLong().coerceIn(MIN_DELAY_MS, MAX_DELAY_MS)
    }

    override fun stats(): JSONObject = JSONObject().put("arrived", arrived.get()).put("drawn", drawn.get()).put("failed", failed.get())
        .put("early", early.get()).put("held_limit", heldLimit).put("skipped", skipped.get()).put("max_fps", maxFps).put("hold", hold).put("delay_ms", delayMs).put("presented", presented)
        .put("distinct_buffers", bufferIds.size).put("draw_ms", drawMs).put("size", lastSize).put("error", lastError)

    /** Waits (up to a second) for the copy thread to let go of the compositor surface, which its owner
     * destroys next. */
    override fun close() {
        closed = true
        reader.setOnImageAvailableListener(null, null)
        val done = CountDownLatch(1)
        handler.post {
            handler.removeCallbacksAndMessages(this)
            while (held.isNotEmpty()) runCatching { held.removeFirst().image.close() }
            synchronized(this) { latest?.buffer?.close(); latest = null }
            if (context != EGL14.EGL_NO_CONTEXT) {
                if (window != EGL14.EGL_NO_SURFACE) EGL14.eglMakeCurrent(display, window, window, context)
                VideoLayerNative.releaseBlit()
                EGL14.eglMakeCurrent(display, EGL14.EGL_NO_SURFACE, EGL14.EGL_NO_SURFACE, EGL14.EGL_NO_CONTEXT)
                if (window != EGL14.EGL_NO_SURFACE) EGL14.eglDestroySurface(display, window)
                EGL14.eglDestroyContext(display, context)
            }
            window = EGL14.EGL_NO_SURFACE; context = EGL14.EGL_NO_CONTEXT
            runCatching { reader.close() }
            done.countDown()
            thread.quitSafely()
        }
        done.await(1, TimeUnit.SECONDS)
    }

    companion object {
        private const val IMAGES = 4
        private const val HELD_LIMIT = 8 // frames held for their masks at once (about 130 ms at 60 fps)
        private const val DEFAULT_DELAY_MS = 120L
        private const val MIN_DELAY_MS = 40L
        private const val MAX_DELAY_MS = 250L
        private const val MARGIN_MS = 20.0
    }
}
