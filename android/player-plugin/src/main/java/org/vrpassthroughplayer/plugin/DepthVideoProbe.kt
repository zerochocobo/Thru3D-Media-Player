package org.vrpassthroughplayer.plugin

import android.content.Context
import android.os.Handler
import android.os.HandlerThread
import org.json.JSONObject
import java.io.File
import java.nio.ByteBuffer
import java.nio.ByteOrder

/** Realtime 2D->3D: every presented mono frame carries a near map in the pair's R8 mask (both
 * halves), sharing the color's immutable slot, fences and display gates with Alpha. The shader
 * shifts each eye's color sampling by the near map (flat SBS 3D, not VR).
 *
 * The video never waits for depth. Each frame is published at once with the latest near map. Depth is
 * a bounded two-stage pipeline: [DepthWorker] runs one GPU inference at a time while [DepthPost]
 * stabilizes the previous result. While the GPU is busy the newest staged frame waits (a newer one
 * replaces it), so the next inference starts as soon as the GPU is free instead of one or two frames
 * later. Three input/raw buffers bound the work in flight; ZipDepth uses the device tier's input.
 * Before the first result (cold compile) and for good if the model cannot run, frames show in 2D
 * (depth_ran=false) and the reason is reported in stats. */
internal class DepthVideoProbe(
    private val scope: MediaSessionGate.Scope,
    private val context: () -> Context?,
    private val release: (Long) -> Unit,
    private val ready: () -> Unit,
    private val completed: (JSONObject, ByteBuffer, ByteBuffer) -> Boolean,
    private val mapReady: () -> Unit = {},
) : AutoCloseable {
    private val worker = DepthWorker.handler
    private val lock = Any()
    private val gate = FramePairGate(scope).apply { setAlpha(true) }
    private var closed = false
    @Volatile private var handle = 0L // set on the depth worker once compiled
    @Volatile private var error = ""   // non-empty: depth cannot run, frames stay 2D
    // Latest finished map (one copy per eye half: the bridge's upload rejects aliased inputs) and the
    // frame it belongs to. Published maps are never written again.
    private var latest: Pair<ByteBuffer, ByteBuffer>? = null // lock
    private var latestFrame = -1L          // lock
    private var lastSubmitted = -1L        // lock: a backwards jump (seek, loop) drops the old scene's map
    /** A staged model input and its raw inverse depth; owned by one pipeline stage at a time. */
    private class Job(val rgb: ByteBuffer, val raw: ByteBuffer) { var frameId = -1L; var submittedNs = 0L; val content = IntArray(4) }
    private val free = ArrayDeque<Job>()   // lock
    private var jobs = 0                   // lock: allocated, at most JOBS
    private var inferring = false          // lock: one GPU inference at a time
    private var pending: Job? = null       // lock: newest input waiting for the GPU
    private var replaced = 0L              // lock: pending inputs superseded by a newer frame
    private var lastStartNs = 0L           // lock: start of the latest inference
    /** Minimum time between inference starts from an idle GPU: the gap goes to decode and display. */
    private val intervalNs = debugIntervalMs() * 1_000_000L
    private var count = 0L
    private var lastInferred = -1L // post thread only: source frame of the previous stabilized map
    private var inferred = 0L
    private val dims = DepthNative.PROFILE.split('x').map { it.toInt() }
    private val plane = dims[0] * dims[1]
    @Volatile var processMs = 0.0; private set   // inference + stabilizer wall time per map
    @Volatile private var inferMs = 0.0          // GPU stage: upload, run, readback wait
    @Volatile private var stabilizeMs = 0.0      // CPU stage: near-map stabilizer
    @Volatile private var latencyMs = 0.0        // frame submitted -> its map ready
    @Volatile private var info = ""
    @Volatile private var inferStages = "{}"
    @Volatile private var postStages = "{}"
    fun stats(): Map<String, Any> = mapOf("depth_process_ms_avg" to processMs, "depth_infer_ms_avg" to inferMs,
        "depth_stabilize_ms_avg" to stabilizeMs, "depth_latency_ms_avg" to latencyMs, "depth_updates" to inferred,
        "depth_interval_ms" to intervalNs / 1_000_000L, "depth_pending_replaced" to synchronized(lock) { replaced },
        "depth_stages" to JSONObject(inferStages).also { stages ->
            JSONObject(postStages).let { post -> post.keys().forEach { stages.put(it, post.get(it)) } }
        }.toString(),
        "depth_runtime" to info, "depth_ready" to (handle > 0), "depth_error" to error)

    fun start() {
        worker.post {
            try {
                if (synchronized(lock) { closed }) return@post
                val host = context() ?: error("Depth activity unavailable")
                val created = DepthNative.videoModelFile(host)?.let { DepthNative.createFromFile(it.path, DepthWarmup.cacheDirectory(host).absolutePath) }
                    ?: DepthNative.create(host.assets, DepthWarmup.cacheDirectory(host).absolutePath)
                check(created > 0) { "Depth prepare failed" }
                val description = DepthNative.describe(created)
                val dimensions = JSONObject(description)
                if (dimensions.getInt("width") != dims[0] || dimensions.getInt("height") != dims[1]) {
                    DepthNative.close(created)
                    error("Video depth input dimensions differ")
                }
                val kept = synchronized(lock) { if (closed) false else { handle = created; true } }
                if (!kept) DepthNative.close(created) else { info = description; ready() }
            } catch (failure: Throwable) {
                error = failure.message ?: failure.javaClass.simpleName
                android.util.Log.w("QuestDepth", "2D->3D unavailable, playing 2D: $error")
            }
        }
    }

    fun acceptsPair(pair: JSONObject): Boolean = synchronized(lock) { !closed && gate.accepts(identity(pair)) }
    fun presented(pair: JSONObject): Boolean = synchronized(lock) { !closed && gate.presented(identity(pair)) }
    private fun identity(pair: JSONObject) = FramePairGate.Identity(pair.getInt("session_id"), pair.getInt("logical_session_id"),
        pair.getInt("generation"), pair.getLong("frame_id"), pair.getLong("pts_us"), pair.getInt("format_revision"),
        pair.getLong("effect_revision"), pair.getLong("model_generation"), pair.getLong("slot_token"))

    /** The next frame's model input would be used: stage it (otherwise the bridge skips the readback).
     * While the GPU is busy, every new frame is staged to replace the pending one. */
    fun wantsInput(frameId: Long): Boolean = synchronized(lock) {
        !closed && handle > 0L && latestFrame != frameId && pending?.frameId != frameId &&
            (if (inferring) pending != null || available() else available() && System.nanoTime() - lastStartNs >= intervalNs)
    }
    private fun available() = free.isNotEmpty() || jobs < JOBS // lock
    private fun take(): Job? = free.removeFirstOrNull() // lock
        ?: if (jobs < JOBS) { jobs++; Job(direct(plane * 12), direct(plane * 4)) } else null

    /** [rgb] is the bridge's staged mono input (float32 CHW), valid only during this call; null when
     * this frame was not staged for the model. */
    fun submit(ticket: DecodedFrameGate.Ticket, token: Long, rgb: ByteBuffer?, descriptor: JSONObject) {
        var near: Pair<ByteBuffer, ByteBuffer>
        var nearFrame: Long
        var start: Job? = null
        val id = synchronized(lock) {
            val identity = gate.identify(ticket, token)
            if (closed || identity == null) null else {
                if (identity.frameId < lastSubmitted) {
                    latest = null; latestFrame = -1L
                    pending?.let { free.addLast(it) }; pending = null
                }
                lastSubmitted = identity.frameId
                if (rgb != null && handle > 0L && rgb.capacity() == plane * 12) {
                    val job = if (!inferring) take() else pending?.also { replaced++ } ?: take()?.also { pending = it }
                    if (job != null) {
                        // Copy: the slot (and its staged input) is handed to the display below.
                        job.rgb.clear(); job.rgb.put(rgb.duplicate().apply { clear() }); job.rgb.clear()
                        job.frameId = identity.frameId; job.submittedNs = System.nanoTime()
                        contentPixels(descriptor, job.content)
                        if (!inferring) { inferring = true; lastStartNs = job.submittedNs; start = job }
                    }
                }
                identity
            }
        }
        if (id == null) { release(token); return }
        synchronized(lock) { near = latest ?: FLAT; nearFrame = latestFrame }
        val ran = near !== FLAT
        val kernel = JSONObject().put("near_frame_id", nearFrame).put("frames_behind", if (ran) id.frameId - nearFrame else -1)
        if (!publish(id, descriptor.toString(), near, ran, kernel)) release(token)
        start?.let { job -> worker.post { infer(job) } }
    }

    /** True hands the color lease to the GL uploader. */
    private fun publish(id: FramePairGate.Identity, descriptor: String, near: Pair<ByteBuffer, ByteBuffer>, ran: Boolean,
                        kernel: JSONObject): Boolean {
        val result = JSONObject(descriptor).put("effect_revision", id.effectRevision)
            .put("session_id", id.decoderId).put("logical_session_id", id.logicalSessionId).put("generation", id.generation)
            .put("model_generation", id.modelGeneration).put("inference_ran", ran).put("depth_ran", ran)
            .put("pair_identity_verified", true).put("alpha_kind", "depth_near_map")
            .put("alpha_transport", "cpu").put("alpha_gpu_uploaded", false).put("pair_presented", false)
            .put("depth_kernel", kernel).put("depth_error", error)
        val accepted = synchronized(lock) {
            if (closed || !gate.accepts(id)) false else { count++; result.put("depth_pairs", count); true }
        }
        return accepted && completed(result, near.first, near.second)
    }

    /** GPU stage on [DepthWorker]: hands the raw map to [DepthPost], then starts the pending frame. */
    private fun infer(job: Job) {
        var handed = false
        try {
            val active = handle
            if (active <= 0L || synchronized(lock) { closed }) return
            val started = System.nanoTime()
            val kernel = try {
                JSONObject(DepthNative.infer(active, job.rgb, job.raw))
            } catch (failure: Throwable) {
                failed(active, failure); return
            }
            inferMs = inferMs * 0.9 + (System.nanoTime() - started) / 1e6 * 0.1
            inferStages = kernel.optJSONObject("stages")?.toString() ?: "{}"
            if (kernel.optString("state") != "ready") return
            // Handler order keeps the stabilizer in source order.
            DepthPost.handler.post { stabilize(active, job, started) }
            handed = true
        } finally {
            val next = synchronized(lock) {
                if (!handed && !closed) free.addLast(job)
                inferring = false
                // A pending frame from before a seek was already dropped by submit.
                val waiting = pending?.takeIf { !closed && handle > 0L }
                pending = null
                if (waiting != null) { inferring = true; lastStartNs = System.nanoTime() }
                waiting
            }
            next?.let { worker.post { infer(it) } }
        }
    }

    /** CPU stage on [DepthPost]. The stabilizer's rates are per source frame: skipped frames count. */
    private fun stabilize(active: Long, job: Job, started: Long) {
        try {
            if (synchronized(lock) { closed } || handle != active) return
            val frameId = job.frameId
            val near = direct(plane * 4)
            val reset = synchronized(lock) { latest == null } || lastInferred < 0 || frameId <= lastInferred
            val step = if (reset) 1 else (frameId - lastInferred).coerceIn(1L, 1000L).toInt()
            lastInferred = frameId
            val kernel = try {
                JSONObject(DepthNative.stabilize(active, job.raw, job.rgb, near, reset, step,
                    job.content[0], job.content[1], job.content[2], job.content[3]))
            } catch (failure: Throwable) {
                if (!synchronized(lock) { closed }) failed(active, failure)
                return
            }
            val now = System.nanoTime()
            processMs = processMs * 0.9 + (now - started) / 1e6 * 0.1
            latencyMs = latencyMs * 0.9 + (now - job.submittedNs) / 1e6 * 0.1
            stabilizeMs = stabilizeMs * 0.9 + kernel.optDouble("stabilize_ms", 0.0) * 0.1
            postStages = kernel.optJSONObject("stages")?.toString() ?: "{}"
            if (kernel.optString("state") != "ready") return
            val updated = synchronized(lock) {
                // A seek while this ran: its scene is gone.
                if (!closed && frameId <= lastSubmitted && (latestFrame < 0 || frameId >= latestFrame)) {
                    val copy = direct(near.capacity()).put(near.duplicate().apply { clear() }).apply { clear() }
                    latest = near to copy; latestFrame = frameId; inferred++
                    true
                } else false
            }
            if (updated) mapReady()
            // Debug A/B of the depth input size: one line per 50 maps.
            if (updated && BuildConfig.DEBUG && inferred % 50 == 0L) android.util.Log.i("QuestDepth",
                "video depth profile=${DepthNative.PROFILE} infer_ms_avg=${"%.1f".format(inferMs)} " +
                    "latency_ms_avg=${"%.1f".format(latencyMs)} updates=$inferred")
        } finally {
            synchronized(lock) { if (!closed) free.addLast(job) }
        }
    }

    /** The picture's pixels inside the model input (letterbox excluded); the whole map without a rect. */
    private fun contentPixels(descriptor: JSONObject, out: IntArray) {
        val rect = descriptor.optJSONArray("model_content_rect")
        if (rect == null || rect.length() != 4) { out[0] = 0; out[1] = 0; out[2] = dims[0]; out[3] = dims[1]; return }
        val x0 = Math.round(rect.getDouble(0) * dims[0]).toInt().coerceIn(0, dims[0] - 1)
        val y0 = Math.round(rect.getDouble(1) * dims[1]).toInt().coerceIn(0, dims[1] - 1)
        val x1 = Math.round((rect.getDouble(0) + rect.getDouble(2)) * dims[0]).toInt().coerceIn(x0 + 1, dims[0])
        val y1 = Math.round((rect.getDouble(1) + rect.getDouble(3)) * dims[1]).toInt().coerceIn(y0 + 1, dims[1])
        out[0] = x0; out[1] = y0; out[2] = x1 - x0; out[3] = y1 - y0
    }

    /** A model that cannot run stays off for this session; the video goes on in 2D. */
    private fun failed(active: Long, failure: Throwable) {
        error = failure.message ?: failure.javaClass.simpleName
        android.util.Log.w("QuestDepth", "2D->3D inference failed, playing 2D: $error")
        val owned = synchronized(lock) { (handle == active).also { if (it) { handle = 0L; latest = null } } }
        // The worker serializes this after any in-flight inference of the same handle.
        if (owned) worker.post { DepthNative.close(active) }
    }

    override fun close() {
        val previous: Long
        synchronized(lock) {
            if (closed) return
            closed = true; gate.close()
            previous = handle; handle = 0; latest = null
            pending = null; free.clear()
        }
        // The worker serializes this after any in-flight inference; a stabilizer call still running
        // keeps its own native reference, and later ones see the closed handle and stop.
        if (previous > 0) worker.post { DepthNative.close(previous) }
    }

    companion object {
        /** Default gap between depth starts from an idle GPU. Debug builds: adb shell setprop debug.vrpp.depth.interval_ms N. */
        // Cap idle starts near 30 Hz. A busy GPU starts the pending frame as soon as it finishes;
        // jobs never accumulate beyond JOBS.
        private const val INTERVAL_MS = 33L
        /** Input/raw buffers: one inferring, one pending, one being stabilized. */
        private const val JOBS = 3
        private fun direct(bytes: Int): ByteBuffer = ByteBuffer.allocateDirect(bytes).order(ByteOrder.LITTLE_ENDIAN)
        private fun debugIntervalMs(): Long {
            if (!BuildConfig.DEBUG) return INTERVAL_MS
            return try {
                val value = Class.forName("android.os.SystemProperties").getMethod("get", String::class.java)
                    .invoke(null, "debug.vrpp.depth.interval_ms") as String
                value.toLongOrNull()?.coerceIn(0L, 2000L) ?: INTERVAL_MS
            } catch (_: Throwable) { INTERVAL_MS }
        }
        /** Pass-through mask: never written, so every 2D pair can share it (two distinct planes). */
        private val FLAT: Pair<ByteBuffer, ByteBuffer> by lazy {
            fun plane() = direct(DepthNative.PROFILE.split('x').map { it.toInt() }.let { it[0] * it[1] * 4 })
            plane() to plane()
        }
    }
}

/** The depth model's own thread: compiles, warms and runs it. Kept for the process lifetime like
 * the RVM workers (one OpenCL/OpenMP root, never re-created). */
internal object DepthWorker {
    val handler: Handler by lazy { Handler(HandlerThread("QuestDepth").apply { start() }.looper) }
}

/** Video depth's CPU stage (near-map stabilizer), overlapping the next GPU inference. */
internal object DepthPost {
    val handler: Handler by lazy { Handler(HandlerThread("QuestDepthPost").apply { start() }.looper) }
}

/** First use compiles and tunes the depth model's OpenCL kernels; do it before anyone asks for 3D. */
internal object DepthWarmup {
    fun cacheDirectory(context: Context) = File(context.cacheDir, "depth-mnn").apply { mkdirs() }

    fun ready(context: Context): Boolean = DepthNative.unavailable == null && (DepthNative.videoModelFile(context)?.isFile
        ?: (File(DepthNative.cachePath(context.assets, cacheDirectory(context).absolutePath)).length() > 4096))

    /** Runs on [DepthWorker], so a session that starts meanwhile waits for this compile and then
     * opens from the cache instead of compiling a second time. */
    fun schedule(context: Context, report: (JSONObject) -> Unit) {
        if (DepthNative.unavailable != null || DepthNative.videoModelOverride != null) return // debug A/B compiles at session start
        val app = context.applicationContext
        DepthWorker.handler.post {
            val base = JSONObject().put("profile_key", "depth").put("model", "depth")
            try {
                val keep = File(DepthNative.cachePath(app.assets, cacheDirectory(app).absolutePath))
                cacheDirectory(app).listFiles { file -> file != keep }?.forEach { it.delete() }
                if (ready(app)) { report(base.put("state", "cached")); return@post }
                report(JSONObject(base.toString()).put("state", "warming"))
                val started = System.nanoTime()
                val described = ModelPreparationGate.run {
                    val handle = DepthNative.create(app.assets, cacheDirectory(app).absolutePath)
                    try { JSONObject(DepthNative.describe(handle)) } finally { DepthNative.close(handle) }
                }
                report(described.put("profile_key", "depth").put("model", "depth").put("state", "ready")
                    .put("compile_ms", (System.nanoTime() - started) / 1_000_000))
            } catch (error: Throwable) {
                android.util.Log.w("QuestDepth", "Depth warmup failed: ${error.message}")
                report(base.put("state", "failed").put("message", error.message))
            }
        }
    }
}
