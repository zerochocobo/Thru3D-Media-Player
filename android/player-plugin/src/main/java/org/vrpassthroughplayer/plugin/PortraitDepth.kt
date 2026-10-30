package org.vrpassthroughplayer.plugin

import android.content.Context
import org.json.JSONObject
import java.nio.ByteBuffer
import java.nio.ByteOrder
import kotlin.math.max

/** Optional ZipDepth residual alongside RVM. One owned input/in-flight job and one immutable result;
 * neither model waits for the other. All display/GL operations stay on the bridge's GL thread. */
internal class PortraitDepth(private val context: () -> Context?, private val redraw: () -> Unit) : AutoCloseable {
    private val lock = Any()
    private val worker = DepthWorker.handler
    private var closed = false
    private var epoch = 0L
    private var shot = -1L
    private var requested = false
    private var starting = false
    private var busy = false
    private var handle = 0L
    private var latest: PortraitDepthGeometry.Map? = null
    private var lastStart = 0L
    private var lastInputPts = -1L
    private var blockedUntil = 0L
    private var overloads = 0
    private var slowReads = 0
    private var updates = 0L
    private var rejected = 0L
    private var error = ""
    private var reason = "disabled"
    private var processMs = 0.0
    private var readMs = 0.0
    private var ageUs = -1L
    private var residualPixels = 0
    private var residualPeak = 0
    private var inputReadMs = 0.0
    private var inferenceMs = 0.0
    private var residualMs = 0.0
    private data class Input(val epoch: Long, val frame: Long, val pts: Long, val shot: Long,
                             val crop: PortraitDepthGeometry.Crop, val mask: PortraitDepthGeometry.Mask, val rgb: ByteBuffer)
    private var pendingInput: Input? = null
    private val dims = DepthNative.PROFILE.split('x').map { it.toInt() }

    fun configure(enabled: Boolean) = synchronized(lock) {
        if (requested != enabled) {
            requested = enabled; epoch++; latest = null; lastInputPts = -1
            reason = if (enabled) "preparing" else "disabled"
        }
    }
    fun stats(): Map<String, Any> = synchronized(lock) { mapOf(
        "requested" to requested, "active" to (reason == "enhanced"), "reason" to reason,
        "ready" to (handle > 0), "busy" to busy, "updates" to updates, "rejected" to rejected,
        "process_ms" to processMs, "readback_ms" to readMs, "age_us" to ageUs,
        "interval_ms" to max(333.34,processMs/0.30), "error" to error, "shot_id" to shot,
        "residual_pixels" to residualPixels, "residual_peak" to residualPeak,
        "input_pending" to (pendingInput != null), "input_read_ms" to inputReadMs,
        "inference_ms" to inferenceMs, "residual_ms" to residualMs) }

    /** Called on every bridge tick, including while paused. No GL wait blocks the XR thread. */
    fun pollInput(renderer: Long) {
        val input = synchronized(lock) {
            val next = pendingInput ?: return
            if (closed || next.epoch != epoch) { pendingInput = null; busy = false; rejected++; return }
            next
        }
        try {
            val started = System.nanoTime()
            if (!RenderBridgeNative.readPortraitInput(renderer,input.rgb)) return
            synchronized(lock) {
                inputReadMs = (System.nanoTime()-started)/1e6
                pendingInput = null
            }
            worker.post { infer(input.epoch,input.frame,input.pts,input.shot,input.crop,input.mask,input.rgb) }
        } catch (failure: Throwable) {
            synchronized(lock) { pendingInput = null; busy = false }
            failed(failure)
        }
    }

    private fun start() {
        synchronized(lock) { if (closed || starting || handle > 0 || error.isNotEmpty()) return; starting = true }
        worker.post {
            var created = 0L
            try {
                if (synchronized(lock) { closed || !requested }) return@post
                val host = context() ?: error("Depth activity unavailable")
                created = ModelPreparationGate.run {
                    DepthNative.videoModelFile(host)?.let { DepthNative.createFromFile(it.path, DepthWarmup.cacheDirectory(host).absolutePath) }
                        ?: DepthNative.create(host.assets, DepthWarmup.cacheDirectory(host).absolutePath)
                }
                check(created > 0) { "Portrait depth prepare failed" }
                val info = JSONObject(DepthNative.describe(created))
                check(info.getInt("width") == dims[0] && info.getInt("height") == dims[1]) { "Portrait depth input dimensions differ" }
                synchronized(lock) { if (!closed) { handle = created; created = 0 } }
                redraw()
            } catch (failure: Throwable) { failed(failure) }
            finally { if (created > 0) DepthNative.close(created); synchronized(lock) { starting = false } }
        }
    }
    private fun failed(failure: Throwable) = synchronized(lock) {
        error = failure.message ?: failure.javaClass.simpleName; reason = "model_error"; latest = null; epoch++
        android.util.Log.w("QuestPortraitDepth", "Using base relief: $error")
        // Serialized after any in-flight invocation; failed optional depth must not retain model
        // memory for the rest of the movie or make RVM playback fail.
        worker.post { val id = synchronized(lock) { handle.also { handle = 0 } }; if (id > 0) DepthNative.close(id) }
        redraw()
    }
    private fun accountPreparation(started: Long, now: Long): Boolean = synchronized(lock) {
        val elapsed = (System.nanoTime()-started)/1e6
        readMs = if (readMs == 0.0) elapsed else readMs*.9+elapsed*.1
        slowReads = if (elapsed > 8) slowReads+1 else 0
        if (slowReads < 3) false else {
            blockedUntil = now+5_000_000_000L; epoch++; latest = null; reason = "readback_budget"; true
        }
    }

    /** Low-end GPUs keep the base tier even when the persisted request came from another device. */
    fun frame(renderer: Long, token: Long, pair: JSONObject, allowed: Boolean, alphaFps: Int): ByteBuffer? {
        val frame = pair.getLong("frame_id"); val pts = pair.getLong("pts_us"); val currentShot = pair.optLong("portrait_shot_id", -1)
        val now = System.nanoTime()
        synchronized(lock) {
            if (currentShot != shot) { shot = currentShot; epoch++; latest = null; lastInputPts = -1 }
            ageUs = -1
            residualPixels = 0; residualPeak = 0
            if (closed || !requested || !allowed || currentShot < 0 || error.isNotEmpty()) {
                reason = when { !requested -> "disabled"; !allowed -> "device_base_only"; currentShot < 0 -> "shot_unavailable"; else -> "model_error" }
                latest = null; return null
            }
            val slow = pair.optDouble("rvm_process_ms", 0.0) > 40.0 || alphaFps < 20
            overloads = if (slow) overloads+1 else 0
            if (overloads >= 3) { blockedUntil = now+3_000_000_000L; latest = null; epoch++ }
            if (now < blockedUntil) { reason = "budget_base_only"; return null }
        }
        start()
        synchronized(lock) { if (handle == 0L) { reason = "preparing"; return null } }
        try {
            val started = System.nanoTime()
            val maskBytes = ByteBuffer.allocateDirect(PortraitDepthGeometry.GRID * PortraitDepthGeometry.GRID)
            RenderBridgeNative.readPortraitMask(renderer, token, maskBytes)
            val r = pair.getJSONArray("model_content_rect")
            val rect = FloatArray(4) { r.getDouble(it).toFloat() }
            val observation = PortraitMask.observe(maskBytes, 64, 64, rect)
            if (observation.subjects != 1 || observation.cropped || observation.bounds.size != 4) {
                synchronized(lock) { latest = null; epoch++; reason = "subject_unreliable" }
                accountPreparation(started,now)
                return null
            }
            val mask = PortraitDepthGeometry.Mask(maskBytes,rect,observation.bounds.map { it.toFloat() }.toFloatArray())
            val map = synchronized(lock) { latest }
            val residual = map?.let { PortraitDepthGeometry.align(it,mask,frame,pts,currentShot) }
            var pixels = 0; var peak = 0
            if (residual != null) for (i in 0 until residual.capacity()) {
                val value = kotlin.math.abs((residual.get(i).toInt() and 255)-128)
                if (value > 2) pixels++
                peak = max(peak,value)
            }
            synchronized(lock) {
                reason = if (residual != null) "enhanced" else "waiting_depth"
                ageUs = if (map != null) pts-map.pts else -1
                residualPixels = pixels; residualPeak = peak
            }
            val jobEpoch = synchronized(lock) {
                if (!busy && pts != lastInputPts && now-lastStart >= (max(333.34, processMs/0.30)*1e6).toLong()) {
                    busy = true; lastStart = now; lastInputPts = pts; epoch
                } else -1L
            }
            if (jobEpoch >= 0) {
                try {
                    val crop = PortraitDepthGeometry.crop(mask.bounds,pair.getInt("width"),pair.getInt("height"),dims[0],dims[1])
                    val rgb = ByteBuffer.allocateDirect(dims[0]*dims[1]*3*4).order(ByteOrder.LITTLE_ENDIAN)
                    RenderBridgeNative.stagePortraitInput(renderer,token,crop.rect,dims[0],dims[1])
                    synchronized(lock) { pendingInput = Input(jobEpoch,frame,pts,currentShot,crop,mask,rgb) }
                } catch (failure: Throwable) { synchronized(lock) { busy = false }; throw failure }
            }
            if (accountPreparation(started,now)) return null
            return residual
        } catch (failure: Throwable) { failed(failure); return null }
    }

    private fun infer(jobEpoch: Long, frame: Long, pts: Long, shotId: Long, crop: PortraitDepthGeometry.Crop,
                      mask: PortraitDepthGeometry.Mask, rgb: ByteBuffer) {
        try {
            val model = synchronized(lock) { if (closed || !requested || jobEpoch != epoch) 0L else handle }
            if (model == 0L) return
            val near = ByteBuffer.allocateDirect(dims[0]*dims[1]*4).order(ByteOrder.LITTLE_ENDIAN)
            val started = System.nanoTime(); val c = crop.content
            // Video ZipDepth model, non-temporal normalization: changing ROIs cannot contaminate its
            // temporal band. Virtual distance never reads this relative inverse-depth map.
            val result = JSONObject(DepthNative.processPortrait(model,rgb,near,c[0],c[1],c[2],c[3]))
            check(result.optString("state") == "ready") { "Portrait depth result unavailable" }
            val inferred = System.nanoTime()
            val field = PortraitDepthGeometry.residual(near,dims[0],dims[1],crop,mask)
            val elapsed = (System.nanoTime()-started)/1e6
            synchronized(lock) {
                inferenceMs = result.optDouble("depth_ms",0.0)
                residualMs = (System.nanoTime()-inferred)/1e6
                processMs = if (processMs == 0.0) elapsed else processMs*.8+elapsed*.2
                if (!closed && requested && jobEpoch == epoch) {
                    latest = PortraitDepthGeometry.Map(frame,pts,shotId,crop,mask,dims[0],dims[1],field); updates++
                } else rejected++
            }
            redraw()
        } catch (failure: Throwable) { failed(failure) }
        finally { synchronized(lock) { busy = false } }
    }
    override fun close() {
        synchronized(lock) { if (closed) return; closed = true; epoch++; latest = null; pendingInput = null }
        worker.post { val id = synchronized(lock) { handle.also { handle = 0 } }; if (id > 0) DepthNative.close(id) }
    }
}
