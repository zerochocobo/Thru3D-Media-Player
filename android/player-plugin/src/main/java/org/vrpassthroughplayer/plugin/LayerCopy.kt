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
 *
 * Frame interpolation (picture quality mode, a film of 30 frames a second or fewer): each frame waits
 * for the one after it, and every display refresh draws the picture for its own moment between the two
 * (native/xr-layer/frame_interp.cpp). A frame shows [holdMs] after it arrived; MPV delays the audio as long.
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
        // Interpolation holds the pair on show and the frame after it.
        if (!holdable) (if (quality) IMAGES + 2 else IMAGES) else if (compact) COMPACT_IMAGES else heldLimit + 2,
        HardwareBuffer.USAGE_GPU_SAMPLED_IMAGE)
    private var display: EGLDisplay = EGL14.EGL_NO_DISPLAY // copy thread
    private var context: EGLContext = EGL14.EGL_NO_CONTEXT
    private var config: EGLConfig? = null
    private var window: EGLSurface = EGL14.EGL_NO_SURFACE
    private var windowSize = 0 to 0
    private var windowDataSpace = 0 // copy thread: the HDR colour space set on the window (0: none)
    @Volatile private var gpuMs = 0.0
    private val interpolationGpuMs = DoubleArray(2) // one pair's estimate, one picture in between
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
    // Anime4K (the plugins tab): the settings the last frame was drawn with (null: none), whether its
    // frames were HDR (the networks take SDR pictures only), and, once its draws stayed over
    // ANIME4K_BUDGET_MS, that this file shows without it from then on.
    @Volatile private var anime4kDrawn: FloatArray? = null
    @Volatile private var anime4kHdr = false
    @Volatile private var anime4kOverloaded = false
    // Its networks were still being linked at the last draw, which went without them: the frame on show
    // is drawn again once they are ready, also when paused.
    @Volatile private var anime4kWaiting = false
    private var anime4kSlow = 0 // copy thread: draws over the budget in a row
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
    // Frame interpolation (copy thread). A frame's place in time is its media timestamp; [offsetNs] carries
    // that to the clock the display's refreshes are on, following the frames' arrivals slowly, so the
    // picture's moment at each refresh does not inherit the jitter of single arrivals.
    private class Timed(val image: Image, val sequence: Long, val pts: Long, val arrivedNs: Long)
    private val waiting = ArrayList<Timed>() // oldest first: the pair on show, then what arrived since
    private var lastPts = Long.MIN_VALUE
    private var offsetNs = 0.0
    @Volatile private var interpolationDelayNs = 0L
    private var shownSequence = -1L // what the surface shows while frames wait here
    private var shownPhase = 0f
    private var ticking = false
    private var unsupported = false // the GPU or its driver refused the interpolation's passes
    // The GPU does not finish the pictures in time (a slower headset, a hot one): for this file the
    // frames show as they come again, which is smoother than interpolation missing its refreshes.
    @Volatile private var overloaded = false
    private var retried = 0L // the last of [retries] seen: a new one lifts the stop above
    private var paced = 0 // refreshes drawn for since the last look at how many ran late
    // How long before its latch a refresh's picture was handed to the compositor (smoothed), and how often
    // it was handed after it: where the latches are a guess (PICO) these say how good the guess is.
    @Volatile private var latchMarginMs = 0.0
    private val afterLatch = AtomicLong()
    private var pacedLate = 0
    private val tick = Runnable { tick() }
    private val between = AtomicLong() // pictures drawn between two frames
    private val late = AtomicLong() // refreshes missed: the draw before ran past its start
    private var lastKeptNs = Long.MIN_VALUE // copy thread
    private val bufferIds = java.util.Collections.synchronizedSet(HashSet<Long>())
    @Volatile private var drawMs = 0.0
    @Volatile private var lastSize = ""
    @Volatile private var outputSize = 0 to 0 // what the last frame was drawn at, for the info page
    @Volatile private var lastError = ""
    @Volatile private var closed = false
    @Volatile private var teardownComplete = false
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
    override val holdMs: Double get() = if (hold) delayMs.toDouble() else interpolationDelayNs / 1e6
    /** MPV's playback speed: media time passes this much faster than the clock. */
    @Volatile var speed = 1.0
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
            if (!hold && interpolate(image, sequence)) return@setOnImageAvailableListener
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

    /** The settings or the head's direction are no longer what the picture on show was drawn with. */
    private fun lookChanged(): Boolean {
        val now = focus
        val before = shownFocus
        // Half a degree: less is the head's tremor, and the window's edge is a soft one.
        val moved = now != null && (before == null || before.size != now.size || now.indices.any { it >= 4 && now[it] != before[it] } ||
            Math.abs(now[0] - before[0]) > now[2] * 0.5f || Math.abs(now[1] - before[1]) > now[3] * 0.5f)
        return picture !== shownLook || (moved && working) || (now != null && before == null) || anime4kWaiting
    }

    /** Draws the frame on show again if what it was drawn with has changed, and looks again later. */
    private fun redrawShown() {
        val frame = shown ?: return
        if (closed) return
        if (lookChanged()) draw(frame)
        else handler.postDelayed(redraw, IDLE_MS)
    }

    /** Takes [image] for interpolation: true when it waits here for its refreshes, false to draw it at once
     * (the mode is off or cannot run, or the frame does not follow the one before at a film's pace: the
     * first after a seek, a faster source). The frame on show then becomes the first of the pair. */
    private fun interpolate(image: Image, sequence: Long): Boolean {
        val now = System.nanoTime()
        val pts = image.timestamp
        val rate = speed.takeIf { it > 0.0 } ?: 1.0
        val step = if (lastPts == Long.MIN_VALUE) 0L else ((pts - lastPts) / rate).toLong()
        lastPts = pts
        val look = picture
        val pace = cadence
        val retry = retries.get()
        if (retry != retried) { retried = retry; overloaded = false; unsupported = false; paced = 0; pacedLate = 0 }
        val crop = image.cropRect
        val w = crop.width().takeIf { it > 0 } ?: image.width
        val h = crop.height().takeIf { it > 0 } ?: image.height
        if (!quality || unsupported || overloaded || look == null || look.size < 20 || look[19] < 0.5f || pace == null || now - pace[3] > CADENCE_STALE_NS ||
            step !in MIN_STEP_NS..MAX_STEP_NS || w.toLong() * h > MAX_INTERPOLATED_PIXELS) { stopInterpolation(); return false }
        if (waiting.isEmpty()) {
            val previous = shown?.takeIf { it.sequence == sequence - 1 }
            val first = previous?.image ?: return false
            handler.removeCallbacks(redraw); shown = null
            val arrived = previous.arrivedMs * 1_000_000L
            waiting.add(Timed(first, previous.sequence, first.timestamp, arrived))
            // The frame on show stays for the delay, then the picture moves on from it.
            offsetNs = arrived - first.timestamp / rate
            interpolationDelayNs = step + pace[1] * 3 / 2
            shownSequence = previous.sequence; shownPhase = 0f
        }
        val observed = now - pts / rate
        // A pause or a stall moves every arrival after it: start from there rather than catch up.
        offsetNs = if (Math.abs(observed - offsetNs) > OFFSET_RESET_NS) observed else offsetNs + (observed - offsetNs) * OFFSET_FOLLOW
        val before = waiting.last()
        waiting.add(Timed(image, sequence, pts, now))
        // The pair's motion now, so its first refresh finds it done.
        runCatching {
            val a = before.image.hardwareBuffer; val b = image.hardwareBuffer
            try {
                if (a != null && b != null && context != EGL14.EGL_NO_CONTEXT && window != EGL14.EGL_NO_SURFACE &&
                    !VideoLayerNative.interpEstimate(a, b, before.sequence, sequence, w, h, image.width, image.height)) unsupported = true
            } finally { a?.close(); b?.close() }
        }
        if (!ticking) { ticking = true; handler.post(tick) }
        return true
    }

    private fun stopInterpolation() {
        interpolationDelayNs = 0L
        if (waiting.isEmpty()) return
        handler.removeCallbacks(tick); ticking = false
        for (frame in waiting) runCatching { frame.image.close() }
        waiting.clear()
    }

    /** One display refresh: draws the picture for the moment that refresh shows, then waits for the next
     * (or, with the last frame on show and none coming, looks again later as [redrawShown] does). */
    private fun tick() {
        ticking = false
        if (closed || waiting.isEmpty()) return
        val now = System.nanoTime()
        val pace = cadence
        if (pace == null || now - pace[3] > CADENCE_STALE_NS || unsupported || overloaded) {
            // Nothing to pace by: the newest frame as it is, and the next frames draw at once.
            val newest = waiting.removeAt(waiting.size - 1)
            stopInterpolation()
            draw(Held(newest.image, newest.sequence, SystemClock.uptimeMillis()))
            return
        }
        val period = pace[1]
        val latch = latchAfter(now, pace[0], period, pace[2])
        val rate = speed.takeIf { it > 0.0 } ?: 1.0
        val moment = ((latch - interpolationDelayNs - offsetNs) * rate).toLong()
        while (waiting.size >= 2 && moment >= waiting[1].pts) runCatching { waiting.removeAt(0).image.close() }
        val first = waiting[0]
        val second = waiting.getOrNull(1)
        val phase = if (second == null) 0f else phaseBetween(moment, first.pts, second.pts)
        try {
            if (phase > 0f && phase < 1f && second != null) {
                render(first.image, first.sequence, second.image, second.sequence, phase)
                between.incrementAndGet()
                shownSequence = first.sequence; shownPhase = phase
            } else {
                val frame = if (phase >= 1f && second != null) second else first
                if (shownSequence != frame.sequence || shownPhase != 0f || lookChanged()) render(frame.image, frame.sequence)
                shownSequence = frame.sequence; shownPhase = 0f
            }
        } catch (failure: Throwable) {
            failed.incrementAndGet(); lastError = failure.toString().take(160)
        }
        if (closed) return
        val margin = (latch - System.nanoTime()) / 1e6
        latchMarginMs = if (latchMarginMs == 0.0) margin else latchMarginMs * 0.95 + margin * 0.05
        if (margin < 0) afterLatch.incrementAndGet()
        ticking = true
        if (waiting.size < 2 && moment >= first.pts) { handler.postDelayed(tick, IDLE_MS); return }
        // The next draw starts soon after this latch, with most of a period ahead of its own.
        val start = latch + period * 3 / 20
        val wait = start - System.nanoTime()
        if (wait < -period / 2) { late.incrementAndGet(); pacedLate++ }
        if (++paced >= OVERLOAD_REFRESHES) {
            if (pacedLate * OVERLOAD_SHARE > paced) overloaded = true
            paced = 0; pacedLate = 0
        }
        handler.postDelayed(tick, maxOf(0L, (wait + 500_000L) / 1_000_000L))
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
        // before RCAS. Never past the output cap, which is there for this headset's memory. Anime4K takes
        // its place, at the size its doublings make.
        val networks = anime4k(image, w, h)
        if (networks != null) { outW = w shl networks[2].toInt(); outH = h shl networks[2].toInt() }
        else if (outW == w && quality) picture?.let { enlargedSize(w, h, it, maxOutputWidth) }?.let { outW = it.first; outH = it.second }
        scaledDown = outW < w; enlarged = outW > w
        outputSize = outW to outH
        return intArrayOf(w, h, outW, outH)
    }

    /** Anime4K's mode, tier and doublings for [image] (w x h visible) under the picture settings, or null
     * where it does not run: off, HDR, the output capped smaller, or this file overloaded the GPU. */
    private fun anime4k(image: Image, w: Int, h: Int): FloatArray? {
        val look = picture
        if (!quality || look == null || look.size < 22 || look[20] < 0.5f) return null
        val hdr = android.os.Build.VERSION.SDK_INT >= 33 && (image.dataSpace and TRANSFER_MASK).let { it == TRANSFER_ST2084 || it == TRANSFER_HLG }
        anime4kHdr = hdr
        if (hdr || anime4kOverloaded || VideoLayerNative.anime4kRefused()) return null
        if (maxOutputWidth in 1 until w) return null
        val doublings = anime4kDoublings(w, h, maxOutputWidth)
        if (look[20] > 2.5f && doublings == 0) return null // mode C enlarges or does nothing
        return floatArrayOf(look[20], look[21], doublings.toFloat())
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

    /** Draws [image] over the compositor surface and shows it; with [after], the picture [phase] of the way
     * from [image] to [after] instead (the two frames' sequences name them to the native side). */
    private fun render(image: Image, sequence: Long, after: Image? = null, afterSequence: Long = 0L, phase: Float = 0f) {
        if (closed || context == EGL14.EGL_NO_CONTEXT) return
        val (w, h, outW, outH) = sizes(image)
        lastSize = "${w}x$h of ${image.width}x${image.height} to ${outW}x$outH"
        if (!ensureWindow(outW, outH)) return
        if (deep || quality) tagDataSpace(image)
        val buffer = image.hardwareBuffer ?: return
        val second = after?.hardwareBuffer
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
            val area = if (working) window() else null
            val step = if (denoising) look!![17] else 0f
            val tolerance = if (denoising) look!![18] else 0f
            var done = second != null && VideoLayerNative.interpBlit(buffer, second, sequence, afterSequence, phase, w, h, image.width, image.height,
                outW, outH, flip, true, amount, area, graded, step, tolerance)
            // Where the picture in between cannot be drawn, the nearer frame.
            if (second != null && !done) unsupported = true
            // Anime4K on single frames (the menu keeps it and interpolation apart); its result is kept by
            // the frame's sequence, so a redraw of the frame on show does not run the networks again.
            val networks = if (second == null) anime4k(image, w, h) else null
            if (!done) done = VideoLayerNative.blitBuffer(if (second != null && phase >= 0.5f) second else buffer, w, h, image.width, image.height,
                outW, outH, flip, quality || amount > 0f, amount, area, graded, step, tolerance, networks, sequence)
            if (!done) { failed.incrementAndGet(); return }
            gpuMs = VideoLayerNative.blitGpuMs()
            anime4kWaiting = networks != null && VideoLayerNative.anime4kPending()
            anime4kDrawn = networks.takeUnless { anime4kWaiting }
            watchAnime4k(anime4kDrawn != null)
            if (second != null) { interpolationGpuMs[0] = VideoLayerNative.interpGpuMs(0); interpolationGpuMs[1] = VideoLayerNative.interpGpuMs(1) }
            resizeWindow()
        } finally { buffer.close(); second?.close() }
        if (EGL14.eglSwapBuffers(display, window)) { drawn.incrementAndGet(); presented = sequence }
        else { failed.incrementAndGet(); lastError = "swap 0x" + Integer.toHexString(EGL14.eglGetError()) }
        val ms = (SystemClock.elapsedRealtimeNanos() - started) / 1e6
        drawMs = if (drawMs == 0.0) ms else drawMs * 0.95 + ms * 0.05
    }

    private fun draw(frame: Held) {
        val image = frame.image ?: return drawPacked(frame)
        try {
            render(image, frame.sequence)
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

    /** Anime4K's draws over this headset's budget (the picture settings carry it; ANIME4K_BUDGET_MS without)
     * for ANIME4K_SLOW_DRAWS frames in a row: this headset cannot keep
     * the networks up with this file (a larger tier than it affords, a hot GPU); the frames show without
     * them from then on, the window and its sharpening as before. */
    private fun watchAnime4k(running: Boolean) {
        if (!running || gpuMs <= 0.0) { anime4kSlow = 0; return }
        val budget = picture?.takeIf { it.size >= 23 && it[22] > 0f }?.get(22)?.toDouble() ?: ANIME4K_BUDGET_MS
        anime4kSlow = if (gpuMs > budget) anime4kSlow + 1 else 0
        if (anime4kSlow >= ANIME4K_SLOW_DRAWS) { anime4kOverloaded = true; anime4kSlow = 0 }
    }

    /** Sized by cost: the copy's GPU time is smoothed over about a second, so one step each half second.
     * Not while Anime4K runs: its networks' time is not the window's. */
    private fun resizeWindow() {
        if (!working || windowDegrees > 0f || gpuMs <= 0.0 || anime4kDrawn != null || ++sinceResize < RESIZE_DRAWS) return
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
        .put("output_width", outputSize.first).put("output_height", outputSize.second)
        .put("gpu_ms", gpuMs).put("scaled_down", scaledDown).put("enlarged", enlarged).put("quality", quality).put("deep", deep).put("sharpen", strength.toDouble()).put("budget_ms", budgetMs)
        .put("window_degrees", halfDegrees.toDouble()).put("focus", focus?.let { "%.3f,%.3f".format(it[0], it[1]) } ?: "")
        .put("data_space", windowDataSpace).put("source_data_space", sourceDataSpace)
        .put("interpolating", interpolationDelayNs > 0L).put("interpolation_delay_ms", interpolationDelayNs / 1e6).put("between", between.get())
        .put("late", late.get()).put("interpolation_unsupported", unsupported).put("interpolation_overloaded", overloaded)
        .put("anime4k", anime4kDrawn != null).put("anime4k_hdr", anime4kHdr).put("anime4k_overloaded", anime4kOverloaded)
        .put("anime4k_refused", VideoLayerNative.anime4kRefused())
        .put("estimate_gpu_ms", interpolationGpuMs[0]).put("between_gpu_ms", interpolationGpuMs[1])
        .put("latch_margin_ms", latchMarginMs).put("after_latch", afterLatch.get())
        .put("display_ahead_ms", cadence?.let { (it[0] - it[3]) / 1e6 } ?: 0.0).put("period_ms", cadence?.let { it[1] / 1e6 } ?: 0.0)
        .put("lead_ms", cadence?.let { it[2] / 1e6 } ?: 0.0).put("display_estimated", cadenceConverted)

    override fun pollClosed(): Boolean {
        if (closed) return teardownComplete
        closed = true
        reader.setOnImageAvailableListener(null, null)
        handler.post {
            handler.removeCallbacksAndMessages(this)
            while (held.isNotEmpty()) runCatching { held.removeFirst().image?.close() }
            stopInterpolation()
            handler.removeCallbacks(redraw); handler.removeCallbacks(tick)
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
            thread.quitSafely()
            teardownComplete = true
        }
        return false
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
        // Frame interpolation: for sources of 10 to 33 frames a second (a film, 25 and 30 fps video) up to 4K.
        // Faster sources are smooth enough and leave no time for it; 8K is past what the GPU can move.
        private const val MIN_STEP_NS = 30_000_000L
        private const val MAX_STEP_NS = 100_000_000L
        private const val MAX_INTERPOLATED_PIXELS = 4096L * 2304L
        private const val CADENCE_STALE_NS = 2_000_000_000L
        private const val OFFSET_RESET_NS = 30_000_000.0
        private const val OFFSET_FOLLOW = 0.05
        private const val PHASE_SNAP = 0.04f
        // Two seconds of refreshes at 72 Hz; a quarter of them late is past what a busy moment explains.
        private const val OVERLOAD_REFRESHES = 144
        // Anime4K's GPU time a frame (the whole copy, smoothed) past which it stops for the file, where the
        // settings name none: a 24 fps frame lasts 42 ms and the headset's own rendering needs most of it.
        private const val ANIME4K_BUDGET_MS = 20.0
        private const val ANIME4K_SLOW_DRAWS = 60
        private const val OVERLOAD_SHARE = 4
        /** The latch a draw starting at [now] is for: the compositor takes the surface's newest buffer at each
         * latch ([lead] before a display time, a [period] apart), and the first one at least half a period
         * away leaves the GPU that long. All in nanoseconds on one clock. */
        internal fun latchAfter(now: Long, display: Long, period: Long, lead: Long): Long {
            val grid = display - lead
            return grid + Math.floorDiv(now + period / 2 - grid + period - 1, period) * period
        }

        /** How far the media time [moment] lies from the frame at [first] to the frame at [second], 0..1.
         * Next to a frame it is the frame itself: sharper than a picture moved a few percent of the way. */
        internal fun phaseBetween(moment: Long, first: Long, second: Long): Float {
            if (second <= first || moment <= first) return 0f
            val phase = ((moment - first).toDouble() / (second - first)).toFloat()
            return if (phase < PHASE_SNAP) 0f else if (phase > 1f - PHASE_SNAP) 1f else phase
        }

        /** The compositor's refreshes (Godot, a few times a second): a predicted display time, the refresh
         * period and how long before a display time the compositor takes the surface's newest buffer, all
         * in nanoseconds on System.nanoTime's clock, and when they were reported. */
        @Volatile var cadence: LongArray? = null
        /** The runtime's display times were on another clock and [cadence] holds an estimate instead. */
        @Volatile var cadenceConverted = false
        /** Where the head looks in one eye's picture (Godot, every frame): u, v, UV per degree across and
         * down, layout (0 one picture, 1 side by side, 2 top and bottom), 1 when longitude wraps. */
        @Volatile var focus: FloatArray? = null
        /** The player's picture settings (Godot, when they change): sharpening 0..1, 1 when graded, then the
         * grade's gain, gamma and offset per channel, contrast and saturation; then super resolution:
         * its level (0 off, 1 moderate, 2 maximum), the picture's kind (0 flat, 1 VR180, 2 VR360) and its
         * eyes across and down; then the denoising's step in source pixels and its tolerance (0: off); then
         * 1 for frame interpolation; then Anime4K's mode (0 off, 1 A, 2 B, 3 C), tier (0 S .. 3 VL) and this
         * headset's budget for it in milliseconds. */
        @Volatile var picture: FloatArray? = null
        /** The user turned frame interpolation on again after it stopped for a file: try it again. */
        val retries = AtomicLong()
        private const val FLAT_LONG = 3840.0
        private const val FLAT_PIXELS = 3840.0 * 2160.0
        private const val VR180_EYE = 2880.0
        private const val VR360_EYE_WIDTH = 5760.0
        private const val VR360_EYE_HEIGHT = 2880.0
        private const val FRAME_PIXELS = 8192.0 * 4096.0
        private const val MIN_ENLARGEMENT = 1.15 // less than this is not worth a second pass

        /** The size super resolution shows a [w] x [h] frame at under the settings [look], or null to leave
         * it (mpv_video_display.gd's upscale_size holds the same rule for the menu). Each eye's picture grows
         * to fit the box for its kind: a flat picture 4K (its long side 3840, as many pixels as 3840 x 2160),
         * a VR180 eye 2880 x 2880, a VR360 eye 5760 x 2880; and the whole frame stays within the pixels of an
         * 8K VR frame, which lets a 3840 x 3840 top-bottom 360 picture (a common older format) reach 5760 x 5760.
         * It stops at [maxWidth] (the output cap, 0: none) rather than giving up there. */
        internal fun enlargedSize(w: Int, h: Int, look: FloatArray, maxWidth: Int): Pair<Int, Int>? {
            if (look.size < 17 || look[13] < 0.5f || w <= 0 || h <= 0) return null
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
            if (maxWidth > 0) scale = minOf(scale, maxWidth.toDouble() / w)
            if (scale < MIN_ENLARGEMENT) return null
            return (Math.round(w * scale).toInt() and 1.inv()) to (Math.round(h * scale).toInt() and 1.inv())
        }

        /** How many times Anime4K doubles a [w] x [h] frame (native/xr-layer/anime4k.h; mpv_video_display.gd's
         * anime4k_doublings is the same rule): again while the long side is at most 1920, twice at most, never
         * past [maxWidth] (the output cap, 0: none). A DVD's 720 x 480 becomes 2880 x 1920, 1080p 4K, and
         * larger frames are only restored. */
        internal fun anime4kDoublings(w: Int, h: Int, maxWidth: Int): Int {
            val longest = maxOf(w, h)
            var doublings = 0
            while (doublings < 2 && (longest shl doublings) <= ANIME4K_DOUBLE_UP_TO &&
                (maxWidth <= 0 || (w shl (doublings + 1)) <= maxWidth)) doublings++
            return doublings
        }
        private const val ANIME4K_DOUBLE_UP_TO = 1920

        // android.hardware.DataSpace bit fields.
        private const val STANDARD_MASK = 63 shl 16
        private const val TRANSFER_MASK = 31 shl 22
        private const val TRANSFER_ST2084 = 7 shl 22
        private const val TRANSFER_HLG = 8 shl 22
        private const val RANGE_FULL = 1 shl 27
    }
}
