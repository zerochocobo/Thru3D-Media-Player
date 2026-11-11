package org.vrpassthroughplayer.plugin

import android.content.Context
import org.json.JSONArray
import org.json.JSONObject
import java.nio.ByteBuffer
import java.nio.ByteOrder

/** Motion-only adapter for the existing video model/stabilizer. One worker job and one newest
 * identity are retained; no frame files, full-size Java pixel copies or XR-thread inference. */
internal class AnimatedPhotoDepth(
    private val capture: (ByteBuffer, Int, Int) -> Input?,
    private val width: Int,
    private val height: Int,
    private val backend: Backend,
    private val post: (Runnable) -> Unit,
    private val clock: () -> Long = System::nanoTime,
) : AutoCloseable {
    data class Identity(val frame: Long, val ptsUs: Long, val loop: Long)
    data class Input(val identity: Identity, val rect: IntArray)
    interface Backend : AutoCloseable {
        fun open()
        fun process(rgb: ByteBuffer, rect: IntArray, reset: Boolean, step: Int): ByteArray
    }
    private data class Map(val token: Long, val input: Input, val pixels: ByteArray)
    private val lock = Any()
    private var closed = false
    private var busy = false
    private var opened = false // worker only
    private var pending: Identity? = null
    private var shown: Identity? = null
    private var accepted: Identity? = null // worker only
    private var latest: Map? = null
    private var serial = 0L
    private var updates = 0L
    private var error = ""
    private var processMs = 0.0
    private var latencyMs = 0.0
    private var queuedAt = 0L
    private var rgb: ByteBuffer? = null // one reusable model-size input, worker only

    init { require(width in 1..1024 && height in 1..1024) }

    fun present(identity: Identity) {
        val schedule = synchronized(lock) {
            if (closed || error.isNotEmpty()) return
            if (shown?.loop != identity.loop) latest = null
            shown = identity
            val previous = accepted
            if (previous != null && previous.loop == identity.loop && identity.ptsUs >= previous.ptsUs && identity.ptsUs - previous.ptsUs < 28_000) return
            pending = identity
            if (busy) false else { busy = true; queuedAt = clock(); true }
        }
        if (schedule) post(Runnable(::run))
    }

    private fun run() {
        try {
            synchronized(lock) { if (closed) return; pending = null }
            if (!opened) { backend.open(); opened = true }
            synchronized(lock) { if (closed) return }
            val buffer = rgb ?: ByteBuffer.allocateDirect(width * height * 12).order(ByteOrder.LITTLE_ENDIAN).also { rgb = it }
            val input = capture(buffer, width, height) ?: return
            val id = input.identity
            val previous = accepted
            // Preserve the video's 28 ms source-time policy. No wall-time backoff on slow devices.
            if (previous != null && previous.loop == id.loop && id.ptsUs >= previous.ptsUs && id.ptsUs - previous.ptsUs < 28_000) return
            val rect = input.rect
            require(rect.size == 4 && rect[0] >= 0 && rect[1] >= 0 && rect[2] > 0 && rect[3] > 0 &&
                rect[0].toLong() + rect[2] <= width && rect[1].toLong() + rect[3] <= height)
            synchronized(lock) { if (closed || shown?.loop != id.loop) return }
            val reset = previous == null || previous.loop != id.loop || id.frame <= previous.frame
            val step = if (reset) 1 else (id.frame - previous.frame).coerceIn(1L, 1000L).toInt()
            val started = clock()
            val pixels = backend.process(buffer, rect.copyOf(), reset, step)
            require(pixels.size == width * height * 4)
            synchronized(lock) {
                accepted = id
                if (!closed && shown?.loop == id.loop && id.frame <= (shown?.frame ?: -1)) {
                    latest = Map(++serial, input, pixels); updates++
                    processMs = (clock() - started) / 1e6
                    latencyMs = (clock() - queuedAt) / 1e6
                }
            }
        } catch (_: Throwable) {
            synchronized(lock) { if (!closed) { error = "3D unavailable"; latest = null; pending = null } }
            backend.close(); opened = false
        } finally {
            val again = synchronized(lock) {
                busy = false
                val next = pending
                if (!closed && error.isEmpty() && next != null && next != accepted) {
                    busy = true; queuedAt = clock(); true
                } else false
            }
            if (again) post(Runnable(::run))
        }
    }

    fun status(): JSONObject = synchronized(lock) {
        val map = latest
        JSONObject().put("state", if (error.isNotEmpty()) "failed" else if (map == null) "preparing" else "ready")
            .put("error", error).put("token", map?.token ?: 0).put("frame_id", map?.input?.identity?.frame ?: -1)
            .put("loop", map?.input?.identity?.loop ?: -1).put("width", width).put("height", height)
            .put("rect", JSONArray(map?.input?.rect?.map { it } ?: emptyList<Int>()))
            .put("updates", updates).put("process_ms", processMs).put("latency_ms", latencyMs).put("interval_ms", 28)
    }

    fun pixels(token: Long): ByteArray = synchronized(lock) {
        latest?.takeIf { !closed && it.token == token }?.pixels ?: ByteArray(0)
    }

    override fun close() {
        synchronized(lock) { if (closed) return; closed = true; latest = null; pending = null }
        // Same worker as inference: closing never races a native call or blocks XR.
        post(Runnable { backend.close(); opened = false; rgb = null })
    }

    companion object {
        fun create(context: () -> Context?, capture: (ByteBuffer, Int, Int) -> Input?): AnimatedPhotoDepth {
            val dims = DepthNative.PROFILE.split('x').map(String::toInt)
            return AnimatedPhotoDepth(capture, dims[0], dims[1], VideoBackend(context, dims[0], dims[1]), { DepthWorker.handler.post(it) })
        }
    }

    /** Reuses DepthVideoProbe's model preparation, infer, content bounds and temporal stabilization.
     * Still-photo DA2, PhotoDepthRuntime and its persistent cache are never touched. */
    private class VideoBackend(val context: () -> Context?, val width: Int, val height: Int) : Backend {
        private var handle = 0L
        private var raw: ByteBuffer? = null
        private var near: ByteBuffer? = null
        override fun open() {
            val host = context() ?: error("Depth context unavailable")
            try {
                handle = ModelPreparationGate.run {
                    DepthNative.videoModelFile(host)?.let { DepthNative.createFromFile(it.path, DepthWarmup.cacheDirectory(host).absolutePath) }
                        ?: DepthNative.create(host.assets, DepthWarmup.cacheDirectory(host).absolutePath)
                }
                check(handle > 0)
                val info = JSONObject(DepthNative.describe(handle))
                check(info.getInt("width") == width && info.getInt("height") == height)
                raw = ByteBuffer.allocateDirect(width * height * 4).order(ByteOrder.LITTLE_ENDIAN)
                near = ByteBuffer.allocateDirect(width * height * 4).order(ByteOrder.LITTLE_ENDIAN)
            } catch (failure: Throwable) { close(); throw failure }
        }
        override fun process(rgb: ByteBuffer, rect: IntArray, reset: Boolean, step: Int): ByteArray {
            val kernel = JSONObject(DepthNative.infer(handle, rgb, raw!!))
            check(kernel.optString("state") == "ready")
            kernel.optJSONArray("picture")?.takeIf { it.length() == 4 }?.let {
                val x = maxOf(rect[0], it.getInt(0)); val y = maxOf(rect[1], it.getInt(1))
                val right = minOf(rect[0] + rect[2], it.getInt(0) + it.getInt(2))
                val bottom = minOf(rect[1] + rect[3], it.getInt(1) + it.getInt(3))
                if (right > x && bottom > y) { rect[0] = x; rect[1] = y; rect[2] = right - x; rect[3] = bottom - y }
            }
            check(JSONObject(DepthNative.stabilize(handle, raw!!, rgb, near!!, reset, step, rect[0], rect[1], rect[2], rect[3])).optString("state") == "ready")
            return ByteArray(width * height * 4).also { near!!.duplicate().apply { clear() }.get(it) }
        }
        override fun close() {
            if (handle > 0) DepthNative.close(handle)
            handle = 0; raw = null; near = null
        }
    }
}
