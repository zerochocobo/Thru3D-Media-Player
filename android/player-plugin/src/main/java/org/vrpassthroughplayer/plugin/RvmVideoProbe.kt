package org.vrpassthroughplayer.plugin

import android.content.Context
import android.os.Handler
import org.json.JSONObject
import java.io.File
import java.nio.ByteBuffer
import java.nio.ByteOrder
import java.util.zip.CRC32

/** Retain the exact color lease while both eyes run RVM.
 * One running input and up to [QUEUE] waiting inputs; a newer one replaces the oldest waiting.
 * The short queue absorbs single slow inferences (8K runs within ~1 ms of the frame time)
 * instead of dropping a frame for each. Diagnostic mode saves eight
 * pairs; player mode runs continuously without per-frame evidence files.
 * The shared handler serializes prepare/process/close across retiring sessions.
 * Alpha is handed to the owner GL uploader; this class does not present textures.
 */
internal class RvmVideoProbe(
    private val scope: MediaSessionGate.Scope,
    private val profile: String,
    private val vulkan: Boolean,
    private val context: () -> Context?,
    private val worker: Handler,
    private val release: (Long) -> Unit,
    private val ready: () -> Unit,
    private val completed: (JSONObject, ByteBuffer, ByteBuffer) -> Boolean,
    private val failed: (Throwable) -> Unit,
    private val diagnostic: Boolean = true,
    private val roi: () -> RoiController? = { null },
) : AutoCloseable {
    private data class Input(val identity: FramePairGate.Identity, val left: ByteBuffer,
                             val right: ByteBuffer, val descriptor: String,
                             val windowId: Long, val rect: FloatArray?,
                             val scoutLeft: ByteBuffer?, val scoutRight: ByteBuffer?,
                             // Zero-copy {in L, in R, Alpha L, Alpha R} AHardwareBuffer handles.
                             val shared: LongArray? = null, val scoutShared: LongArray? = null,
                             val submittedNs: Long = System.nanoTime()) {
        /** Drops this input's buffer references (held so a closing bridge cannot free them mid-use). */
        fun releaseBuffers() { RenderBridgeNative.releaseBuffers(shared); RenderBridgeNative.releaseBuffers(scoutShared) }
    }
    private val lock = Any()
    private val gate = FramePairGate(scope).apply { setAlpha(true) }
    private var closed = false
    private var runtime: RvmRuntime? = null
    private val pending = ArrayDeque<Input>()
    private var scheduled = false
    private var count = 0
    private var skipped = 0L
    private var appliedGeneration = 0L // RVM worker only.
    private var appliedWindow = 0L // RVM worker only: ROI window the display states belong to.
    private var appliedShot = -1L
    private var appliedScoutShot = -1L
    private var appliedFrame = -1L
    private var appliedPts = -1L
    // Worker timing (exponential averages, ms): inference call, whole drain, idle gap before a drain.
    @Volatile var processMs = 0.0; private set
    @Volatile var drainMs = 0.0; private set
    @Volatile var idleMs = 0.0; private set
    private var lastDrainEnd = 0L
    private val timeline = FrameTimeline()
    fun stats(): Map<String, Any> = mapOf("rvm_timeline" to timeline.json(), "rvm_process_ms_avg" to processMs, "rvm_drain_ms_avg" to drainMs,
        "rvm_idle_ms_avg" to idleMs, "rvm_pending_replaced" to skipped)

    /** Do not consume the paused source's only frame while the runtime is still preparing. */
    fun isReady(): Boolean = synchronized(lock) { !closed && runtime != null }

    fun start() {
        // Queue behind a running warmup compile first (it fills the cache), then build the runtime
        // on the inference worker that uses it. Built on the prepare thread, it never became ready.
        RvmWorkers.prepare.post { worker.post {
            try {
                if (synchronized(lock) { closed }) return@post
                val host = context() ?: error("RVM probe activity unavailable")
                RvmNative.configureGpu(RvmWarmup.cacheDirectory(host).absolutePath, RvmNative.fp16())
                val generation = gate.modelGeneration()
                val prepared = RvmRuntime.prepare(host.assets, vulkan, profile,
                    scope.logicalSessionId.toLong(), generation)
                val retained = synchronized(lock) {
                    if (closed) false else { runtime = prepared; appliedGeneration = generation; true }
                }
                if (!retained) prepared.close() else ready()
            } catch (error: Throwable) {
                if (!synchronized(lock) { closed }) failed(error)
            }
        } }
    }

    fun setFormat(revision: Int) {
        synchronized(lock) { if (!closed) gate.setFormat(revision) }
    }
    fun acceptsPair(pair: JSONObject): Boolean = synchronized(lock) {
        !closed && gate.accepts(identity(pair))
    }
    fun presented(pair: JSONObject): Boolean = synchronized(lock) { !closed && gate.presented(identity(pair)) }
    private fun identity(pair: JSONObject) = FramePairGate.Identity(pair.getInt("session_id"), pair.getInt("logical_session_id"),
        pair.getInt("generation"), pair.getLong("frame_id"), pair.getLong("pts_us"), pair.getInt("format_revision"),
        pair.getLong("effect_revision"), pair.getLong("model_generation"), pair.getLong("slot_token"))

    /** Zero-copy: the slot lease keeps the bridge's AHardwareBuffers alive until release/hand-off. */
    fun submitShared(ticket: DecodedFrameGate.Ticket, token: Long, shared: LongArray, descriptor: JSONObject,
                     scoutShared: LongArray?) {
        check(!diagnostic) { "Diagnostic evidence needs CPU buffers" }
        submit(ticket, token, EMPTY, EMPTY, descriptor, null, null, shared, scoutShared)
    }

    fun submit(ticket: DecodedFrameGate.Ticket, token: Long, left: ByteBuffer,
               right: ByteBuffer, descriptor: JSONObject, scoutLeft: ByteBuffer? = null, scoutRight: ByteBuffer? = null,
               shared: LongArray? = null, scoutShared: LongArray? = null) {
        val windowId = descriptor.optLong("roi_window_id", 0L)
        val rect = descriptor.optJSONArray("model_content_rect")?.let { a -> FloatArray(4) { a.getDouble(it).toFloat() } }
        var obsolete: Long? = null
        var dropped: Input? = null
        var dispatch = false
        synchronized(lock) {
            val identity = gate.identify(ticket, token)
            if (closed || (diagnostic && count >= LIMIT) || identity == null) obsolete = token
            else {
                if (pending.size >= QUEUE) pending.removeFirst().let { obsolete = it.identity.slotToken; dropped = it; skipped++ }
                pending.addLast(Input(identity, left, right, descriptor.toString(), windowId, rect, scoutLeft, scoutRight,
                    shared, scoutShared))
                if (!scheduled) { scheduled = true; dispatch = true }
            }
        }
        if (obsolete == token) { RenderBridgeNative.releaseBuffers(shared); RenderBridgeNative.releaseBuffers(scoutShared) }
        dropped?.releaseBuffers()
        obsolete?.let(release)
        if (dispatch) worker.post { drain() }
    }

    private fun drain() {
        val input = synchronized(lock) {
            val next = pending.removeFirstOrNull()
            if (closed || (diagnostic && count >= LIMIT) || next == null) { scheduled = false; next }
            else next
        } ?: return
        var handedOff = false
        var readback = false
        var measured = false
        val drainStart = System.nanoTime()
        if (lastDrainEnd > 0) idleMs = idleMs * 0.9 + (drainStart - lastDrainEnd) / 1e6 * 0.1
        try {
            val active = synchronized(lock) { if (closed || (diagnostic && count >= LIMIT)) null else runtime }
                ?: return
            val size = profile.split('x').map { it.toInt() }.let { it[0] * it[1] * 4 }
            // Zero-copy Alpha stays in the bridge's buffers; only the CPU path needs host planes.
            val leftAlpha = if (input.shared != null) EMPTY else ByteBuffer.allocateDirect(size).order(ByteOrder.LITTLE_ENDIAN)
            val rightAlpha = if (input.shared != null) EMPTY else ByteBuffer.allocateDirect(size).order(ByteOrder.LITTLE_ENDIAN)
            val id = input.identity
            if (!gate.accepts(id)) return
            if (appliedGeneration != id.modelGeneration) {
                check(active.reset(id.modelGeneration)) { "Video RVM format reset failed" }
                appliedGeneration = id.modelGeneration
                appliedFrame = -1L; appliedPts = -1L
            }
            val started = System.nanoTime()
            // A new ROI window starts the display stream from zero states, even when the
            // first input of that window was dropped in favour of a newer one.
            val shared = input.shared
            // Source packing, never the number of XR viewing eyes. Unknown diagnostic descriptors
            // retain the legacy stereo contract; spatial SBS descriptors already carry true here.
            val descriptor = JSONObject(input.descriptor)
            val eyes = if (descriptor.optBoolean("stereo_sbs", true)) 2 else 1
            val shot = descriptor.optLong("portrait_shot_id", -1L)
            val shotChanged = eyes == 1 && shot != appliedShot
            val redraw = id.frameId == appliedFrame && id.ptsUs == appliedPts
            val resetFirst = input.windowId != appliedWindow || shotChanged || redraw
            descriptor.put("portrait_shot_cut", shotChanged)
            val output = if (shared != null)
                active.processAhb(id.modelGeneration, id.frameId, id.ptsUs, shared.copyOfRange(0, 2), shared.copyOfRange(2, 4), 0, resetFirst, eyes)
            else active.process(id.modelGeneration, id.frameId, id.ptsUs,
                input.left, input.right, leftAlpha, rightAlpha, 0, resetFirst, eyes)
            appliedFrame = id.frameId; appliedPts = id.ptsUs
            // A periodic check found nonfinite recurrent states: they were reset, skip this Alpha.
            if (output.optString("state") == "state_reset") return
            appliedWindow = input.windowId
            appliedShot = shot
            val elapsedMs = (System.nanoTime() - started) / 1e6
            processMs = processMs * 0.9 + elapsedMs * 0.1
            if (synchronized(lock) { closed } || !gate.accepts(id) || output.optString("state") == "stale") return
            check(output.getString("state") == "ready" && output.getString("profile_key") == profile &&
                gate.matchesRuntime(id, output.getLong("session_id"), output.getLong("generation"),
                    output.getLong("frame_id"), output.getLong("pts_us"))) { "RVM video identity mismatch" }
            val ordinal = synchronized(lock) { count + 1 }
            val directory = if (diagnostic) File(context()?.filesDir ?: error("Activity unavailable"),
                "diagnostics/rvm_video_${DiagnosticRequests.processId}_${scope.decoderId}").apply { check(mkdirs() || isDirectory) } else null
            val stem = "pair_${ordinal}_${id.frameId}"
            val files = JSONObject()
            if (directory != null) for ((name, buffer) in listOf("left_rgb" to input.left, "right_rgb" to input.right,
                                        "left_alpha" to leftAlpha, "right_alpha" to rightAlpha)) {
                val target = File(directory, "${stem}_$name.f32")
                target.outputStream().channel.use { channel ->
                    val bytes = buffer.duplicate().apply { clear() }
                    while (bytes.hasRemaining()) check(channel.write(bytes) > 0)
                }
                val crc = CRC32().apply { update(buffer.duplicate().apply { clear() }) }.value
                files.put(name, JSONObject().put("file", target.name).put("bytes", buffer.capacity()).put("crc32", crc))
            }
            val result = descriptor.put("effect_revision", id.effectRevision).put("inference_eyes", eyes)
                .put("session_id", id.decoderId).put("logical_session_id", id.logicalSessionId).put("generation", id.generation)
                .put("model_generation", id.modelGeneration).put("inference_ran", true)
                .put("pair_identity_verified", true).put("rvm_backend", if (vulkan) "vulkan" else "cpu")
                .put("rvm_process_ms", elapsedMs)
                .put("alpha_layout", if (shared != null) "AHardwareBuffer_R_round_alpha_x255" else "float32_CHW_numeric_0_1")
                .put("alpha_transport", if (shared != null) "zero_copy" else "cpu")
                .put("alpha_gpu_uploaded", false).put("pair_presented", false)
                .put("evidence_files", files).put("diagnostic_evidence", diagnostic)
                .put("kernel", output).put("probe_ordinal", ordinal)
            if (directory != null) result.put("evidence_directory", directory.name)
            val controller = roi()
            var scoutAfterPublish: (() -> Unit)? = null
            if (controller != null && input.rect != null && shared != null) {
                // Copy the planes while the slot lease guarantees the buffers; analyse elsewhere so the
                // next inference starts immediately. Most results need no analysis: skip the readback.
                val window = input.windowId; val rect = input.rect
                if (controller.wantsAlpha(window)) {
                    readback = true
                    val planes = ByteBuffer.allocateDirect(size / 2)
                    check(RvmNative.readAlphaPlanes(shared[2], shared[if (eyes == 1) 2 else 3], planes))
                    if (eyes == 1) portraitObservation(result, planes, rect)
                    RvmWorkers.roi.post { controller.onMainPlanes(window, rect, planes) }
                } else RvmWorkers.roi.post { controller.onMainSkipped(window) }
                input.scoutShared?.let { scout ->
                    // The scout input belongs to this slot: run it while this worker still holds the lease.
                    scoutAfterPublish = {
                        val scouted = active.processAhb(id.modelGeneration, id.frameId, id.ptsUs, scout.copyOfRange(0, 2),
                            scout.copyOfRange(2, 4), 1, shot != appliedScoutShot || redraw, eyes = 1)
                        if (scouted.optString("state") == "ready") {
                            appliedScoutShot = shot
                            val scoutPlanes = ByteBuffer.allocateDirect(size / 2)
                            check(RvmNative.readAlphaPlanes(scout[2], scout[2], scoutPlanes))
                            RvmWorkers.roi.post { controller.onScoutPlanes(window, scoutPlanes) }
                        }
                    }
                }
                result.put("roi_reset", resetFirst).put("roi_scout_ran", input.scoutShared != null)
            } else if (controller != null && input.rect != null) {
                // Read before the buffers are handed to the GL uploader.
                readback = true
                controller.onMain(input.windowId, input.rect, leftAlpha, rightAlpha)
                if (input.scoutLeft != null && input.scoutRight != null) {
                    val scoutLeftAlpha = ByteBuffer.allocateDirect(size).order(ByteOrder.LITTLE_ENDIAN)
                    val scoutRightAlpha = ByteBuffer.allocateDirect(size).order(ByteOrder.LITTLE_ENDIAN)
                    val scouted = active.process(id.modelGeneration, id.frameId, id.ptsUs, input.scoutLeft, input.scoutRight,
                        scoutLeftAlpha, scoutRightAlpha, 1, shot != appliedScoutShot || redraw, eyes = 1)
                    if (scouted.optString("state") == "ready") appliedScoutShot = shot
                    if (scouted.optString("state") == "ready") controller.onScout(input.windowId, scoutLeftAlpha, scoutRightAlpha)
                }
                result.put("roi_reset", resetFirst).put("roi_scout_ran", input.scoutLeft != null)
            }
            // First mono result establishes an observation; later samples reuse the ROI cadence.
            // Debug ROI-off still gets bounded observations, never a per-XR-frame readback.
            if (eyes == 1 && !result.has("portrait_observation") && (shotChanged || ordinal == 1 || ((controller == null || shared == null) && ordinal % 10 == 0)) && input.rect != null) {
                val planes = ByteBuffer.allocateDirect(size / 2)
                if (shared != null) check(RvmNative.readAlphaPlanes(shared[2], shared[2], planes))
                else for (i in 0 until size / 4) planes.put(i, (leftAlpha.getFloat(i * 4).coerceIn(0f, 1f) * 255).toInt().toByte())
                readback = true
                portraitObservation(result, planes, input.rect)
            }
            val publish = synchronized(lock) {
                if (closed || !gate.accepts(id)) false
                else { count++; result.put("rvm_probe_pairs", count).put("rvm_pending_replaced", skipped); true }
            }
            // A true result transfers this color lease and Alpha buffers to the GL uploader.
            if (publish) scoutAfterPublish?.invoke()
            if (publish) handedOff = completed(result, leftAlpha, rightAlpha)
            measured = publish
        } catch (error: Throwable) {
            if (!synchronized(lock) { closed }) failed(error)
        } finally {
            lastDrainEnd = System.nanoTime()
            drainMs = drainMs * 0.9 + (lastDrainEnd - drainStart) / 1e6 * 0.1
            if (measured) timeline.record(readback, input.scoutShared != null || input.scoutLeft != null,
                (drainStart - input.submittedNs) / 1e6, (lastDrainEnd - drainStart) / 1e6, (lastDrainEnd - input.submittedNs) / 1e6)
            input.releaseBuffers() // after the main and scout inferences of this input
            if (!handedOff) release(input.identity.slotToken)
            val again = synchronized(lock) {
                if (pending.isEmpty()) { scheduled = false; false } else true
            }
            if (again) worker.post { drain() }
        }
    }

    override fun close() {
        val obsolete: List<Input>
        val previous: RvmRuntime?
        synchronized(lock) {
            if (closed) return
            closed = true; gate.close()
            obsolete = pending.toList(); pending.clear()
            previous = runtime; runtime = null
        }
        // Immediate native invalidation; the in-flight process retains its own inputs.
        previous?.close()
        obsolete.forEach { it.releaseBuffers(); release(it.identity.slotToken) }
    }
    private fun portraitObservation(result: JSONObject, planes: ByteBuffer, rect: FloatArray) {
        val dimensions = profile.split('x').map { it.toInt() }
        val observation = PortraitMask.observe(planes, dimensions[0], dimensions[1], rect)
        result.put("portrait_observation", JSONObject().put("bounds", org.json.JSONArray(observation.bounds))
            .put("subjects", observation.subjects).put("cropped", observation.cropped)
            .put("frame_id", result.getLong("frame_id")).put("pts_us", result.getLong("pts_us")))
    }
    companion object {
        const val LIMIT = 8
        const val QUEUE = 2
        private val EMPTY: ByteBuffer = ByteBuffer.allocateDirect(0)
    }
}
