package org.vrpassthroughplayer.plugin

import android.content.Context
import android.net.Uri
import android.opengl.EGL14
import android.opengl.EGLContext
import android.os.Handler
import android.os.ParcelFileDescriptor
import org.json.JSONArray
import org.json.JSONObject
import java.nio.ByteBuffer
import java.nio.ByteOrder
import java.util.concurrent.ConcurrentHashMap
import java.util.concurrent.Executors
import java.util.concurrent.atomic.AtomicBoolean
import java.util.concurrent.atomic.AtomicInteger

/** Production MPV -> shared GPU color -> immutable RVM inputs -> complete display
 * pairs. Native MPV survives mode/layout/seek generations; old display claims
 * survive invalidation only until Godot detaches them after its last draw.
 */
internal class MpvVideoBridge(
    private val context: () -> Context?,
    private val render: (Runnable) -> Unit,
    private val emit: (String, Int, String) -> Unit,
    /** Library URI (smb://, http(s)://) -> MPV location; blocks, called on the worker. */
    private val resolveNetwork: (String) -> String = { it },
    /** Library URI -> extra M4A tracks beside the video (clone voice); blocks, called on the worker. */
    private val sidecarAudio: (String) -> List<SidecarAudio.Track> = { emptyList() },
    private val releaseNetwork: (String) -> Unit = {},
    private val sidecarSubtitles: (String) -> List<SidecarSubtitles.Track> = { emptyList() },
    private val networkProgress: (String) -> TransferMeter.Snapshot? = { null },
    private val networkFailure: (String) -> PlaybackFailure? = { null },
    private val subtitleFiles: (String) -> List<String> = { emptyList() },
    private val openSubtitleFile: (String, String) -> SidecarSubtitles.Track = { _, _ -> error("Subtitle unavailable") },
    private val subtitleIdentity: (String) -> String = { "" },
) {
    private val worker = RvmWorkers.video
    private val subtitleWorker = Executors.newSingleThreadExecutor { Thread(it, "QuestSubtitleFiles") }
    private val companionWorker = Executors.newSingleThreadExecutor { Thread(it, "QuestCloudCompanions") }
    private val gate = MediaSessionGate()
    private val sessions = ConcurrentHashMap<Int, Session>()
    private val hosts = ConcurrentHashMap.newKeySet<Host>()
    @Volatile private var foreground = true
    @Volatile private var stopped = false
    private val freezePending = AtomicBoolean(false)
    private val frozenFrames = ConcurrentHashMap<Long, AtomicInteger>()
    @Volatile private var debugNormalFastPath = true
    internal fun debugNormalFramePath(enabled: Boolean) { if (BuildConfig.DEBUG) debugNormalFastPath = enabled }
    @Volatile private var debugFrameCapOverride = -1
    /** Debug cadence verification only: -1 keeps the mode default. */
    internal fun debugFrameCap(fps: Int) { if (BuildConfig.DEBUG) debugFrameCapOverride = fps }
    @Volatile private var debugRoiDisabled = false
    /** Debug A/B only: run Alpha on the whole eye instead of the ROI window. */
    internal fun debugRoi(enabled: Boolean) { if (BuildConfig.DEBUG) debugRoiDisabled = !enabled }
    @Volatile private var debugZeroCopyDisabled = false
    /** Debug A/B only: CPU readback/upload transport instead of AHardwareBuffer zero-copy. */
    internal fun debugZeroCopy(enabled: Boolean) { if (BuildConfig.DEBUG) debugZeroCopyDisabled = !enabled }
    @Volatile private var debugBorrowDisabled = false
    /** Debug A/B only: copy every captured 8K color instead of holding the MPV slot. */
    internal fun debugBorrowColor(enabled: Boolean) { if (BuildConfig.DEBUG) debugBorrowDisabled = !enabled }
    @Volatile private var debugDirectDisabled = false
    /** Debug A/B only: MPV renders an 8K RGBA copy instead of handing over the decoder's image. */
    internal fun debugDirect(enabled: Boolean) { if (BuildConfig.DEBUG) debugDirectDisabled = !enabled }
    /** Alpha pairs show the decoder's own YUV image (no full-resolution RGBA render); needs borrowing. */
    private fun direct(session: Session) = if (session.alpha) session.vulkan && !debugBorrowDisabled && !debugDirectDisabled &&
        !debugZeroCopyDisabled else normalDirect(session)
    /** Normal playback shows the decoder image as well: no 8K RGBA render or bridge copy per frame.
     * A capped output width keeps MPV's scaled RGBA path, whose size the cap chose. */
    private fun normalDirect(session: Session) = !session.inference && session.normalFastPath && session.host.maxWidth == 0 &&
        !session.host.debugRgba && !debugBorrowDisabled && !debugDirectDisabled && !debugNormalDirectDisabled
    @Volatile private var debugNormalDirectDisabled = false
    /** Debug A/B only: normal playback renders and copies MPV's RGBA color instead of the decoder image. */
    internal fun debugNormalDirect(enabled: Boolean) { if (BuildConfig.DEBUG) debugNormalDirectDisabled = !enabled }
    private var audioFocus: MpvAudioFocus? = null // worker only
    @Volatile private var audioFocusState = "none"

    private inner class Host(val uri: String, val startMs: Int, val hardware: Boolean, val audio: Boolean, val exactStart: Boolean,
                             val maxWidth: Int, val layerRequested: Boolean = false, val alphaLayer: Boolean = false) {
        /** MPV decodes into a compositor layer surface; set when that surface was created. */
        @Volatile var layer = false
        @Volatile var layerSurface: android.view.Surface? = null
        /** Alpha plan B spike (debug: adb shell setprop debug.vrpp.layer.fanout 1): frames pass through an
         * ImageReader on their way to the layer surface. */
        @Volatile var fanout: LayerFanout? = null
        /** GPU copy prototype (debug: setprop debug.vrpp.layer.copy 1): frames drawn into the layer surface. */
        @Volatile var copy: LayerCopy? = null
        /** Where this host's decoder writes for the layer: the GPU copy (Alpha) or the debug hand-off. */
        val frames: LayerFrames? get() = copy ?: fanout
        val debugCopy = BuildConfig.DEBUG && debugProperty("debug.vrpp.layer.copy") == "1"
        val copyFlip = debugProperty("debug.vrpp.layer.copy_flip") != "0"
        val debugFanout = BuildConfig.DEBUG && try {
            Class.forName("android.os.SystemProperties").getMethod("get", String::class.java)
                .invoke(null, "debug.vrpp.layer.fanout") == "1"
        } catch (_: Throwable) { false }
        /** Debug A/B for a whole playback: adb shell setprop debug.vrpp.mpv.normal_direct 0 keeps the RGBA copy path. */
        val debugRgba = BuildConfig.DEBUG && try {
            Class.forName("android.os.SystemProperties").getMethod("get", String::class.java)
                .invoke(null, "debug.vrpp.mpv.normal_direct") == "0"
        } catch (_: Throwable) { false }
        private val openNs = System.nanoTime()
        @Volatile var loadingPhase = "connecting"
        @Volatile var remote = Uri.parse(uri).scheme !in setOf("file", "content")
        fun elapsedMs() = (System.nanoTime() - openNs) / 1_000_000
        val startup = ConcurrentHashMap<String, Double>()
        fun markStartup(stage: String) { startup.putIfAbsent(stage, (System.nanoTime() - openNs) / 1_000_000.0) }
        @Volatile var handle = 0L
        @Volatile var owner: EGLContext? = null
        @Volatile var closing = false
        @Volatile var playing = true
        var speed = 1.0 // synchronized(host), retained across processing revisions
        @Volatile var subtitleDelay = 0.0 // also read by the narration clock
        @Volatile var audioEnabled = audio
        @Volatile var audioVolume = 100.0
        @Volatile var audioMuted = false
        @Volatile var narrationPath = ""
        @Volatile var narrationCa = ""
        @Volatile var interleavePolicy = Mp4InterleavePolicy.Decision()
        var interleaveCheckStarted = false // GL thread only
        @Volatile var interleaveRetry = false
        @Volatile var interleaveRestartMs = startMs
        @Volatile var narration: NarrationController? = null
        fun needsAudio() = (audioEnabled && audioAvailable) || narration?.wantsAudio == true || narration?.wantsPreview == true || narration?.wantsPauseDrain == true
        @Volatile var audioAvailable = audio
        @Volatile var descriptor: ParcelFileDescriptor? = null
        @Volatile var sidecars: List<ParcelFileDescriptor> = emptyList()
        @Volatile var networkLease: String? = null
        @Volatile var subtitleLeases: List<String> = emptyList()
        val subtitleLocations = ConcurrentHashMap<String, String>() // original filename -> current lease
        val subtitleTrackIds = ConcurrentHashMap<String, Int>()
        @Volatile var subtitleFileLoad: SubtitleFileLoad? = null
        @Volatile var subtitleMemoryId = ""
        @Volatile var audioLeases: List<String> = emptyList()
        var cloudCompanionsStarted = false // GL thread; discovery starts after first published frame
        /** Only once MPV no longer reads them. */
        fun closeDescriptors() = synchronized(this) {
            narration?.close(); narration = null
            networkLease?.let(releaseNetwork); networkLease = null
            subtitleLeases.forEach(releaseNetwork); subtitleLeases = emptyList()
            audioLeases.forEach(releaseNetwork); audioLeases = emptyList()
            descriptor?.close(); descriptor = null
            sidecars.forEach { runCatching { it.close() } }; sidecars = emptyList()
        }
        @Volatile var subtitleCommand = 0L
        var nextStatusNs = 0L // GL only
    }
    /** Normal playback never probes the source again. Only a native alternating-seek signal
     * starts the bounded index check; a confirmed decision is consumed by one internal reopen. */
    private fun inspectInterleave(host: Host, status: JSONObject) {
        if (host.closing || stopped || host.interleaveCheckStarted || host.interleavePolicy.sequential ||
            !status.optBoolean("network_interleave_suspect")) return
        host.interleaveCheckStarted = true
        worker.post {
            if (host.closing || stopped) return@post
            val decision = Mp4InterleavePolicy.inspectHttp(host.narrationPath) { host.closing || stopped }
            host.markStartup("interleave_checked_ms")
            if (host.closing || stopped) return@post
            if (decision.sequential) {
                val observed = runCatching { JSONObject(MpvSourceNative.status(host.handle)).optJSONObject("details")
                    ?.optDouble("position_seconds", 0.0) ?: 0.0 }.getOrDefault(0.0)
                host.interleaveRestartMs = maxOf(host.startMs, if (observed.isFinite())
                    (observed * 1000).coerceIn(0.0, Int.MAX_VALUE.toDouble()).toInt() else host.startMs)
                host.interleavePolicy = decision
                host.interleaveRetry = true
            } else refreshPlayback() // A negative/failed check resumes the unchanged policy.
        }
    }

    private data class SubtitleFileLoad(val session: Int, val request: Int, val name: String,
                                        val serial: Long = 0, val location: String = "")
    private data class Lease(val ticket: DecodedFrameGate.Ticket, val pair: JSONObject,
                             val left: ByteBuffer, val right: ByteBuffer,
                             val producer: Long = 0L) // Borrowed MPV slot, released when this lease retires.
    private data class Alpha(val pair: JSONObject, val left: ByteBuffer, val right: ByteBuffer)
    /** depth: realtime 2D->3D on a mono source; its near map rides in the Alpha mask slot. Never with alpha. */
    private class Session(val scope: MediaSessionGate.Scope, val host: Host, private val requestedStereo: Boolean,
                          val profile: String, val alpha: Boolean, val vulkan: Boolean, val normalFastPath: Boolean,
                          private val requestedDepth: Boolean = false, private val requestedTopBottom: Boolean = false) {
        @Volatile var spatial = false // the decoded source fixes its physical packing
        val stereo get() = spatial || requestedStereo
        val depth get() = requestedDepth && !spatial
        val topBottom get() = requestedTopBottom && !spatial
        val id get() = scope.decoderId
        val lock = Any()
        val disposed = AtomicBoolean(false)
        val display = PairDisplayGate(scope, depth = 2)
        val end = MpvEndGate(scope, alpha)
        val normal = FramePairGate(scope)
        @Volatile var model: RvmVideoProbe? = null
        @Volatile var depthModel: DepthVideoProbe? = null
        // 2D->3D view: eye-width fraction of the full parallax and the near value on the screen plane.
        @Volatile var depthShift = 0.035f
        @Volatile var depthConvergence = 0.35f
        val depthViewQueued = AtomicBoolean(false)
        /** Both effects run a model on every presented frame and gate pairs through it. */
        val inference get() = alpha || depth
        /** Alpha plan B: frames fan out from the layer surface to RVM; masks go to the mask layer. */
        val layerAlpha get() = alpha && host.layer && host.frames != null
        var nextFanoutNs = 0L // GL thread
        var layerMasks = 0L // GL thread
        var debugTicks = 0L // GL thread
        var audioDelay = 0.0 // seconds MPV delays the audio by: the layer's measured hold for masks
        /** The fanned-out frame RVM works on (capture time, ns): one at a time, so no frame waits in a queue
         * while the held video waits for its mask. 0 when none. */
        var maskInFlightNs = 0L // GL thread
        var maskLatencyMs = 0.0 // GL thread: capture -> mask on the layer, smoothed
        val captureNs = HashMap<Long, Long>() // GL thread: capture time of each Alpha layer token
        /** GPU copy: finished masks waiting for their frame to be drawn (token to pair), oldest first. */
        val pendingMasks = ArrayDeque<Pair<Long, JSONObject>>() // GL thread
        fun accepts(pair: JSONObject) = if (alpha) model?.acceptsPair(pair) == true else depthModel?.acceptsPair(pair) == true
        fun presented(pair: JSONObject) = if (alpha) model?.presented(pair) == true else depthModel?.presented(pair) == true
        @Volatile var roi: RoiController? = null // Alpha only; created with the renderer on the GL thread.
        val roiEnabled = alpha
        var zeroCopy = false // GL thread: the bridge stages inputs into AHardwareBuffers shared with MNN
        var borrow = false // GL thread: pairs show the MPV slot itself; no 8K copy per captured frame
        var copyingProducer = 0L // GL thread: producer lease held by the slot being staged
        var renderer = 0L // GL only under lock
        var owner: EGLContext? = null
        var copying: Pair<DecodedFrameGate.Ticket, Long>? = null
        var copyingPair: JSONObject? = null
        var pendingSource: JSONObject? = null // Retain producer lease until a consumer slot accepts the copy.
        var deferredCopies = 0L
        val leases = HashMap<Long, Lease>()
        val buffers = HashMap<Int, Pair<ByteBuffer, ByteBuffer>>()
        val scoutBuffers = HashMap<Int, Pair<ByteBuffer, ByteBuffer>>()
        val alphaUploads = HashMap<Long, Alpha>()
        val pairs = HashMap<Long, JSONObject>()
        val retiring = HashSet<Long>()
        var sourceEpoch = 0L
        var latestPair = ""
        var firstPair = false
        var captured = 0L
        var ownerDraws = 0L
        var uniquePostDrawFrames = 0L
        var lastPostDrawFrame = -1L
        var lastPostDrawEpoch = -1L
        var drawnToken = 0L
        val dims = (if (depth) DepthNative.PROFILE else profile).split('x').map { it.toInt() }
        val opaque by lazy {
            fun plane() = ByteBuffer.allocateDirect(dims[0]*dims[1]*4).order(ByteOrder.LITTLE_ENDIAN).also {
                for (i in 0 until dims[0]*dims[1]) it.putFloat(i*4, 1f)
            }
            plane() to plane()
        }
    }
    fun supported() = !stopped && MpvSourceNative.supported()
    /** User setting: decoded color width cap for sources opened from now on (0 = source size). */
    @Volatile var outputWidthCap = 0
    /** User setting: Alpha passthrough reads the source at this rate, one RVM pair per presented frame. */
    @Volatile private var alphaFps = RVM_VIDEO_FPS
    /** The player's Alpha edge: mask values remapped from [low, high] to [0, 1] (0, 1: unchanged). */
    @Volatile private var alphaEdge = floatArrayOf(0f, 1f)
    fun setAlphaEdge(low: Double, high: Double): Boolean {
        if (!low.isFinite() || !high.isFinite() || low < 0.0 || high > 1.0 || high - low < 0.01) return false
        alphaEdge = floatArrayOf(low.toFloat(), high.toFloat())
        return true
    }
    /** MPV's cadence cap is atomic and resets its decimation on change, so a running session follows at once. */
    fun setAlphaFps(fps: Int): Boolean {
        if (fps !in ALPHA_FPS_RANGE) return false
        alphaFps = fps
        sessions.values.filter { it.alpha && active(it) }.forEach { session ->
            val handle = session.host.handle
            if (handle > 0) runCatching { MpvSourceNative.setFrameCap(handle, frameCap(session)) }
        }
        return true
    }
    private fun frameCap(session: Session) = if (BuildConfig.DEBUG && debugFrameCapOverride >= 0) debugFrameCapOverride
        // 2D->3D shows every frame with the latest depth map; only Alpha needs one result per frame.
        else if (session.alpha && !session.layerAlpha) alphaFps else 0
    private fun active(session: Session) = !stopped && !session.disposed.get() && gate.accepts(session.id)
    private fun event(name: String, session: Session, json: JSONObject) {
        json.put("session_id", session.id).put("logical_session_id", session.scope.logicalSessionId)
            .put("generation", session.scope.generation).put("backend", "Android_libmpv")
        emit(name, session.id, json.toString())
    }
    @Synchronized fun open(uri: String, startMs: Int, stereo: Boolean, profile: String,
                           alpha: Boolean, vulkan: Boolean, hardware: Boolean = true, audio: Boolean = true,
                           depth: Boolean = false, topBottom: Boolean = false, exactSeek: Boolean = false, layer: Boolean = false,
                           networkInterleaveCompat: Boolean = false): Int {
        if (!supported() || sessions.size >= 2 || startMs < 0 || profile !in RvmProfiles.keys || (depth && (alpha || stereo)) ||
            Uri.parse(uri).scheme !in setOf("content", "file", "usb", "smb", "cloud", "medialib", "dlna", "http", "https")) return -1
        val id = gate.begin(); if (id <= 0) return -1
        // Compositor layers carry normal playback; Alpha only in the plan B prototype (its mask becomes a
        // compositor mask layer). 2D->3D composes in Godot's shader.
        val alphaLayer = alpha && layerAlpha()
        val host = Host(uri, startMs, hardware, audio, exactSeek, outputWidthCap, layer && hardware && !depth && (!alpha || alphaLayer),
            alphaLayer && layer && hardware)
        host.interleavePolicy = Mp4InterleavePolicy.Decision(networkInterleaveCompat)
        if (host.alphaLayer) layerMask = "0 0 0"
        val session = Session(gate.current(id) ?: return -1, host, stereo, profile, alpha, vulkan, debugNormalFastPath, depth,
            stereo && topBottom)
        sessions[id] = session; hosts.add(host)
        sessions.values.filter { it.id != id }.forEach { dispose(it, true) }
        prepareModel(session)
        worker.post {
            try {
                host.markStartup("worker_started_ms")
                if (host.closing || stopped) return@post
                val app = context() ?: error("Activity unavailable")
                val tlsCaFile = MpvTlsTrust.prepare(app)
                // Keep Host.uri (history, modes and companions) on the shortcut, resolving only the input.
                val resolved = resolveNetwork(uri)
                val source = Uri.parse(resolved)
                host.remote = host.remote || source.scheme in setOf("http", "https", "smb", "cloud", "medialib")
                host.loadingPhase = "reading"
                if (resolved != uri || source.scheme in setOf("medialib", "cloud", "smb")) host.networkLease = resolved
                val path = if (source.scheme == "file") source.path ?: error("Local file path unavailable")
                else if (source.scheme in setOf("http", "https")) resolved else {
                    val fd = app.contentResolver.openFileDescriptor(source, "r") ?: error("Local document descriptor unavailable")
                    host.descriptor = fd
                    "fd://${fd.fd}"
                }
                host.markStartup("source_resolved_ms")
                val iso = Uri.parse(path).path.orEmpty().lowercase().endsWith(".iso") ||
                    source.path.orEmpty().lowercase().endsWith(".iso") ||
                    (source.scheme == "content" && app.contentResolver.query(source,
                        arrayOf(android.provider.OpenableColumns.DISPLAY_NAME), null, null, null)?.use {
                            it.moveToFirst() && it.getString(0).orEmpty().lowercase().endsWith(".iso")
                        } == true)
                if (iso) host.loadingPhase = "reading_disc"
                val disc = if (iso) MpvSourceNative.probeIso(path) else null
                host.loadingPhase = "preparing"
                val nativePath = if (iso && path.startsWith("fd://")) "/proc/self/fd/${path.removePrefix("fd://")}" else path
                host.narrationPath = nativePath; host.narrationCa = tlsCaFile
                val surfaceWidth = disc?.get(0)?.toInt() ?: LAYER_SURFACE_SIZE
                val surfaceHeight = disc?.get(1)?.toInt() ?: LAYER_SURFACE_SIZE
                // Extra audio is optional: a failed lookup plays the video without it.
                val deferCloud = Uri.parse(uri).scheme == "cloud"
                val extra = if (audio && !deferCloud) sidecarAudio(uri) else emptyList()
                host.markStartup("audio_sidecars_resolved_ms")
                host.sidecars = extra.mapNotNull { it.descriptor }
                host.audioLeases = extra.filter { it.location.startsWith("http://127.0.0.1:") }.map { it.location }
                val captions = if (deferCloud) emptyList() else sidecarSubtitles(uri)
                host.subtitleMemoryId = runCatching { subtitleIdentity(uri) }.getOrDefault("")
                host.markStartup("subtitle_sidecars_resolved_ms")
                host.subtitleLeases = captions.map { it.location }
                if (SidecarSubtitles.supportsDirectory(uri)) captions.forEach { host.subtitleLocations[it.title] = it.location }
                if (host.closing || stopped) { host.closeDescriptors(); return@post }
                render(Runnable {
                    if (host.closing || stopped) return@Runnable
                    try {
                        host.owner = EGL14.eglGetCurrentContext()
                        host.markStartup("native_create_started_ms")
                        if (host.layerRequested) {
                            host.layerSurface = runCatching { VideoLayerNative.createSurface(surfaceWidth, surfaceHeight) }
                                .onFailure { android.util.Log.w("QuestPlayer", "Video layer surface unavailable", it) }.getOrNull()
                            host.layer = host.layerSurface != null
                            if (host.layer) currentLayerSurface = host.layerSurface
                            // Alpha on the layer always copies: the hand-off made the decoder allocate a buffer per frame.
                            if (host.layer && (host.debugCopy || host.alphaLayer)) host.copy = runCatching {
                                LayerCopy(host.layerSurface!!, surfaceWidth, surfaceHeight, host.copyFlip, holdable = host.alphaLayer,
                                    heldLimit = debugInt("debug.vrpp.layer.held", 8).coerceIn(2, 12),
                                    // The output resolution setting caps the compositor window as it caps the RGBA frames.
                                    maxOutputWidth = debugInt("debug.vrpp.layer.window_max", host.maxWidth))
                                    .also { it.keepFrames = host.alphaLayer }
                            }.onFailure { android.util.Log.w("QuestPlayer", "Layer copy unavailable", it) }.getOrNull()
                            if (host.layer && host.copy == null && host.debugFanout) host.fanout = runCatching {
                                LayerFanout(host.layerSurface!!, surfaceWidth, surfaceHeight, holdable = host.alphaLayer).also { it.keepFrames = host.alphaLayer }
                            }.onFailure { android.util.Log.w("QuestPlayer", "Layer fan-out unavailable", it) }.getOrNull()
                        }
                        host.handle = MpvSourceNative.create(app, nativePath, startMs, hardware, audio, host.maxWidth,
                            extra.flatMap { listOf(it.location, it.title) }.toTypedArray(),
                            captions.flatMap { listOf(it.location, it.title) }.toTypedArray(), host.exactStart,
                            if (host.layer) host.copy?.surface ?: host.fanout?.surface ?: host.layerSurface else null, disc?.get(3) == 1L, surfaceWidth, surfaceHeight, iso, tlsCaFile,
                            host.interleavePolicy.sequential)
                        check(host.handle > 0)
                        host.markStartup("native_created_ms")
                        host.loadingPhase = "reading"
                        synchronized(host) {
                            check(MpvSourceNative.setSpeed(host.handle, host.speed))
                            val serial = MpvSourceNative.setSubtitleDelay(host.handle, host.subtitleDelay)
                            check(serial > 0)
                            host.subtitleCommand = maxOf(host.subtitleCommand, serial)
                        }
                        MpvSourceNative.setFrameCap(host.handle, frameCap(session))
                        MpvSourceNative.setDirect(host.handle, direct(session))
                        // Native creation stays paused until focus policy has
                        // run off the Godot GL thread.
                        refreshPlayback()
                    } catch (failure: Throwable) { fail(session, "MPV_SOURCE_START_FAILED", failure) }
                })
            } catch (failure: Throwable) { fail(session, (failure as? StrmFailure)?.code ?: "MPV_LOCAL_SOURCE_FAILED", failure) }
        }
        return id
    }
    /** Optional cloud discovery cannot hold up the first frame or the source worker. */
    private fun discoverCloudCompanions(host: Host) {
        if (host.cloudCompanionsStarted || host.closing || stopped || Uri.parse(host.uri).scheme != "cloud") return
        host.cloudCompanionsStarted = true
        companionWorker.execute {
            if (host.closing || stopped) return@execute
            val audio = if (host.audio) runCatching { sidecarAudio(host.uri) }.getOrDefault(emptyList()) else emptyList()
            val captions = if (!host.closing && !stopped) runCatching { sidecarSubtitles(host.uri) }.getOrDefault(emptyList()) else emptyList()
            synchronized(host) {
                val freshCaptions = captions.filter { !host.subtitleLocations.containsKey(it.title) && host.subtitleFileLoad?.name != it.title }
                val accepted = !host.closing && !stopped && host.handle > 0 && runCatching {
                    MpvSourceNative.addCompanions(host.handle, audio.flatMap { listOf(it.location, it.title) }.toTypedArray(),
                        freshCaptions.flatMap { listOf(it.location, it.title) }.toTypedArray())
                }.getOrDefault(false)
                if (accepted) {
                    host.sidecars = host.sidecars + audio.mapNotNull { it.descriptor }
                    host.audioLeases = host.audioLeases + audio.filter { it.location.startsWith("http://127.0.0.1:") }.map { it.location }
                    host.subtitleLeases = host.subtitleLeases + freshCaptions.map { it.location }
                    freshCaptions.forEach { host.subtitleLocations[it.title] = it.location }
                    host.markStartup("cloud_companions_queued_ms")
                } else {
                    audio.forEach { it.descriptor?.close(); if (it.location.startsWith("http://127.0.0.1:")) releaseNetwork(it.location) }
                    freshCaptions.forEach { releaseNetwork(it.location) }
                }
                captions.filter { it !in freshCaptions }.forEach { releaseNetwork(it.location) }
            }
        }
    }

    /** A nonblocking snapshot, also available while source resolution/ISO probing is on the worker. */
    fun loadingStatus(id: Int): String {
        val session = sessions[id]?.takeIf(::active) ?: return ""
        val host = session.host
        val progress = host.networkLease?.let(networkProgress)
        return JSONObject().put("remote", host.remote).put("phase", host.loadingPhase)
            .put("elapsed_ms", host.elapsedMs()).apply {
                if (progress != null) put("bytes", progress.bytes).put("bytes_per_second", progress.bytesPerSecond)
            }.toString()
    }
    private fun prepareModel(session: Session) {
        if (session.depth) {
            // Depth never ends the session: until (or unless) the model runs, frames show in 2D.
            session.depthModel = DepthVideoProbe(session.scope, context, { token -> release(session, token) },
                {
                    if (active(session)) {
                        // The first paused color can arrive before depth is ready and skip input
                        // staging. Re-render that same frame now; do not resume playback or seek.
                        render(Runnable {
                            if (active(session) && session.host.handle > 0 && !session.host.layer)
                                MpvSourceNative.requestFrame(session.host.handle)
                        })
                        event("mpv_state", session, JSONObject().put("state", "effect_ready"))
                    }
                },
                { pair, left, right -> deliver(session, pair, left, right) },
                {
                    // Depth's first result is consumed by the next color capture. A paused source
                    // has none; redraw it once with the map. wantsInput(frameId) prevents a loop.
                    render(Runnable {
                        if (active(session) && session.host.handle > 0 && !session.host.layer && !session.host.playing)
                            MpvSourceNative.requestFrame(session.host.handle)
                    })
                })
            session.depthModel!!.start()
            return
        }
        if (!session.alpha) return
        session.model = RvmVideoProbe(session.scope, session.profile, session.vulkan, context, worker,
            { token -> release(session, token) },
            { if (active(session)) event("mpv_state", session, JSONObject().put("state", "effect_ready")) },
            { pair, left, right -> deliver(session, pair, left, right) },
            { failure -> fail(session, "MPV_RVM_FAILED", failure) }, diagnostic = false, roi = { session.roi })
        session.model!!.start()
    }
    /** Model result -> GL upload into the pair's mask. True hands the color lease to the uploader. */
    private fun deliver(session: Session, pair: JSONObject, left: ByteBuffer, right: ByteBuffer): Boolean {
        if (!active(session)) return false
        render(Runnable {
            synchronized(session.lock) {
                if (!active(session)) { retire(session, pair.getLong("slot_token")); return@synchronized }
                try { upload(session, pair, left, right) }
                catch (failure: Throwable) { fail(session, "MPV_ALPHA_UPLOAD_FAILED", failure) }
            }
        })
        return true
    }
    /** Returns a new processing generation without reopening the MPV media/audio core. */
    @Synchronized fun revise(id: Int, stereo: Boolean, alpha: Boolean, profile: String, positionMs: Int = -1,
                             depth: Boolean = false, topBottom: Boolean = false, exactSeek: Boolean = false): Int {
        val old = sessions[id] ?: return -1
        if (!active(old) || sessions.size >= 2 || profile !in RvmProfiles.keys || (depth && (alpha || stereo))) return -1
        val host = old.host
        // A layer host has no frame images for the shader effects; the owner reopens it instead. The Alpha
        // plan B prototype host fans its frames out to RVM, so it keeps the layer for Alpha.
        if (host.layer && (depth || (alpha && !host.alphaLayer))) return -1
        if (positionMs >= 0 && (host.handle <= 0 || !MpvSourceNative.seek(host.handle, positionMs.toLong(), exactSeek))) return -1
        if (positionMs >= 0) host.narration?.transportChanged()
        val next = gate.replace(id); if (next <= 0) return -1
        val session = Session(gate.current(next) ?: return -1, host, stereo, profile, alpha, old.vulkan, old.normalFastPath, depth,
            stereo && topBottom)
        // A decoder image is exported once: redrawing the current frame for a new direct session yields
        // nothing to show. Decode that frame again instead (an exact seek to its own timestamp).
        val redecodeMs = if (positionMs < 0 && !host.layer && direct(old) && direct(session))
            synchronized(old.lock) { old.pairs[old.drawnToken]?.optLong("pts_us", -1L) ?: -1L }.let { if (it >= 0) it / 1000 else -1L }
        else -1L
        sessions[next] = session; dispose(old, false); prepareModel(session)
        if (host.handle > 0) MpvSourceNative.setFrameCap(host.handle, frameCap(session))
        if (host.handle > 0) MpvSourceNative.setDirect(host.handle, direct(session))
        if (host.handle > 0 && positionMs < 0 && (redecodeMs < 0 || !MpvSourceNative.seek(host.handle, redecodeMs, true)))
            MpvSourceNative.requestFrame(host.handle)
        return next
    }
    fun setPlaying(id: Int, playing: Boolean) {
        val session = sessions[id] ?: return
        if (!active(session)) return
        session.host.playing = playing
        if (!playing) session.host.narration?.pauseWithVideo()
        if (!playing && session.host.handle > 0) MpvSourceNative.setPlaying(session.host.handle, false)
        refreshPlayback(explicit = playing)
    }
    fun setSpeed(id: Int, speed: Double): Boolean {
        if (!speed.isFinite() || speed !in 0.25..3.0) return false
        val session = sessions[id] ?: return false
        synchronized(session.host) {
            if (!active(session) || session.host.closing) return false
            if (session.host.handle > 0 && !MpvSourceNative.setSpeed(session.host.handle, speed)) return false
            if(session.host.speed!=speed)session.host.narration?.transportChanged()
            session.host.speed = speed
            return true
        }
    }
    fun setAudio(id: Int, trackId: Int, volume: Double, muted: Boolean): Boolean {
        val session = sessions[id] ?: return false
        if (!active(session) || session.host.handle <= 0) return false
        if (trackId != 0 && !session.host.audioEnabled) MpvSourceNative.setPlaying(session.host.handle, false)
        val accepted = MpvSourceNative.setAudio(session.host.handle, trackId, volume, muted)
        if (accepted) { session.host.audioEnabled = trackId != 0; session.host.audioVolume = volume; session.host.audioMuted = muted }
        refreshPlayback(explicit = accepted && trackId != 0)
        return accepted
    }
    fun setNarration(id: Int, json: String): Boolean {
        if (!BuildConfig.DEBUG || !NarrationPolicy.FEATURE_ENABLED) return false
        val session = sessions[id] ?: return false
        if (!active(session) || session.host.closing) return false
        val host = session.host
        val controller = synchronized(host) {
            host.narration ?: NarrationController(context, {
                if (host.closing || stopped || host.handle <= 0) null else NarrationController.Source(host.handle,
                    host.narrationPath, host.narrationCa, foreground, host.audioVolume, host.audioMuted, host.subtitleDelay, host.subtitleCommand,host.playing)
            }, { value -> if (host.handle > 0 && !host.closing) MpvSourceNative.setNarrationGain(host.handle, value) },
                { refreshPlayback() }).also { host.narration=it }
        }
        val accepted = controller.configure(json)
        if (accepted) refreshPlayback(explicit = controller.enabled)
        return accepted
    }
    /** Explicit Debug fixture tests only; no user-media details or subtitle text. */
    fun narrationTestStatus(id: Int): JSONObject {
        check(BuildConfig.DEBUG)
        val session=sessions[id] ?: error("No active fixture")
        val app=context() ?: error("Unavailable")
        val fixture=java.io.File(Uri.parse(session.host.uri).path.orEmpty()).canonicalFile
        check(fixture.parentFile==java.io.File(app.filesDir,"fixtures").canonicalFile && fixture.name in setOf("mp06_text_subtitles.mkv","mp08_8k_long.mp4","mp08_4k.mp4"))
        val native=JSONObject(MpvSourceNative.status(session.host.handle));val details=native.optJSONObject("details") ?: JSONObject()
        val tracks=org.json.JSONArray()
        details.optJSONArray("subtitle_tracks")?.let { list -> for(i in 0 until list.length()) {
            val item=list.getJSONObject(i);val title=item.optString("title")
            tracks.put(JSONObject().put("id",item.optInt("id")).put("codec",item.optString("codec"))
                .put("language",item.optString("language")).put("stream_index",item.optInt("stream_index",-1))
                .put("fixture_language",if(title.endsWith(".narration-zh.srt"))"zh" else if(title.endsWith(".narration-en.srt"))"en" else ""))
        } }
        return (session.host.narration?.status() ?: JSONObject().put("state","off"))
            .put("session_id",id).put("focus",audioFocusState).put("base_volume",session.host.audioVolume)
            .put("effective_volume",details.optString("volume")).put("muted",session.host.audioMuted)
            .put("position",details.optString("position_seconds")).put("paused",details.optString("paused"))
            .put("decoder_drops",details.optString("decoder_frame_drop_count")).put("vo_drops",details.optString("vo_frame_drop_count"))
            .put("video_frame_number",details.optString("estimated_frame_number")).put("avsync_seconds",details.optString("avsync_seconds"))
            .put("paused_for_cache",details.optString("paused_for_cache")).put("audio_track",details.optString("audio_track_id"))
            .put("video_pts_us",details.optLong("video_pts_us")).put("audio_pts_us",details.optLong("audio_pts_us"))
            .put("audio_observed_monotonic_ns",details.optLong("audio_observed_monotonic_ns")).put("audio_delay_seconds",details.optString("audio_delay_seconds"))
            .put("seeks_started",native.optLong("seeks_started")).put("seeks_completed",native.optLong("seeks_completed"))
            .put("tracks",tracks).put("subtitle_track",details.optJSONObject("subtitle")?.optString("track_id"))
    }
    fun setSubtitle(id: Int, trackId: Int): Boolean {
        val session = sessions[id] ?: return false
        if (!active(session) || session.host.handle <= 0 || trackId < -1) return false
        val serial = MpvSourceNative.setSubtitle(session.host.handle, trackId)
        if (serial <= 0) return false
        synchronized(session.host) {
            session.host.subtitleCommand = maxOf(session.host.subtitleCommand, serial)
        }
        session.host.narration?.timelineChanged()
        return true
    }
    fun listSubtitleFiles(id: Int, request: Int): Boolean {
        val session = sessions[id] ?: return false
        if (!active(session) || request <= 0 || !SidecarSubtitles.supportsDirectory(session.host.uri)) return false
        subtitleWorker.execute {
            if (!active(session)) return@execute
            val result = try {
                JSONObject().put("state", "ready").put("files", JSONArray(subtitleFiles(session.host.uri)))
            } catch (error: Exception) {
                JSONObject().put("state", "error").put("error", if (error is SecurityException || error is java.nio.file.AccessDeniedException)
                    "Subtitle folder access denied" else "Unable to list subtitle files")
            }
            if (active(session)) event("mpv_subtitle_files", session, result.put("operation", "list").put("request", request))
        }
        return true
    }
    fun loadSubtitleFile(id: Int, request: Int, name: String): Boolean {
        val session = sessions[id] ?: return false
        val host = session.host
        synchronized(host) {
            if (!active(session) || host.handle <= 0 || request <= 0 || host.subtitleFileLoad != null ||
                !SidecarSubtitles.supportsDirectory(host.uri) || !SidecarSubtitles.supportedFile(name)) return false
            host.subtitleFileLoad = SubtitleFileLoad(id, request, name)
        }
        subtitleWorker.execute {
            var location = ""
            try {
                if (!active(session)) {
                    synchronized(host) { if (host.subtitleFileLoad?.session == id) host.subtitleFileLoad = null }
                    return@execute
                }
                // A previously loaded file can be selected without another download or sub-add.
                val existing = host.subtitleTrackIds[name]
                if (existing != null) {
                    synchronized(host) { host.subtitleFileLoad = null }
                    if (active(session)) event("mpv_subtitle_files", session, JSONObject().put("operation", "load")
                        .put("request", request).put("file", name).put("state", "ready").put("track_id", existing))
                    return@execute
                }
                location = openSubtitleFile(host.uri, name).location
                synchronized(host) {
                    if (!active(session) || host.closing || host.handle <= 0) {
                        releaseNetwork(location); host.subtitleFileLoad = null; return@execute
                    }
                    val serial = MpvSourceNative.addSubtitleFile(host.handle, location, name)
                    check(serial > 0)
                    host.subtitleLocations[name] = location
                    host.subtitleLeases = host.subtitleLeases + location
                    host.subtitleFileLoad = SubtitleFileLoad(id, request, name, serial, location)
                }
            } catch (_: Exception) {
                if (location.isNotEmpty()) releaseNetwork(location)
                synchronized(host) { host.subtitleFileLoad = null }
                if (active(session)) event("mpv_subtitle_files", session, JSONObject().put("operation", "load")
                    .put("request", request).put("file", name).put("state", "error").put("error", "Unable to load subtitle"))
            }
        }
        return true
    }
    /** The native load is unselected. Publish success only after its actual track is observable. */
    private fun subtitleFileResult(session: Session, details: JSONObject?) {
        val host = session.host
        val tracks = details?.optJSONArray("subtitle_tracks") ?: JSONArray()
        for (i in 0 until tracks.length()) {
            val track = tracks.getJSONObject(i)
            val name = host.subtitleLocations.entries.firstOrNull { it.value == track.optString("filename") }?.key ?: continue
            track.put("source_file", name)
            if (track.optString("codec") in setOf("subrip", "ass", "ssa", "webvtt", "sami", "microdvd", "subviewer", "text", "ttml"))
                host.subtitleTrackIds[name] = track.getInt("id")
        }
        val pending = host.subtitleFileLoad ?: return
        if (pending.serial <= 0) return
        val raw = MpvSourceNative.subtitleFileStatus(host.handle, pending.serial)
        if (raw.isEmpty()) return
        val track = JSONObject(raw).optInt("track_id")
        if (track > 0 && (0 until tracks.length()).none { tracks.getJSONObject(it).optInt("id") == track }) return
        synchronized(host) {
            if (host.subtitleFileLoad !== pending) return
            host.subtitleFileLoad = null
            if (track <= 0) {
                host.subtitleLocations.remove(pending.name, pending.location)
                host.subtitleLeases = host.subtitleLeases - pending.location
                releaseNetwork(pending.location)
            }
        }
        if (pending.session == session.id && active(session)) event("mpv_subtitle_files", session, JSONObject()
            .put("operation", "load").put("request", pending.request).put("file", pending.name)
            .put("state", if (track > 0) "ready" else "error").put("track_id", track)
            .put("error", if (track > 0) "" else "Unable to load subtitle"))
    }
    fun subtitles(id: Int, afterSequence: Long): String {
        val session = sessions[id] ?: return ""
        if (!active(session) || session.host.handle <= 0 || afterSequence < 0) return ""
        val text = MpvSourceNative.subtitleStatus(session.host.handle, afterSequence)
        if (text.isEmpty() || !active(session)) return ""
        return JSONObject(text).put("session_id", session.id).put("generation", session.scope.generation)
            .put("mpv_source_handle", session.host.handle).put("required_command_id", session.host.subtitleCommand).toString()
    }
    fun setSubtitleDelay(id: Int, seconds: Double): Boolean {
        val session = sessions[id] ?: return false
        if (!seconds.isFinite() || kotlin.math.abs(seconds) > 10.0) return false
        synchronized(session.host) {
            if (!active(session) || session.host.closing) return false
            if (session.host.handle > 0) {
                val serial = MpvSourceNative.setSubtitleDelay(session.host.handle, seconds)
                if (serial <= 0) return false
                session.host.subtitleCommand = maxOf(session.host.subtitleCommand, serial)
                session.host.narration?.timelineChanged()
            }
            // Opening can still be resolving the source on the worker. Apply this
            // value when the native handle is created, before first playback.
            session.host.subtitleDelay = seconds
        }
        return true
    }
    fun subtitleBitmap(id: Int, version: Long): ByteArray {
        val session = sessions[id] ?: return ByteArray(0)
        if (!active(session) || session.host.handle <= 0 || version <= 0) return ByteArray(0)
        val pixels = MpvSourceNative.subtitleBitmap(session.host.handle, version)
        return if (active(session)) pixels else ByteArray(0)
    }
    private fun refreshPlayback(explicit: Boolean = false) {
        worker.post {
            val needsAudio = !stopped && foreground && hosts.any {
                !it.closing && it.handle > 0 && (it.playing || it.narration?.wantsPreview == true || it.narration?.wantsPauseDrain == true) && it.needsAudio()
            }
            if (needsAudio && audioFocus == null) context()?.let { app ->
                audioFocus = MpvAudioFocus(app) { change ->
                    // Stop as soon as loss arrives; waiting for RVM work to
                    // finish must not keep audio playing over another app.
                    if (change != MpvAudioFocusGate.Change.GAIN) hosts.filter { !stopped && !it.closing && it.needsAudio() }.forEach {
                        if (change == MpvAudioFocusGate.Change.LOSS) it.playing = false
                        it.narration?.allow(false)
                        if (it.handle > 0) MpvSourceNative.setPlaying(it.handle, false)
                    }
                    if (change == MpvAudioFocusGate.Change.LOSS) sessions.values.filter { active(it) && it.host.needsAudio() }.forEach {
                        event("mpv_state", it, JSONObject().put("state", "paused").put("audio_focus_change", "loss"))
                    }
                    refreshPlayback()
                }
            }
            val granted = if (needsAudio) audioFocus?.acquire(explicit) == true else {
                audioFocus?.release(); true
            }
            audioFocusState = if (needsAudio) audioFocus?.state() ?: "unavailable" else "none"
            hosts.forEach { host -> if (!stopped && !host.closing && host.handle > 0) {
                val allowed = foreground && host.playing && host.narration?.holdsPlayback != true && (!host.needsAudio() || granted)
                host.narration?.allow(foreground && (host.playing || host.narration?.wantsPreview == true || host.narration?.wantsPauseDrain == true) && (!host.needsAudio() || granted))
                MpvSourceNative.setPlaying(host.handle, allowed)
            } }
        }
    }
    fun draw() {
        for (session in sessions.values) synchronized(session.lock) {
            try {
                if (session.disposed.get()) { cleanup(session); return@synchronized }
                if (!active(session) || session.host.handle == 0L) return@synchronized
                check(session.host.owner == EGL14.eglGetCurrentContext()) { "MPV owner GL context changed" }
                if (session.renderer > 0 || session.host.layer) {
                    if (session.renderer > 0) { pollRetirements(session); finishUploads(session) }
                    if (session.display.drawn(session.drawnToken)) {
                        session.ownerDraws++
                        session.pairs[session.drawnToken]?.let { pair ->
                            val frame = pair.getLong("frame_id")
                            val epoch = pair.getLong("source_epoch")
                            if (frame != session.lastPostDrawFrame || epoch != session.lastPostDrawEpoch) {
                                session.uniquePostDrawFrames++
                                session.lastPostDrawFrame = frame
                                session.lastPostDrawEpoch = epoch
                            }
                            // A layer identity's picture needs no inference of its own (Alpha plan B masks it on the layer).
                            session.end.postDraw(identity(pair), pair.getLong("source_epoch"),
                                pair.getBoolean("inference_ran") || pair.optString("color_target") == "layer")
                        }
                    }
                }
                finishCopy(session)
                if (!session.inference && session.normalFastPath) finishUploads(session)
                if (session.copying != null) return@synchronized
                // Open/revise starts MPV paused until Godot displays the first complete pair.
                // Taking that frame before RVM is ready drops it in drain(); paused MPV then
                // has no new frame to offer and the Alpha transition never completes.
                val effectReady = !session.alpha || session.model?.isReady() == true
                if (effectReady) {
                    val source = session.pendingSource ?: MpvSourceNative.acquire(session.host.handle)
                        .takeIf { it.isNotEmpty() }?.let { JSONObject(it) }
                    session.pendingSource = null
                    if (source != null && !capture(session, source)) {
                        session.pendingSource = source
                        session.deferredCopies++
                    }
                }
                if (BuildConfig.DEBUG && session.layerAlpha && session.debugTicks++ % 144 == 0L)
                    android.util.Log.i("QuestPlayer", "layer alpha draw effectReady=$effectReady copying=${session.copying != null} " +
                        "pending=${session.pendingSource != null} model=${session.model?.isReady()} captured=${session.captured} masks=${session.layerMasks} " +
                        "playing=${session.host.playing} uploads=${session.alphaUploads.size}")
                // Alpha turned off in place: frames go on unheld (and the audio delay returns to zero below).
                session.host.frames?.hold = session.layerAlpha
                session.host.copy?.maxFps = if (session.layerAlpha) alphaFps else 0
                if (session.layerAlpha) session.host.frames?.releaseStale(HOLD_LIMIT_MS)
                if (session.layerAlpha) showPresentedMasks(session)
                if (session.layerAlpha && session.copying == null && session.maskInFlightNs == 0L && session.model?.isReady() == true)
                    captureFanout(session)
                // A capture whose mask never comes (dropped by the model) frees the slot after a while.
                if (session.maskInFlightNs != 0L && System.nanoTime() - session.maskInFlightNs > 1_000_000_000L) session.maskInFlightNs = 0L
                if (System.nanoTime() >= session.host.nextStatusNs) {
                    session.host.nextStatusNs = System.nanoTime()+250_000_000L
                    val status = JSONObject(MpvSourceNative.status(session.host.handle))
                    inspectInterleave(session.host, status)
                    if (BuildConfig.DEBUG && session.renderer > 0)
                        status.put("bridge", JSONObject(RenderBridgeNative.stats(session.renderer)))
                    status.put("normal_fast_path", !session.inference && session.normalFastPath)
                        .put("layer_active", session.host.layer)
                        .put("rvm_video_fps_cap", frameCap(session))
                    session.host.frames?.let { fanout ->
                        // Audio waits as long as the frames wait for their masks (changes under 20 ms are kept).
                        val delay = if (session.layerAlpha) Math.round(fanout.holdMs) / 1000.0 else 0.0
                        if (Math.abs(delay - session.audioDelay) >= 0.02 && MpvSourceNative.setAudioDelay(session.host.handle, delay))
                            session.audioDelay = delay
                        status.put(if (fanout is LayerCopy) "layer_copy" else "layer_fanout",
                            fanout.stats().put("masks", session.layerMasks).put("audio_delay", session.audioDelay)
                            .put("mask_latency_ms", session.maskLatencyMs))
                    }
                    session.roi?.status()?.forEach { (key, value) -> status.put(key, if (value is List<*>) JSONArray(value) else value) }
                    session.model?.stats()?.forEach { (key, value) -> status.put(key, value) }
                    session.depthModel?.stats()?.forEach { (key, value) -> status.put(key, value) }
                    val details = status.optJSONObject("details")
                    if (status.optJSONObject("startup_native")?.optLong("first_published_us", -1)?.let { it >= 0 } == true)
                        discoverCloudCompanions(session.host)
                    if (session.host.subtitleMemoryId.isNotEmpty()) status.put("subtitle_memory_id", session.host.subtitleMemoryId)
                    subtitleFileResult(session, details)
                    if (!details?.optString("codec").isNullOrEmpty()) {
                        val available = (details?.optJSONArray("audio_tracks")?.length() ?: 0) > 0 && session.host.audio
                        if (available != session.host.audioAvailable) {
                            session.host.audioAvailable = available; refreshPlayback()
                        }
                    }
                    val terminal = if (status.optBoolean("eof_source_resolved")) status.optJSONObject("eof_source_ticket") else null
                    session.end.observe(terminal?.let { MpvEndGate.Source(it.getLong("source_epoch"), it.getLong("frame_id"), it.getLong("pts_us")) })
                    event("mpv_state", session, status.put("alpha_requested", session.alpha).put("depth_requested", session.depth)
                        .put("startup_bridge", JSONObject(session.host.startup as Map<*, *>))
                        .put("interleave_leading_audio_bytes", session.host.interleavePolicy.leadingAudioBytes)
                        .put("network_interleave_retry", session.host.interleaveRetry)
                        .put("network_interleave_restart_ms", session.host.interleaveRestartMs)
                        .put("source_start_ms", session.host.startMs)
                        .put("captured_frames", session.captured)
                        .put("display_claims", session.display.heldClaims()).put("post_draw_frames", session.ownerDraws)
                        .put("unique_post_draw_frames", session.uniquePostDrawFrames).put("rvm_model_created", session.model != null)
                        .put("rvm_model_ready", session.model?.isReady() == true)
                        .put("producer_copy_deferred", session.deferredCopies).put("producer_copy_pending", session.pendingSource != null)
                        .put("eof_pair_post_draw", session.end.complete()).put("eof_presented_slot", session.end.completedSlot())
                        .put("audio_focus", audioFocusState).put("narration", session.host.narration?.status() ?: JSONObject().put("state", "off")))
                    if (status.optString("state") == "failed" || status.optBoolean("render_failed"))
                        throw PlaybackFailureException(PlaybackFailure.native(status))
                }
            } catch (failure: Throwable) { fail(session, "MPV_FRAME_PIPELINE_FAILED", failure) }
        }
        for (host in hosts) if (host.closing && sessions.values.none { it.host === host }) {
            try {
                if (host.handle == 0L || MpvSourceNative.close(host.handle, host.owner != EGL14.eglGetCurrentContext())) {
                    host.handle = 0; host.closeDescriptors(); hosts.remove(host)
                    // A newer playback may already own the current swapchain; only the last one destroys it.
                    host.fanout?.close(); host.fanout = null
                    host.copy?.close(); host.copy = null
                    if (host.layer && currentLayerSurface === host.layerSurface) {
                        VideoLayerNative.destroySurface(); currentLayerSurface = null
                    }
                }
            } catch (_: Throwable) { /* Preserve ownership and retry; never close a descriptor still used by MPV. */ }
        }
    }
    private fun capture(session: Session, source: JSONObject): Boolean {
        if (source.optString("color_target") == "layer") return captureLayer(session, source)
        val producer = source.getLong("producer_token")
        var releaseProducer = true
        try {
            check(source.getBoolean("source_ticket_valid") && source.getBoolean("producer_fence_ready") && source.getBoolean("owner_context_shared"))
            if (source.optBoolean("spatial_video")) session.spatial = true
            val width = source.getInt("width"); val height = source.getInt("height")
            check(!session.stereo || (if (session.topBottom) height else width) % 2 == 0)
            val eyeWidth = if (session.stereo && !session.topBottom) width / 2 else width
            val eyeHeight = if (session.topBottom) height / 2 else height
            val epoch = source.getLong("source_epoch")
            if (session.sourceEpoch == 0L) session.sourceEpoch = epoch
            check(session.sourceEpoch == epoch) { "Source epoch changed without processing generation reset" }
            if (session.renderer == 0L) {
                session.owner = EGL14.eglGetCurrentContext()
                session.renderer = RenderBridgeNative.create(width, height, session.dims[0], session.dims[1], session.stereo, session.topBottom)
                if (session.alpha && session.vulkan && !debugZeroCopyDisabled)
                    session.zeroCopy = RenderBridgeNative.enableZeroCopy(session.renderer)
                // Alpha keeps each captured MPV slot for the pair's life instead of copying 8K (~270MB
                // of bus traffic per frame); MPV has spare slots for the frames in flight.
                // Normal direct playback holds the decoder image (or, for Profile 5/software decode, the MPV
                // color) the same way, so no frame is copied at all.
                if ((session.alpha || normalDirect(session)) && !debugBorrowDisabled)
                    session.borrow = RenderBridgeNative.enableBorrowedColor(session.renderer)
                if (session.roiEnabled && !debugRoiDisabled) session.roi = RoiController(RenderBridgeNative.fullInputRect(session.renderer),
                    session.dims[0], session.dims[1], eyeWidth, eyeHeight)
            }
            val buffer = source.optLong("hardware_buffer", 0L)
            // A decoder image published for an earlier direct session: release it and wait for the next frame.
            if (buffer != 0L && !(session.borrow && (session.alpha || normalDirect(session)))) return true
            val plan = session.roi?.plan()
            val token = if (buffer != 0L && !session.inference)
                RenderBridgeNative.captureOpaqueBuffer(session.renderer, buffer, source.getInt("buffer_width"), source.getInt("buffer_height"))
            else if (buffer != 0L)
                RenderBridgeNative.captureBufferRoi(session.renderer, buffer, source.getInt("buffer_width"), source.getInt("buffer_height"),
                    plan?.rect ?: RenderBridgeNative.fullInputRect(session.renderer), plan?.scout ?: false)
            else if (!session.inference && session.normalFastPath)
                RenderBridgeNative.captureOpaqueTexture(session.renderer, source.getInt("color_texture_id"))
            else if (plan != null)
                RenderBridgeNative.captureTextureRoi(session.renderer, source.getInt("color_texture_id"), plan.rect, plan.scout)
            // 2D->3D stages (and later reads back) a model input only when the depth model will take it.
            else RenderBridgeNative.captureTexture(session.renderer, source.getInt("color_texture_id"),
                session.alpha || (session.depth && session.depthModel?.wantsInput(source.getLong("frame_id")) == true).also { source.put("depth_input_staged", it) })
            if (token == 0L) {
                // A full consumer ring must not consume the only remaining EOF
                // frame. Keep the immutable producer lease and retry next draw.
                releaseProducer = false
                return false
            }
            if (session.borrow) { session.copyingProducer = producer; releaseProducer = false }
            val ticket = DecodedFrameGate.Ticket(session.scope, source.getLong("frame_id"), source.getLong("pts_us"), 1, 1)
            val sourceAspect = eyeWidth.toDouble()/eyeHeight
            val inputAspect = session.dims[0].toDouble()/session.dims[1]
            val rect = plan?.rect?.map { it.toDouble() }
                ?: if (sourceAspect > inputAspect) { val h = inputAspect/sourceAspect; listOf(0.0, (1-h)*0.5, 1.0, h) }
                else { val w = sourceAspect/inputAspect; listOf((1-w)*0.5, 0.0, w, 1.0) }
            source.put("producer_color_texture_id", source.getInt("color_texture_id"))
                .put("mpv_source_handle", session.host.handle)
                .put("godot_context_shared", true)
                .put("slot_token", token).put("format_revision", 1).put("effect_revision", 1)
                .put("session_id", session.id).put("logical_session_id", session.scope.logicalSessionId).put("generation", session.scope.generation)
                .put("input_width", session.dims[0]).put("input_height", session.dims[1]).put("profile_key", session.profile)
                .put("input_layout", "float32_CHW_RGB_0_1").put("model_content_rect", JSONArray(rect)).put("stereo_sbs", session.stereo).put("top_bottom", session.topBottom)
                .put("source_pts_verified", true).put("source_ticket_origin", "private_same_mpv_render_transaction")
                .put("alpha_requested", session.alpha).put("depth_requested", session.depth).put("immutable_color_frame", true)
            if (plan != null) source.put("roi_window_id", plan.windowId).put("roi_scout", plan.scout).put("roi_zoomed", plan.zoomed)
            session.copying = ticket to token; session.copyingPair = source
            return true
        } finally {
            // This consumer fence follows the full-resolution GPU copy and small
            // input staging. There is never a CPU readback of the source image.
            if (releaseProducer)
                check(MpvSourceNative.release(session.host.handle, producer)) { "Producer lease release failed" }
        }
    }
    /** Alpha plan B: the newest frame fanned out from the layer surface becomes the RVM input, as a decoder
     * capture does in MPV direct mode, at the Alpha rate. Its mask goes to the mask layer (finishUploads). */
    private fun captureFanout(session: Session) {
        val now = System.nanoTime()
        if (now < session.nextFanoutNs) return
        val frame = session.host.frames?.take() ?: return
        try {
            session.nextFanoutNs = now + 1_000_000_000L / alphaFps.coerceAtLeast(1)
            val width = frame.width; val height = frame.height
            check(!session.stereo || (if (session.topBottom) height else width) % 2 == 0)
            val eyeWidth = if (session.stereo && !session.topBottom) width / 2 else width
            val eyeHeight = if (session.topBottom) height / 2 else height
            if (session.renderer == 0L) {
                session.owner = EGL14.eglGetCurrentContext()
                session.renderer = RenderBridgeNative.create(width, height, session.dims[0], session.dims[1], session.stereo, session.topBottom)
                if (session.vulkan && !debugZeroCopyDisabled) session.zeroCopy = RenderBridgeNative.enableZeroCopy(session.renderer)
                if (session.roiEnabled && !debugRoiDisabled) session.roi = RoiController(RenderBridgeNative.fullInputRect(session.renderer),
                    session.dims[0], session.dims[1], eyeWidth, eyeHeight)
            }
            val plan = session.roi?.plan()
            val buffer = RenderBridgeNative.hardwareBufferPointer(frame.buffer)
            val token = RenderBridgeNative.captureBufferRoi(session.renderer, buffer, frame.bufferWidth, frame.bufferHeight,
                plan?.rect ?: RenderBridgeNative.fullInputRect(session.renderer), plan?.scout ?: false)
            if (token == 0L) return
            val ticket = DecodedFrameGate.Ticket(session.scope, frame.sequence, frame.timestampNs / 1000, 1, 1)
            val sourceAspect = eyeWidth.toDouble()/eyeHeight
            val inputAspect = session.dims[0].toDouble()/session.dims[1]
            val rect = plan?.rect?.map { it.toDouble() }
                ?: if (sourceAspect > inputAspect) { val h = inputAspect/sourceAspect; listOf(0.0, (1-h)*0.5, 1.0, h) }
                else { val w = sourceAspect/inputAspect; listOf((1-w)*0.5, 0.0, w, 1.0) }
            val pair = JSONObject().put("width", width).put("height", height)
                .put("buffer_width", frame.bufferWidth).put("buffer_height", frame.bufferHeight)
                .put("frame_id", frame.sequence).put("pts_us", frame.timestampNs / 1000).put("source_epoch", session.sourceEpoch)
                .put("mpv_source_handle", session.host.handle).put("slot_token", token).put("format_revision", 1).put("effect_revision", 1)
                .put("session_id", session.id).put("logical_session_id", session.scope.logicalSessionId).put("generation", session.scope.generation)
                .put("input_width", session.dims[0]).put("input_height", session.dims[1]).put("profile_key", session.profile)
                .put("input_layout", "float32_CHW_RGB_0_1").put("model_content_rect", JSONArray(rect))
                .put("stereo_sbs", session.stereo).put("top_bottom", session.topBottom)
                .put("source_pts_verified", true).put("source_ticket_origin", "layer_fanout")
                .put("alpha_requested", true).put("depth_requested", false).put("immutable_color_frame", true).put("layer_alpha", true)
            // Zero-copy model inputs need no CPU planes (finishCopy reads this key).
            if (session.zeroCopy) pair.put("hardware_buffer", buffer)
            if (plan != null) pair.put("roi_window_id", plan.windowId).put("roi_scout", plan.scout).put("roi_zoomed", plan.zoomed)
            session.copying = ticket to token; session.copyingPair = pair
            if (session.captureNs.size > 16) session.captureNs.clear() // tokens the model dropped
            session.maskInFlightNs = System.nanoTime(); session.captureNs[token] = session.maskInFlightNs
        } finally { frame.buffer.close() } // the capture's EGLImage holds the buffer now
    }
    /** GPU copy: a finished mask goes up once the copy thread has drawn its frame; of several, the newest
     * shown (the others are retired). Masks never wait for long: a stalled copy lets them through. */
    private fun showPresentedMasks(session: Session) {
        val presented = session.host.frames?.presented ?: return
        var latest: Pair<Long, JSONObject>? = null
        while (session.pendingMasks.isNotEmpty() && (session.pendingMasks.first().second.getLong("frame_id") <= presented ||
                session.pendingMasks.size > 4)) {
            latest?.let { retire(session, it.first) }
            latest = session.pendingMasks.removeFirst()
        }
        latest?.let { (token, pair) -> showLayerMask(session, token, pair); retire(session, token) }
    }
    /** Alpha plan B: the finished mask, drawn over the frame layout into the mask swapchain (slot 2). */
    private fun showLayerMask(session: Session, token: Long, pair: JSONObject) {
        val layout = if (!session.stereo) 0 else if (session.topBottom) 2 else 1
        val width = pair.getInt("width"); val height = pair.getInt("height")
        // An ROI window puts the model's pixels on a small part of the frame: a coarse mask swapchain blurred
        // its edges into a halo of the video's background. 2048 per eye keeps the model's detail.
        val scale = minOf(1.0, (if (layout == 1) 4096.0 else 2048.0) / width)
        val maskWidth = maxOf(2, Math.round(width * scale).toInt()); val maskHeight = maxOf(2, Math.round(height * scale).toInt())
        val values = pair.getJSONArray("model_content_rect")
        val rect = FloatArray(4) { values.getDouble(it).toFloat() }
        try {
            if (!VideoLayerNative.createImage(MASK_SLOT, maskWidth, maskHeight, 1, false) || VideoLayerNative.acquireImage(MASK_SLOT) <= 0) return
            val edge = alphaEdge
            val drawn = VideoLayerNative.drawMask(MASK_SLOT, RenderBridgeNative.alphaTexture(session.renderer, token), rect, layout,
                session.dims[0], session.dims[1], edge[0], edge[1])
            if (VideoLayerNative.releaseImage(MASK_SLOT, false) && drawn) {
                VideoLayerNative.maskDrawn()
                session.layerMasks++
                layerMask = "${session.layerMasks} $maskWidth $maskHeight"
            }
        } finally {
            // The frames this mask belongs with (and the earlier ones) go to the compositor in the same frame.
            // One frame newer may show with this mask too (masks come every two or three frames): no frame
            // is then more than a frame away from its mask, and none waits for the mask after next.
            session.host.frames?.releaseThrough(pair.getLong("frame_id") + 1)
        }
    }
    /** Layer frame: an identity only, the picture is already on the compositor's surface. Offered to
     * Godot like a completed pair so its claim/seek/EOF bookkeeping is unchanged. */
    private fun captureLayer(session: Session, source: JSONObject): Boolean {
        val producer = source.getLong("producer_token")
        val epoch = source.getLong("source_epoch")
        if (session.sourceEpoch == 0L) session.sourceEpoch = epoch
        if (epoch < session.sourceEpoch) { MpvSourceNative.release(session.host.handle, producer); return true }
        session.sourceEpoch = epoch
        val token = ++layerTokens
        val width = source.getInt("width"); val height = source.getInt("height")
        val pair = source.put("slot_token", token).put("mpv_source_handle", session.host.handle)
            .put("session_id", session.id).put("logical_session_id", session.scope.logicalSessionId).put("generation", session.scope.generation)
            .put("format_revision", 1).put("effect_revision", 1).put("model_generation", 1)
            .put("input_width", session.dims[0]).put("input_height", session.dims[1]).put("profile_key", session.profile)
            .put("model_content_rect", JSONArray(listOf(0.0, 0.0, 1.0, 1.0)))
            .put("stereo_sbs", session.stereo).put("top_bottom", session.topBottom)
            .put("source_pts_verified", true).put("source_ticket_origin", "compositor_layer_playback_restart_or_position")
            .put("alpha_requested", false).put("depth_requested", false).put("inference_ran", false)
            .put("pair_identity_verified", true).put("alpha_kind", "none_layer").put("alpha_texture_id", 0)
            .put("alpha_width", session.dims[0] * 2).put("alpha_height", session.dims[1])
            .put("consumer_copy_fence_ready", true).put("buffer_width", width).put("buffer_height", height)
        session.leases[token] = Lease(DecodedFrameGate.Ticket(session.scope, source.getLong("frame_id"), source.getLong("pts_us"), 1, 1),
            pair, NO_PLANES.first, NO_PLANES.second, producer)
        session.captured++
        val obsolete = session.display.offer(identity(pair))
        if (BuildConfig.DEBUG && session.captured <= 4L) android.util.Log.i("QuestPlayer", "layer pair offer token=$token obsolete=$obsolete " +
            "alpha=${session.alpha} frame=${pair.optLong("frame_id")} pts=${pair.optLong("pts_us")} head=${session.display.readyToken()}")
        if (obsolete == token) { retire(session, token); return true }
        obsolete?.let { retire(session, it) }
        session.pairs[token] = pair; session.latestPair = pair.toString()
        val head = session.display.readyToken()
        if (head != null && (head == token || obsolete != null))
            session.pairs[head]?.let { emit("mpv_pair_available", session.id, it.toString()) }
        return true
    }
    private fun finishCopy(session: Session) {
        val copying = session.copying ?: return
        if (!RenderBridgeNative.ready(session.renderer, copying.second)) return
        val texture = RenderBridgeNative.texture(session.renderer, copying.second)
        val bytes = session.dims[0]*session.dims[1]*3*4
        val pair = session.copyingPair ?: error("Immutable copy descriptor missing")
        // Decoder images get a new texture each frame and always use zero-copy: no CPU planes.
        val buffers = if (pair.has("hardware_buffer")) NO_PLANES else session.buffers.getOrPut(texture) {
            ByteBuffer.allocateDirect(bytes).order(ByteOrder.LITTLE_ENDIAN) to ByteBuffer.allocateDirect(bytes).order(ByteOrder.LITTLE_ENDIAN)
        }
        pair.put("color_texture_id", texture).put("consumer_copy_fence_ready", true)
        val image = RenderBridgeNative.colorImage(session.renderer, copying.second)
        // A string: Godot's JSON parses numbers as doubles, which cannot hold a 64-bit (tagged) pointer.
        if (image != 0L) pair.put("color_target", "external").put("color_egl_image", image.toString()).put("color_uv_scale", JSONArray(listOf(
            pair.getInt("width").toDouble() / pair.getInt("buffer_width"), pair.getInt("height").toDouble() / pair.getInt("buffer_height"))))
        val lease = Lease(copying.first, pair, buffers.first, buffers.second, session.copyingProducer)
        session.copyingProducer = 0L
        session.leases[copying.second] = lease
        session.copying = null; session.copyingPair = null; session.captured++
        if (session.alpha && session.zeroCopy) {
            pair.put("alpha_transport", "zero_copy")
            val shared = RenderBridgeNative.zeroCopyBuffers(session.renderer, copying.second, false)
            val scout = if (pair.optBoolean("roi_scout")) RenderBridgeNative.zeroCopyBuffers(session.renderer, copying.second, true) else null
            session.model!!.submitShared(copying.first, copying.second, shared, pair, scout)
        } else if (session.alpha) {
            check(RenderBridgeNative.readInputs(session.renderer, copying.second, buffers.first, buffers.second))
            val scout = if (pair.optBoolean("roi_scout")) session.scoutBuffers.getOrPut(texture) {
                ByteBuffer.allocateDirect(bytes).order(ByteOrder.LITTLE_ENDIAN) to ByteBuffer.allocateDirect(bytes).order(ByteOrder.LITTLE_ENDIAN)
            }.also { check(RenderBridgeNative.readScoutInputs(session.renderer, copying.second, it.first, it.second)) } else null
            session.model!!.submit(copying.first, copying.second, buffers.first, buffers.second, pair, scout?.first, scout?.second)
        } else if (session.depth) {
            // Mono: both staged eyes hold the same frame; the model reads one. Frames the model skips
            // were not staged: they show with the latest map and cost no readback.
            val staged = pair.optBoolean("depth_input_staged")
            if (staged) check(RenderBridgeNative.readInputs(session.renderer, copying.second, buffers.first, buffers.second))
            session.depthModel!!.submit(copying.first, copying.second, if (staged) buffers.first else null, pair)
        } else {
            pair.put("model_generation", 1).put("inference_ran", false).put("pair_identity_verified", true)
                .put("alpha_kind", "opaque_numeric_mask")
            if (session.normalFastPath) {
                check(RenderBridgeNative.alphaReady(session.renderer, copying.second)) { "Opaque mask must share the completed color fence" }
                session.alphaUploads[copying.second] = Alpha(pair, session.opaque.first, session.opaque.second)
            } else upload(session, pair, session.opaque.first, session.opaque.second)
        }
    }
    private fun upload(session: Session, pair: JSONObject, left: ByteBuffer, right: ByteBuffer) {
        val token = pair.getLong("slot_token")
        if (pair.optBoolean("layer_alpha")) session.maskInFlightNs = 0L // the model is free for the next frame
        check(session.leases.containsKey(token)) { "Alpha color lease unavailable" }
        if (pair.optString("alpha_transport") == "zero_copy") check(RenderBridgeNative.commitZeroCopyAlpha(session.renderer, token))
        else check(RenderBridgeNative.uploadAlpha(session.renderer, token, left, right))
        if (session.depth && pair.optBoolean("depth_ran")) {
            val stereo = RenderBridgeNative.warp(session.renderer, token, session.depthShift, session.depthConvergence)
            if (stereo > 0) pair.put("warp_texture_id", stereo) else pair.remove("warp_texture_id")
        }
        session.alphaUploads[token] = Alpha(pair, left, right)
    }
    private fun finishUploads(session: Session) {
        val iterator = session.alphaUploads.iterator()
        while (iterator.hasNext()) {
            val (token, upload) = iterator.next()
            if (session.inference && !session.accepts(upload.pair)) {
                iterator.remove(); retire(session, token); continue
            }
            if (!RenderBridgeNative.alphaReady(session.renderer, token)) continue
            iterator.remove()
            if (upload.pair.optBoolean("layer_alpha")) {
                // Capture to finished mask: delayed presentation waits as long (and the audio with it).
                session.captureNs.remove(token)?.let { captured ->
                    val latency = (System.nanoTime() - captured) / 1e6
                    session.maskLatencyMs = if (session.maskLatencyMs == 0.0) latency else session.maskLatencyMs * 0.9 + latency * 0.1
                    session.host.frames?.maskLatency(session.maskLatencyMs)
                }
                if (session.host.frames?.presentsLater == true) session.pendingMasks.addLast(token to upload.pair)
                else { showLayerMask(session, token, upload.pair); retire(session, token) }
                continue
            }
            val pair = upload.pair.put("alpha_texture_id", RenderBridgeNative.alphaTexture(session.renderer, token))
                .put("alpha_width", session.dims[0]*2).put("alpha_height", session.dims[1])
                .put("alpha_texture_format", "GL_R8_numeric").put("alpha_gpu_uploaded", true).put("alpha_fence_ready", true)
                .put("alpha_slot_token", token).put("alpha_frame_id", upload.pair.getLong("frame_id"))
                .put("alpha_pts_us", upload.pair.getLong("pts_us"))
            val obsolete = session.display.offer(identity(pair))
            if (obsolete == token) { retire(session, token); continue }
            obsolete?.let { retire(session, it) }
            session.pairs[token] = pair; session.latestPair = pair.toString()
            // Godot claims the oldest ready pair; a newer one is offered once that is claimed. When a full
            // queue drops the oldest (the one Godot was told about), tell Godot the new oldest: otherwise its
            // claim of the dropped pair fails and no notice ever comes again (frozen picture at high rates).
            val head = session.display.readyToken()
            if (head != null && (head == token || obsolete != null))
                session.pairs[head]?.let { emit("mpv_pair_available", session.id, it.toString()) }
        }
    }
    private fun identity(pair: JSONObject) = FramePairGate.Identity(pair.getInt("session_id"), pair.getInt("logical_session_id"),
        pair.getInt("generation"), pair.getLong("frame_id"), pair.getLong("pts_us"), pair.getInt("format_revision"),
        pair.getLong("effect_revision"), pair.getLong("model_generation"), pair.getLong("slot_token"))
    fun setDepthView(id: Int, shift: Double, convergence: Double): Boolean {
        val session = sessions[id] ?: return false
        if (!session.depth || shift !in 0.0..0.2 || convergence !in 0.0..1.0) return false
        session.depthShift = shift.toFloat(); session.depthConvergence = convergence.toFloat()
        // Rewarp the held display texture as well: paused videos have no new frame to upload.
        // Read current values on the render thread so rapid pointer updates coalesce naturally.
        if (session.depthViewQueued.compareAndSet(false, true)) render(Runnable { synchronized(session.lock) {
            session.depthViewQueued.set(false)
            if (active(session) && session.renderer > 0 && session.owner == EGL14.eglGetCurrentContext()) {
                val token = session.drawnToken
                val pair = session.pairs[token]
                if (pair != null && pair.optInt("warp_texture_id") > 0 && session.display.owns(token)) {
                    runCatching { RenderBridgeNative.warp(session.renderer, token, session.depthShift, session.depthConvergence) }
                        .onFailure { android.util.Log.w("QuestPlayer", "Depth view refresh failed", it) }
                }
            }
        } })
        return true
    }
    fun claim(id: Int, token: Long): String {
        val session = sessions[id] ?: return ""
        val next: String?
        val claimed: String
        synchronized(session.lock) {
            if (!active(session) || session.display.claim(token) == null) return ""
            claimed = session.pairs[token]?.toString() ?: ""
            next = session.display.readyToken()?.let { session.pairs[it]?.toString() }
        }
        // The next ready pair (a burst) is drawn on Godot's following frame.
        next?.let { emit("mpv_pair_available", session.id, it) }
        return claimed
    }
    /** Capture on a real owner draw callback, while the original display claim is pinned.
     * Its returned copy outlives the old processing session, without a decoder lease. */
    fun freeze(id: Int, token: Long, request: Int): Boolean {
        val session = sessions[id] ?: return false
        if (session.host.layer) return false // the layer surface keeps showing its frame until the next one
        if (request <= 0 || !freezePending.compareAndSet(false, true)) return false
        synchronized(session.lock) {
            if (!active(session) || !session.display.pin(token)) { freezePending.set(false); return false }
        }
        try {
            render(Runnable { synchronized(session.lock) {
                val report = JSONObject().put("request_id", request).put("slot_token", token)
                try {
                    check(active(session)) { "Freeze source no longer active" }
                    val pair = JSONObject(session.pairs.getValue(token).toString())
                    val warp = pair.optInt("warp_texture_id") > 0 && !pair.getBoolean("stereo_sbs")
                    val copy = RenderBridgeNative.freezePair(session.renderer, token, warp)
                    frozenFrames[copy[0]] = AtomicInteger(1)
                    pair.put("frozen_frame_id", copy[0]).put("freeze_copy_us", copy[5])
                        .put("color_target", "texture").put("color_texture_id", copy[1])
                        .put("alpha_texture_id", copy[2]).put("color_egl_image", "0")
                        .put("warp_texture_id", if (warp) copy[1] else 0)
                    report.put("pair", pair).put("state", "ready")
                } catch (failure: Throwable) {
                    report.put("state", "failed").put("error", failure.message)
                } finally {
                    session.display.unpin(token); freezePending.set(false)
                    release(session, token)
                }
                emit("mpv_frozen_pair", session.id, report.toString())
            } })
            return true
        } catch (_: Throwable) {
            synchronized(session.lock) { session.display.unpin(token) }
            freezePending.set(false)
            return false
        }
    }
    fun releaseFrozen(id: Long) {
        if (id <= 0) return
        render(Runnable {
            val refs = frozenFrames[id] ?: return@Runnable
            if (refs.decrementAndGet() == 0 && frozenFrames.remove(id, refs)) RenderBridgeNative.releaseFrozen(id)
        })
    }
    fun retainFrozen(id: Long): Boolean {
        val refs = frozenFrames[id] ?: return false
        while (true) {
            val count = refs.get()
            if (count <= 0) return false
            if (refs.compareAndSet(count, count + 1)) return true
        }
    }
    fun acknowledge(id: Int, token: Long): Boolean {
        val session = sessions[id] ?: return false
        synchronized(session.lock) {
            val pair = session.pairs[token] ?: return false
            // A layer identity (the picture is on the compositor's surface) carries no effect of its own: the
            // Alpha plan B mask goes to the mask layer, so it is presented without an inference result.
            val identity = pair.optString("color_target") == "layer"
            if (!active(session) || (session.inference && !identity && !session.presented(pair)) || !session.display.acknowledge(token)) return false
            session.drawnToken = token; pair.put("pair_presented", true); session.firstPair = true
            session.host.markStartup("first_pair_bound_ms")
            return true
        }
    }
    fun detach(id: Int, token: Long): Boolean {
        val session = sessions[id] ?: return false
        synchronized(session.lock) { if (!session.display.detach(token)) return false }
        render(Runnable { synchronized(session.lock) {
            if (retirable(session) && !session.display.owns(token)) retire(session, token)
        } })
        return true
    }
    private fun release(session: Session, token: Long) {
        render(Runnable { synchronized(session.lock) {
            if (retirable(session) && !session.display.owns(token)) retire(session, token)
        } })
    }
    private fun retirable(session: Session) =
        session.host.layer || (session.renderer > 0 && session.owner == EGL14.eglGetCurrentContext())
    private fun retire(session: Session, token: Long) {
        check(!session.display.owns(token)) { "Cannot retire a Godot display claim" }
        val lease = session.leases.remove(token) ?: return
        session.pairs.remove(token)
        if (session.renderer > 0 && lease.pair.optString("color_target") != "layer") {
            RenderBridgeNative.retire(session.renderer, token); session.retiring.add(token)
        }
        // After the bridge fence: the MPV slot may be reused once every draw of this pair completes.
        if (lease.producer > 0) check(MpvSourceNative.release(session.host.handle, lease.producer)) { "Borrowed producer release failed" }
    }
    fun requestPixelMask(request: Int, id: Int, token: Long): Boolean {
        if (!BuildConfig.DEBUG || request <= 0) return false
        val session = sessions[id] ?: return false
        val pair = synchronized(session.lock) {
            if (!active(session) || !session.pairs.containsKey(token) || !session.display.pin(token)) return false
            JSONObject(session.pairs.getValue(token).toString())
        }
        try {
            render(Runnable { synchronized(session.lock) {
                val report = JSONObject().put("request_id", request).put("pair", pair)
                try {
                    check(session.renderer > 0 && session.owner == EGL14.eglGetCurrentContext())
                    val pixels = pair.getInt("alpha_width") * pair.getInt("alpha_height")
                    val buffer = ByteBuffer.allocateDirect(pixels)
                    check(RenderBridgeNative.readAlpha(session.renderer, token, buffer))
                    val bytes = ByteArray(pixels); buffer.position(0); buffer.get(bytes)
                    val app = context() ?: error("Activity unavailable")
                    val directory = java.io.File(app.filesDir, "diagnostics").apply { mkdirs() }
                    val name = "mpv_pixel_mask_$request.r8"
                    val temporary = java.io.File.createTempFile("mask-", ".tmp", directory)
                    try { temporary.writeBytes(bytes); check(temporary.renameTo(java.io.File(directory, name))) }
                    finally { temporary.delete() }
                    report.put("state", "ready").put("mask_file", name).put("mask_bytes", pixels)
                        .put("mask_origin", "same_pinned_pair_native_R8_readback")
                } catch (failure: Throwable) {
                    report.put("state", "failed").put("error", failure.message)
                    unpinPixelPair(id, token)
                }
                emit("mpv_pixel_mask", request, report.toString())
            } })
            return true
        } catch (_: Throwable) {
            synchronized(session.lock) { session.display.unpin(token) }
            return false
        }
    }
    fun unpinPixelPair(id: Int, token: Long): Boolean {
        if (!BuildConfig.DEBUG) return false
        return unpinPair(id, token)
    }
    /** Library picture of a layer session (see LayerThumbnail); 0 when the session shows no layer. */
    fun requestLayerThumbnail(id: Int, width: Int, height: Int, rotation: Int, crop: FloatArray, outWidth: Int, outHeight: Int): Int {
        val session = sessions[id] ?: return 0
        if (!active(session) || !session.host.layer) return 0
        return LayerThumbnail.request(session.host.layerSurface, width, height, rotation, crop, outWidth, outHeight)
    }
    fun pinPair(id: Int, token: Long): Boolean {
        val session = sessions[id] ?: return false
        synchronized(session.lock) { return active(session) && session.display.pin(token) }
    }
    fun unpinPair(id: Int, token: Long): Boolean {
        val session = sessions[id] ?: return false
        synchronized(session.lock) { if (!session.display.unpin(token)) return false }
        release(session, token)
        return true
    }
    private fun pollRetirements(session: Session) {
        val iterator = session.retiring.iterator()
        while (iterator.hasNext()) if (RenderBridgeNative.retired(session.renderer, iterator.next())) iterator.remove()
    }
    private fun cleanup(session: Session) {
        session.pendingSource?.let { source ->
            if (session.host.owner == EGL14.eglGetCurrentContext()) {
                check(MpvSourceNative.release(session.host.handle, source.getLong("producer_token")))
            } else {
                // The lost owner context cannot insert a consumer release fence.
                session.host.narration?.close(); session.host.narration = null
                session.host.closing = true
                MpvSourceNative.close(session.host.handle, true)
            }
            session.pendingSource = null
        }
        if (session.renderer > 0) {
            if (session.owner != EGL14.eglGetCurrentContext()) {
                RenderBridgeNative.abandon(session.renderer); session.renderer = 0; session.retiring.clear()
            } else {
                session.copying?.let { RenderBridgeNative.retire(session.renderer, it.second); session.retiring.add(it.second) }
                if (session.copyingProducer > 0) MpvSourceNative.release(session.host.handle, session.copyingProducer)
                session.copyingProducer = 0L
                session.copying = null; session.copyingPair = null; session.alphaUploads.clear()
                session.leases.keys.toList().filter { !session.display.owns(it) }.forEach { retire(session, it) }
                pollRetirements(session)
            }
        }
        if (session.host.layer) session.leases.keys.toList().filter { !session.display.owns(it) }.forEach { retire(session, it) }
        if (session.display.heldClaims() > 0 || session.retiring.isNotEmpty()) return
        if (session.renderer > 0) RenderBridgeNative.close(session.renderer)
        session.renderer = 0; session.buffers.clear(); session.scoutBuffers.clear(); session.leases.clear(); session.pairs.clear()
        sessions.remove(session.id)
        event("mpv_released", session, JSONObject().put("renderer_closed", true).put("held_slots", 0))
    }
    private fun dispose(session: Session, closeHost: Boolean) {
        if (!session.disposed.compareAndSet(false, true)) return
        session.model?.close(); session.depthModel?.close(); session.normal.close()
        synchronized(session.lock) { session.display.close() }
        if (closeHost) {
            session.host.narration?.close(); session.host.narration = null
            session.host.closing = true
            if (session.host.handle > 0) MpvSourceNative.setPlaying(session.host.handle, false)
            refreshPlayback()
        }
        event("mpv_detach", session, JSONObject().put("reason", "generation_invalidated"))
    }
    private fun fail(session: Session, code: String, failure: Throwable) {
        if (session.disposed.get()) return
        val stage = when (session.host.loadingPhase) {
            "connecting" -> "resolving"
            "reading_disc" -> "parsing"
            "reading" -> "reading"
            else -> "output"
        }
        val upstream = session.host.networkLease?.let(networkFailure)
        event("mpv_error", session, PlaybackFailure.report(code, failure, stage, upstream))
        gate.invalidate(session.id); dispose(session, true)
    }
    fun close(id: Int) { sessions[id]?.let { gate.invalidate(id); dispose(it, true) } }
    /** File-management worker only. close() invalidates playback before GL retires its reader. */
    fun awaitFileRelease(uri: String) {
        val deadline = System.nanoTime() + 5_000_000_000L
        val prefix = uri.trimEnd('/') + "/"
        while (true) {
            val readers = hosts.filter { it.uri == uri || it.uri.startsWith(prefix) }
            if (readers.isEmpty()) return
            check(readers.all { it.closing }) { "Stop playback before file management" }
            check(System.nanoTime() < deadline) { "Playback is still closing. Try again" }
            Thread.sleep(25)
        }
    }
    fun pause() {
        foreground = false; hosts.forEach { it.narration?.allow(false); if (it.handle > 0) MpvSourceNative.setPlaying(it.handle, false) }
        refreshPlayback()
    }
    fun resume() { foreground = true; refreshPlayback() }
    fun contextCreated() {
        frozenFrames.keys.toList().forEach { RenderBridgeNative.releaseFrozen(it); frozenFrames.remove(it) }
        // A real recreated context invalidates the complete pipeline. Initial
        // creation has no sessions; UI can reopen the same authorized URI.
        sessions.values.forEach { fail(it, "MPV_GL_CONTEXT_RECREATED", IllegalStateException("Owner context recreated")) }
    }
    // GL thread: layer pair tokens (no bridge slot behind them), in a range of their own: an Alpha layer
    // session also holds render bridge tokens in the same lease map.
    private var layerTokens = 1L shl 40
    @Volatile private var currentLayerSurface: android.view.Surface? = null
    /** Debug builds: an integer system property, [fallback] when unset or not a number. */
    private fun debugInt(name: String, fallback: Int): Int = if (BuildConfig.DEBUG) debugProperty(name).toIntOrNull() ?: fallback else fallback
    private fun debugProperty(name: String): String = try {
        Class.forName("android.os.SystemProperties").getMethod("get", String::class.java).invoke(null, name) as String
    } catch (_: Throwable) { "" }
    /** Alpha on the layer: the GPU copy (LayerCopy) keeps the decoder surface path, RVM reads its held frames
     * and the mask becomes a compositor mask layer. Godot asks for it only where the runtime blends layers
     * (XR_FB_composition_layer_alpha_blend). Debug builds can compare the eye-buffer Alpha with
     * adb shell setprop debug.vrpp.layer.alpha 0. */
    private fun layerAlpha() = !BuildConfig.DEBUG || debugProperty("debug.vrpp.layer.alpha") != "0"
    companion object {
        /** Alpha plan B: masks shown so far in this Alpha layer session and the mask swapchain size, "count w h". */
        @Volatile var layerMask = "0 0 0"
        const val MASK_SLOT = 2 // the picture swapchain slot Godot shows as the mask layer
        const val HOLD_LIMIT_MS = 250L // a held layer frame goes on without its mask after this
        /** Nominal swapchain size: the decoder sets the buffer size; layer rects are in these units. */
        const val LAYER_SURFACE_SIZE = 4096
        const val RVM_VIDEO_FPS = 30
        val ALPHA_FPS_RANGE = 10..40
        private val NO_PLANES: Pair<ByteBuffer, ByteBuffer> = ByteBuffer.allocateDirect(0) to ByteBuffer.allocateDirect(0)
    }
    fun shutdown() {
        stopped = true; gate.shutdown(); sessions.values.forEach { dispose(it, true) }
        subtitleWorker.shutdownNow()
        companionWorker.shutdownNow()
        // Android may never deliver another draw during termination. Forget old
        // owner references and let each shared native context release its objects.
        hosts.forEach { host -> if (host.handle > 0) MpvSourceNative.close(host.handle, true) }
        Thread({
            for (host in hosts.toList()) {
                while (host.handle > 0) {
                    if (MpvSourceNative.close(host.handle, true)) { host.handle = 0; break }
                    Thread.sleep(20)
                }
                host.closeDescriptors()
            }
        }, "QuestMpvDispose").start()
        // Sessions/models/resources close above; the shared RVM worker survives
        // Activity recreation so libomp never loses its final root thread.
    }
}
