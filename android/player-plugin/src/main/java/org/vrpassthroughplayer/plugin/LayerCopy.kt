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
                         private val maxOutputWidth: Int = 0, private val compact: Boolean = false,
                         /** Picture quality mode: 10 bits a channel with the source's HDR colour space, the
                          * player's sharpening around where the head looks and its colour grade ([picture]).
                          * Debug: [deep] alone, a fixed [sharpen] 0..1, [windowDegrees] as the window's half angle
                          * (0 sizes it by [budgetMs] of GPU time a frame) and [tint] to mark the window. */
                         private val quality: Boolean = false, deep: Boolean = false, private val sharpen: Float = 0f,
                         private val windowDegrees: Float = 0f, private val budgetMs: Double = DEFAULT_BUDGET_MS,
                         private val tint: Boolean = false) : LayerFrames {
    private val thread = HandlerThread("LayerCopy").apply { start() }
    private val handler = Handler(thread.looper)
    private val reader = ImageReader.newInstance(width, height, ImageFormat.PRIVATE,
        if (!holdable) IMAGES else if (compact) COMPACT_IMAGES else heldLimit + 2,
        HardwareBuffer.USAGE_GPU_SAMPLED_IMAGE)
    private var display: EGLDisplay = EGL14.EGL_NO_DISPLAY // copy thread
    private var context: EGLContext = EGL14.EGL_NO_CONTEXT
    private var config: EGLConfig? = null
    private var window: EGLSurface = EGL14.EGL_NO_SURFACE
    private var windowSize = 0 to 0
    private var windowDataSpace = 0 // copy thread: the HDR colour space set on the window (0: none)
    @Volatile private var gpuMs = 0.0
    @Volatile private var sourceDataSpace = 0
    @Volatile private var halfDegrees = if (windowDegrees > 0f) windowDegrees else START_DEGREES
    private var sinceResize = 0 // copy thread: draws since the window last changed size
    private val area = FloatArray(8) // copy thread
    private val grade = FloatArray(11) // copy thread
    @Volatile private var deep = deep || quality // false again where the display offers no 10-bit surface
    @Volatile private var strength = 0f // the sharpening drawn last
    private var working = false // copy thread: the last draw denoised, enlarged or sharpened inside the window
    // Picture quality mode keeps the frame on show (copy thread) and draws it again when the settings or the
    // head's direction change with no new frame coming: a paused picture follows the menu and the head.
    // With Alpha's held frames it takes the reader's one spare image.
    private var shown: Held? = null
    private var shownLook: FloatArray? = null
    private var shownFocus: FloatArray? = null
    private val redraw = Runnable { redrawShown() }
    @Volatile private var scaledDown = false
    @Volatile private var enlarged = false
    private class Held(val image: Image?, val sequence: Long, val arrivedMs: Long,
                       val slot: Int = -1, val outWidth: Int = 0, val outHeight: Int = 0) // slot: a packed copy
    private val freeSlots = ArrayDeque<Int>() // copy thread: packed copies made and free
    private var packedSlots = 0 // copy thread: packed copies made (each stays allocated)
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
    @Volatile private var blendDelayMs = 0L // the part of delayMs that waits for the following mask

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
            if (compact && hold) { holdPacked(image, sequence); return@setOnImageAvailableListener }
            if (keepFrames) runCatching { image.hardwareBuffer }.getOrNull()?.let { buffer ->
                val crop = image.cropRect
                val frame = LayerFrame(buffer, crop.width().takeIf { it > 0 } ?: image.width, crop.height().takeIf { it > 0 } ?: image.height,
                    image.width, image.height, sequence, image.timestamp)
                synchronized(this) { latest?.release(); latest = frame }
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

    /** Draws the frame on show again if what it was drawn with has changed, and looks again later. */
    private fun redrawShown() {
        val frame = shown ?: return
        if (closed) return
        val now = focus
        val before = shownFocus
        // Half a degree: less is the head's tremor, and the window's edge is a soft one.
        val moved = now != null && (before == null || before.size != now.size || now.indices.any { it >= 4 && now[it] != before[it] } ||
            Math.abs(now[0] - before[0]) > now[2] * 0.5f || Math.abs(now[1] - before[1]) > now[3] * 0.5f)
        if (picture !== shownLook || (moved && working) || (now != null && before == null)) draw(frame)
        else handler.postDelayed(redraw, IDLE_MS)
    }

    /** The visible size of [image] and the window size it is drawn at. */
    private fun sizes(image: Image): IntArray {
        val crop = image.cropRect
        val w = crop.width().takeIf { it > 0 } ?: image.width
        val h = crop.height().takeIf { it > 0 } ?: image.height
        // The compositor surface may be narrower than the video (memory): the copy scales it down.
        var outW = if (maxOutputWidth in 1 until w) maxOutputWidth else w
        var outH = if (outW == w) h else (h.toLong() * outW / w).toInt() and 1.inv()
        // Super resolution: picture quality mode enlarges a low-resolution source; the draw then runs EASU
        // before RCAS. Never past the output cap, which is there for this headset's memory.
        if (outW == w) enlargedSize(w, h)?.takeIf { maxOutputWidth <= 0 || it.first <= maxOutputWidth }?.let { outW = it.first; outH = it.second }
        scaledDown = outW < w; enlarged = outW > w
        return intArrayOf(w, h, outW, outH)
    }

    /** The size super resolution shows a [w] x [h] frame at, or null to leave it (mpv_video_display.gd's
     * upscale_size holds the same rule for the menu). Each eye's picture grows to fit the box for its kind:
     * a flat picture 4K (its long side 3840, as many pixels as 3840 x 2160), a VR180 eye 2880 x 2880, a
     * VR360 eye 5760 x 2880; and the whole frame stays within the pixels of an 8K VR frame, which lets a
     * 3840 x 3840 top-bottom 360 picture (a common older format) reach 5760 x 5760. */
    private fun enlargedSize(w: Int, h: Int): Pair<Int, Int>? {
        val look = picture ?: return null
        if (!quality || look.size < 17 || look[13] < 0.5f) return null
        val moderate = look[13] < 1.5f // twice the size at most, where EASU is at its best
        val eyeW = w.toDouble() / (if (look[15] > 1.5f) 2 else 1)
        val eyeH = h.toDouble() / (if (look[16] > 1.5f) 2 else 1)
        var scale = when (look[14].toInt()) {
            0 -> minOf(FLAT_LONG / maxOf(eyeW, eyeH), Math.sqrt(FLAT_PIXELS / (eyeW * eyeH)))
            1 -> minOf(VR180_EYE / eyeW, VR180_EYE / eyeH)
            else -> minOf(VR360_EYE_WIDTH / eyeW, VR360_EYE_HEIGHT / eyeH)
        }
        scale = minOf(scale, Math.sqrt(FRAME_PIXELS / (w.toDouble() * h)))
        if (moderate) scale = minOf(scale, 2.0)
        if (scale < MIN_ENLARGEMENT) return null
        return (Math.round(w * scale).toInt() and 1.inv()) to (Math.round(h * scale).toInt() and 1.inv())
    }

    /** Memory saver: packs [image] into a free slot, returns its buffer to the decoder (the newest
     * stays open for RVM until taken) and holds the copy for its delay. */
    private fun holdPacked(image: Image, sequence: Long) {
        var keep = false
        try {
            if (closed || context == EGL14.EGL_NO_CONTEXT) return
            val (w, h, outW, outH) = sizes(image)
            lastSize = "${w}x$h of ${image.width}x${image.height} to ${outW}x$outH packed"
            if (!ensureWindow(outW, outH)) return
            if (freeSlots.isEmpty() && packedSlots < packedLimit()) freeSlots.addFirst(packedSlots++)
            if (freeSlots.isEmpty() && held.isNotEmpty()) { early.incrementAndGet(); draw(held.removeFirst()) }
            val slot = freeSlots.pollFirst() ?: return
            val buffer = image.hardwareBuffer
            val packed = try {
                buffer != null && VideoLayerNative.packBuffer(buffer, w, h, image.width, image.height, outW, outH, flip, slot)
            } finally { buffer?.close() }
            if (!packed) { failed.incrementAndGet(); freeSlots.addFirst(slot); return }
            if (keepFrames) runCatching { image.hardwareBuffer }.getOrNull()?.let { frameBuffer ->
                val frame = LayerFrame(frameBuffer, w, h, image.width, image.height, sequence, image.timestamp, image)
                synchronized(this) { latest?.release(); latest = frame }
                keep = true
            }
            val frame = Held(null, sequence, SystemClock.uptimeMillis(), slot, outW, outH)
            held.addLast(frame)
            handler.postAtTime({ drawDue() }, this, frame.arrivedMs + delayMs)
        } catch (failure: Throwable) {
            failed.incrementAndGet(); lastError = failure.toString().take(160)
        } finally {
            if (!keep) image.close()
        }
    }

    /** Copies that can wait at once: the current delay plus jitter at the Alpha rate, and one being made.
     * At startup the decoder bursts ahead of real time; without this cap every slot got allocated then. */
    private fun packedLimit(): Int {
        val fps = maxFps.takeIf { it > 0 } ?: return heldLimit + 1
        return (Math.ceil((delayMs + PACKED_JITTER_MS) * fps / 1000.0).toInt() + 1).coerceIn(2, heldLimit + 1)
    }

    private fun drawPacked(frame: Held) {
        try {
            if (closed || context == EGL14.EGL_NO_CONTEXT || !ensureWindow(frame.outWidth, frame.outHeight)) return
            val started = SystemClock.elapsedRealtimeNanos()
            if (!VideoLayerNative.drawPacked(frame.slot)) { failed.incrementAndGet(); return }
            if (EGL14.eglSwapBuffers(display, window)) { drawn.incrementAndGet(); presented = frame.sequence }
            else { failed.incrementAndGet(); lastError = "swap 0x" + Integer.toHexString(EGL14.eglGetError()) }
            val ms = (SystemClock.elapsedRealtimeNanos() - started) / 1e6
            drawMs = if (drawMs == 0.0) ms else drawMs * 0.95 + ms * 0.05
        } catch (failure: Throwable) {
            failed.incrementAndGet(); lastError = failure.toString().take(160)
        } finally {
            freeSlots.addFirst(frame.slot) // reused first: only as many copies as wait at once are allocated
        }
    }

    private fun draw(frame: Held) {
        val image = frame.image ?: return drawPacked(frame)
        try {
            if (closed || context == EGL14.EGL_NO_CONTEXT) return
            val (w, h, outW, outH) = sizes(image)
            lastSize = "${w}x$h of ${image.width}x${image.height} to ${outW}x$outH"
            if (!ensureWindow(outW, outH)) return
            if (deep || quality) tagDataSpace(image)
            val buffer = image.hardwareBuffer ?: return
            val started = SystemClock.elapsedRealtimeNanos()
            try {
                if (android.os.Build.VERSION.SDK_INT >= 31) bufferIds.add(buffer.id)
                val look = picture
                shownLook = look; shownFocus = focus
                // Without a direction yet the whole 8K frame would be worked on: a negative strength waits for one.
                val amount = if (sharpen > 0f) sharpen else if (!quality) 0f else if (focus == null) -1f else look?.get(0) ?: 0f
                val denoising = quality && look != null && look.size >= 19 && look[18] > 0f
                strength = maxOf(amount, 0f)
                working = amount >= 0f && (amount > 0f || denoising || outW > w)
                val graded = if (quality && look != null && look.size >= 13 && look[1] > 0.5f) grade.also { look.copyInto(it, 0, 2, 13) } else null
                if (!VideoLayerNative.blitBuffer(buffer, w, h, image.width, image.height, outW, outH, flip, quality || amount > 0f,
                        amount, if (working) window() else null, graded, if (denoising) look!![17] else 0f, if (denoising) look!![18] else 0f)) {
                    failed.incrementAndGet(); return
                }
                gpuMs = VideoLayerNative.blitGpuMs()
                resizeWindow()
            } finally { buffer.close() }
            if (EGL14.eglSwapBuffers(display, window)) { drawn.incrementAndGet(); presented = frame.sequence }
            else { failed.incrementAndGet(); lastError = "swap 0x" + Integer.toHexString(EGL14.eglGetError()) }
            val ms = (SystemClock.elapsedRealtimeNanos() - started) / 1e6
            drawMs = if (drawMs == 0.0) ms else drawMs * 0.95 + ms * 0.05
        } catch (failure: Throwable) {
            failed.incrementAndGet(); lastError = failure.toString().take(160)
        } finally {
            // The buffer goes back to the decoder: at once, or when the next frame has taken its place.
            if (quality && !closed) {
                if (shown !== frame) { shown?.image?.close(); shown = frame }
                handler.removeCallbacks(redraw); handler.postDelayed(redraw, IDLE_MS)
            } else {
                if (shown !== frame) shown?.image?.close()
                shown = null
                image.close()
            }
        }
    }

    /** The sharpening window around the head's direction, or null for the whole frame (no direction
     * reported yet, or a window wide enough to cover a 180 degree picture). */
    private fun window(): FloatArray? {
        val focus = focus ?: return null
        if (halfDegrees >= FULL_DEGREES) return null
        area[0] = focus[0]; area[1] = focus[1]
        area[2] = focus[2] * halfDegrees; area[3] = focus[3] * halfDegrees
        val layout = focus[4].toInt()
        area[4] = if (layout == 1) 2f else 1f; area[5] = if (layout == 2) 2f else 1f
        area[6] = focus[5]; area[7] = if (tint) 1f else 0f
        return area
    }

    /** Sized by cost: the copy's GPU time is smoothed over about a second, so one step each half second. */
    private fun resizeWindow() {
        if (!working || windowDegrees > 0f || gpuMs <= 0.0 || ++sinceResize < RESIZE_DRAWS) return
        sinceResize = 0
        halfDegrees = when {
            gpuMs > budgetMs -> halfDegrees * 0.9f
            gpuMs < budgetMs * 0.9 -> halfDegrees * 1.06f
            else -> halfDegrees
        }.coerceIn(MIN_DEGREES, FULL_DEGREES)
    }

    /** HDR10 and HLG frames keep their primaries and transfer on the window (full range RGB), so the
     * compositor converts the copy as it converts the decoder's own surface. SDR stays untagged. */
    private fun tagDataSpace(image: Image) {
        if (android.os.Build.VERSION.SDK_INT < 33) return
        val source = image.dataSpace
        val transfer = source and TRANSFER_MASK
        val wanted = if (transfer == TRANSFER_ST2084 || transfer == TRANSFER_HLG) (source and STANDARD_MASK) or transfer or RANGE_FULL else 0
        sourceDataSpace = source
        if (wanted == windowDataSpace) return
        if (wanted != 0 && !VideoLayerNative.setWindowDataSpace(target, wanted)) lastError = "setBuffersDataSpace"
        windowDataSpace = wanted
    }

    private fun setUp() {
        display = EGL14.eglGetDisplay(EGL14.EGL_DEFAULT_DISPLAY)
        val version = IntArray(2)
        if (!EGL14.eglInitialize(display, version, 0, version, 1)) { lastError = "eglInitialize"; return }
        val configs = arrayOfNulls<EGLConfig>(1); val count = IntArray(1)
        fun choose(bits: Int, alpha: Int) = EGL14.eglChooseConfig(display, intArrayOf(EGL14.EGL_RED_SIZE, bits, EGL14.EGL_GREEN_SIZE, bits,
            EGL14.EGL_BLUE_SIZE, bits, EGL14.EGL_ALPHA_SIZE, alpha, EGL14.EGL_RENDERABLE_TYPE, EGLExt.EGL_OPENGL_ES3_BIT_KHR,
            EGL14.EGL_SURFACE_TYPE, EGL14.EGL_WINDOW_BIT, EGL14.EGL_NONE), 0, configs, 0, 1, count, 0) && count[0] > 0
        if (deep && !choose(10, 2)) deep = false
        if (!deep && !choose(8, 8)) { lastError = "eglChooseConfig"; return }
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
        if (!VideoLayerNative.setWindowGeometry(target, w, h, deep)) { lastError = "setBuffersGeometry"; return false }
        windowDataSpace = 0
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
    override fun maskLatency(ms: Double, blendMs: Double) {
        if (!ms.isFinite()) return
        // The wait for the following mask only while the reader holds that many frames (not the memory
        // saver's packed copies): frames drawn early would show without either mask.
        val fps = maxFps.takeIf { it > 0 } ?: UNCAPPED_FPS
        val blend = blendMs.takeIf { it.isFinite() && it > 0 && !compact && ms + MARGIN_MS + it <= MAX_DELAY_MS &&
            (ms + MARGIN_MS + it) * fps / 1000.0 <= heldLimit - 1 } ?: 0.0
        blendDelayMs = blend.toLong()
        delayMs = (ms + MARGIN_MS + blend).toLong().coerceIn(MIN_DELAY_MS, MAX_DELAY_MS)
    }

    override fun stats(): JSONObject = JSONObject().put("arrived", arrived.get()).put("drawn", drawn.get()).put("failed", failed.get())
        .put("early", early.get()).put("held_limit", heldLimit).put("compact", compact).put("packed_slots", packedSlots).put("skipped", skipped.get()).put("max_fps", maxFps).put("hold", hold).put("delay_ms", delayMs).put("blend_delay_ms", blendDelayMs).put("presented", presented)
        .put("distinct_buffers", bufferIds.size).put("draw_ms", drawMs).put("size", lastSize).put("error", lastError)
        .put("gpu_ms", gpuMs).put("scaled_down", scaledDown).put("enlarged", enlarged).put("quality", quality).put("deep", deep).put("sharpen", strength.toDouble()).put("budget_ms", budgetMs)
        .put("window_degrees", halfDegrees.toDouble()).put("focus", focus?.let { "%.3f,%.3f".format(it[0], it[1]) } ?: "")
        .put("data_space", windowDataSpace).put("source_data_space", sourceDataSpace)

    /** Waits (up to a second) for the copy thread to let go of the compositor surface, which its owner
     * destroys next. */
    override fun close() {
        closed = true
        reader.setOnImageAvailableListener(null, null)
        val done = CountDownLatch(1)
        handler.post {
            handler.removeCallbacksAndMessages(this)
            while (held.isNotEmpty()) runCatching { held.removeFirst().image?.close() }
            handler.removeCallbacks(redraw)
            runCatching { shown?.image?.close() }; shown = null
            synchronized(this) { latest?.release(); latest = null }
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
        // Memory saver: the frame being packed, the newest kept for RVM and the one RVM is reading.
        private const val COMPACT_IMAGES = 4
        // Quest 3, RVM 320 at 30 FPS: delay 113 ms, 3-4 copies waiting; 40 ms covers the mask jitter.
        private const val PACKED_JITTER_MS = 40.0
        private const val HELD_LIMIT = 8 // frames held for their masks at once (about 130 ms at 60 fps)
        private const val DEFAULT_DELAY_MS = 120L
        private const val MIN_DELAY_MS = 40L
        private const val MAX_DELAY_MS = 250L
        private const val MARGIN_MS = 20.0
        private const val UNCAPPED_FPS = 60 // frames a second to budget for when no Alpha rate is set
        // Quest 3, 10-bit 8K60 at 120 Hz: windows of 45 to 60 degrees (4.4 to 5.2 ms a frame) held 115 to 117 FPS.
        // A 3.5 ms budget shrank the window under 20 degrees, sharpening little more than the centre.
        const val DEFAULT_BUDGET_MS = 5.0
        private const val START_DEGREES = 40f
        private const val MIN_DEGREES = 30f
        private const val FULL_DEGREES = 100f
        private const val RESIZE_DRAWS = 30
        private const val IDLE_MS = 50L // without a frame for this long, the one on show is looked at again
        /** Where the head looks in one eye's picture (Godot, every frame): u, v, UV per degree across and
         * down, layout (0 one picture, 1 side by side, 2 top and bottom), 1 when longitude wraps. */
        @Volatile var focus: FloatArray? = null
        /** The player's picture settings (Godot, when they change): sharpening 0..1, 1 when graded, then the
         * grade's gain, gamma and offset per channel, contrast and saturation; then super resolution:
         * its level (0 off, 1 moderate, 2 maximum), the picture's kind (0 flat, 1 VR180, 2 VR360) and its
         * eyes across and down; then the denoising's step in source pixels and its tolerance (0: off). */
        @Volatile var picture: FloatArray? = null
        private const val FLAT_LONG = 3840.0
        private const val FLAT_PIXELS = 3840.0 * 2160.0
        private const val VR180_EYE = 2880.0
        private const val VR360_EYE_WIDTH = 5760.0
        private const val VR360_EYE_HEIGHT = 2880.0
        private const val FRAME_PIXELS = 8192.0 * 4096.0
        private const val MIN_ENLARGEMENT = 1.15 // less than this is not worth a second pass
        // android.hardware.DataSpace bit fields.
        private const val STANDARD_MASK = 63 shl 16
        private const val TRANSFER_MASK = 31 shl 22
        private const val TRANSFER_ST2084 = 7 shl 22
        private const val TRANSFER_HLG = 8 shl 22
        private const val RANGE_FULL = 1 shl 27
    }
}
