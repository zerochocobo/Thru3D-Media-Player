package org.vrpassthroughplayer.plugin

import android.content.Context
import android.graphics.SurfaceTexture
import android.opengl.*
import android.os.Handler
import android.os.HandlerThread
import android.view.Surface
import org.json.JSONObject
import java.nio.ByteBuffer
import java.nio.ByteOrder
import java.util.concurrent.ConcurrentHashMap
import java.util.concurrent.CountDownLatch
import java.util.concurrent.TimeUnit
import java.util.concurrent.atomic.AtomicBoolean
import java.util.concurrent.atomic.AtomicLong
import kotlin.math.*

/** Gecko remains the decoder and audio owner. Each window owns its EGL/Surface queue.
 * Reuses the player's render bridge, video model and stabilizer; no page/URL extraction. */
object WebBrowserDepthBridge {
    @Volatile private var context: Context? = null
    private val windows = ConcurrentHashMap<Int, Window>()
    private val sessionIds = AtomicLong(1)
    private class Preparation(val depth: Boolean,val matte: Boolean) { @Volatile var state="preparing"; @Volatile var error="" }
    private val preparations=ConcurrentHashMap<Int,Preparation>()
    private val stopping=ConcurrentHashMap<Int,java.util.concurrent.atomic.AtomicInteger>()
    private val stops=java.util.concurrent.Executors.newSingleThreadExecutor { task -> Thread(task,"BrowserEffectStop").apply { isDaemon=true } }
    internal fun install(value: Context) { context = value.applicationContext }
    @JvmStatic fun start(id: Int, output: Surface, sourceWidth: Int, sourceHeight: Int,
                         width: Int, height: Int, crop: FloatArray, matte: Boolean): Boolean {
        val host = context ?: return false
        if (id !in 1..4 || !output.isValid || !WebBrowserDepthGeometry.valid(crop) ||
            sourceWidth !in 256..4096 || sourceHeight !in 256..4096 || width !in 16..2048 || height !in 16..1536) return false
        val window = Window(host, output, sourceWidth, sourceHeight, width, height, crop.copyOf(), matte)
        if (windows.putIfAbsent(id, window) != null) { window.stop(); return false }
        stopping.remove(id)
        window.start(); return true
    }
    /** Verify/warm the requested model caches while the original 2D Surface stays attached. */
    @JvmStatic fun prepare(id: Int,depth: Boolean,matte: Boolean): String {
        val host=context ?: return "{\"state\":\"failed\",\"error\":\"context\"}"
        if(id !in 1..4 || !depth && !matte) return "{\"state\":\"failed\",\"error\":\"request\"}"
        var current=preparations[id]
        if(current==null || current.depth!=depth || current.matte!=matte) {
            val pending=Preparation(depth,matte);preparations[id]=pending;current=pending
            fun failed(error: Throwable) {
                pending.error=error.message ?: error.javaClass.simpleName
                pending.state="failed"
                android.util.Log.w("BrowserDepth", "Browser effect preparation failed", error)
            }
            DepthWorker.handler.post {
                try {
                    if(depth) ModelPreparationGate.run {
                        val model=DepthNative.videoModelFile(host)?.let { DepthNative.createFromFile(it.path,DepthWarmup.cacheDirectory(host).absolutePath) }
                            ?: DepthNative.create(host.assets,DepthWarmup.cacheDirectory(host).absolutePath)
                        check(model!=0L);DepthNative.close(model)
                    }
                    if(matte) RvmWorkers.video.post {
                        try {
                            ModelPreparationGate.run {
                                RvmNative.configureGpu(RvmWarmup.cacheDirectory(host).absolutePath,RvmNative.fp16())
                                RvmRuntime.prepare(host.assets,true,"256x256",sessionIds.getAndIncrement(),1L).close()
                            }
                            pending.state="ready"
                        } catch(error: Throwable) { failed(error) }
                    } else pending.state="ready"
                } catch(error: Throwable) { failed(error) }
            }
        }
        return JSONObject().put("state",current.state).put("error",current.error).toString()
    }
    @JvmStatic fun clearPreparation(id: Int) { preparations.remove(id) }
    @JvmStatic fun requestStop(id: Int) {
        val old=stopping[id]
        if(old!=null && old.get()>=0) return
        val state=java.util.concurrent.atomic.AtomicInteger(0);stopping[id]=state
        val owned=windows[id]
        stops.execute {
            val ok=runCatching { owned?.stop() ?: true }.getOrDefault(false)
            if(ok && owned!=null) windows.remove(id,owned)
            state.set(if(ok) 1 else -1)
        }
    }
    @JvmStatic fun stopState(id: Int): Int = stopping[id]?.get() ?: if(windows[id]==null) 1 else 0
    @JvmStatic fun surface(id: Int): Surface? = windows[id]?.input
    @JvmStatic fun configure(id: Int, strength: Float, position: Float, identity: String, fill: Boolean, depth: Boolean) {
        windows[id]?.configure(strength, position, identity, fill, depth)
    }
    @JvmStatic fun status(id: Int): String = windows[id]?.status() ?: "{}"
    /** Gecko must acknowledge surfaceDestroyed before this call; stops output before XR destruction. */
    @JvmStatic fun stop(id: Int): Boolean {
        val window = windows[id] ?: return true
        if (!window.stop()) return false
        windows.remove(id, window); return true
    }
    internal fun closeAll() { windows.keys.toList().forEach(::stop) }

    private class Window(val host: Context, val output: Surface, val sourceWidth: Int, val sourceHeight: Int,
                         val width: Int, val height: Int, val crop: FloatArray, val matte: Boolean) {
        private val thread = HandlerThread("Browser-Depth-GL").apply { start() }
        private val gl = Handler(thread.looper)
        private val closed = AtomicBoolean(false)
        private val available = AtomicBoolean(false)
        private val done = CountDownLatch(1)
        @Volatile var input: Surface? = null
        @Volatile private var error = ""
        @Volatile private var frames = 0L
        @Volatile private var maps = 0L
        @Volatile private var busy = false
        @Volatile private var identity = ""
        @Volatile private var revision = 0L
        @Volatile private var strength = .5f
        @Volatile private var convergence = .35f
        @Volatile private var fill = false
        @Volatile private var depthEnabled = true
        @Volatile private var matteFrames = 0L
        @Volatile private var matteBusy = false
        @Volatile private var depthBackend = ""
        @Volatile private var matteBackend = ""
        @Volatile private var depthInferMs = 0.0
        @Volatile private var matteProcessMs = 0.0
        private var pendingCapturedNs = 0L
        @Volatile private var matteLatencyMs = 0.0
        private data class Matte(val epoch: Long, val token: Long)
        @Volatile private var matteResult: Matte? = null
        private var matteWorkToken = 0L
        private var matteStage = 0L
        private var matteStageToken = 0L
        private var matteRetiring = 0L
        private var matteTexture = 0
        private var matteRuntime: RvmRuntime? = null // RvmWorkers.video only
        private var matteEpoch = 0L
        private var matteAcceptedFrame = 0L
        private var lastMatte = 0L
        private val sessionId = sessionIds.getAndIncrement()
        private val matteLease = WebBrowserMatteLease(sessionId)
        private val matteSize = 256
        private val matteRgb = direct(matteSize * matteSize * 12)
        private val matteRightRgb = direct(matteRgb.capacity())
        private val matteLeft = direct(matteSize * matteSize * 4)
        private val matteRight = direct(matteLeft.capacity())
        private val matteBytes = ByteBuffer.allocateDirect(matteSize * matteSize)
        private var matteContent = floatArrayOf(0f, 0f, 1f, 1f)
        private val shot = PortraitShotDetector()
        private val shotPixels = ByteBuffer.allocateDirect(PortraitShotDetector.WIDTH * PortraitShotDetector.HEIGHT * 4)
        private var pendingEpoch = 0L
        private var pendingFrame = 0L
        private var pendingDepth = false
        @Volatile private var shownEpoch = -1L
        @Volatile private var shownFrame = -1L
        private data class Near(val left: ByteBuffer, val right: ByteBuffer)
        private val mapLock = Any()
        @Volatile private var latest: Near? = null
        private var reading: Near? = null
        private var display = EGL14.EGL_NO_DISPLAY
        private var egl = EGL14.EGL_NO_CONTEXT
        private var target = EGL14.EGL_NO_SURFACE
        private var source: SurfaceTexture? = null
        private var renderer = 0L
        private var pending = 0L
        private var retiring = 0L
        private var latched = false
        private var shown = 0L
        private var maskUploaded = false
        private var model = 0L // DepthWorker only
        private var modelRevision = -1L
        private var modelFrame = 0L
        private var program = 0
        private var vao = 0
        private var lastInference = 0L
        private var submittedRevision = -1L
        @Volatile private var submittedFrame = -1L
        private var dirty = true
        private val dims = DepthNative.PROFILE.split('x').map(String::toInt)
        private val rgbInput = direct(dims[0] * dims[1] * 12)
        private val rawInput = direct(dims[0] * dims[1] * 4)
        private val nearPool = Array(3) { Near(direct(rawInput.capacity()), direct(rawInput.capacity())) }
        private val matrix = FloatArray(16)
        private val transform = FloatArray(16)
        private val content = IntArray(4)
        fun configure(value: Float, position: Float, key: String, filled: Boolean, depth: Boolean) {
            if (!value.isFinite() || !position.isFinite()) return
            strength = value.coerceIn(0f, 2f); convergence = .35f - position.coerceIn(-100f, 100f) * .003f
            fill = filled
            depthEnabled = depth
            if (identity != key) { identity = key; revision++; matteLease.move(revision); synchronized(mapLock) { latest = null } }
            gl.post { dirty = true }
        }
        fun status(): String = JSONObject().put("frames", frames).put("maps", maps).put("error", error)
            .put("depth_backend", depthBackend).put("matte_backend", matteBackend)
            .put("depth_infer_ms_avg", depthInferMs).put("matte_process_ms_avg", matteProcessMs)
            .put("matte_latency_ms_avg", matteLatencyMs)
            .put("depth_frame_id", submittedFrame).put("shown_frame_id", shownFrame)
            .put("matte_frames", matteFrames).put("matte_frame_id",matteAcceptedFrame).put("state", if (error.isNotEmpty()) "failed" else if (matte && (matteFrames == 0L || shownEpoch != revision) || depthEnabled && strength > 0f && latest == null) "preparing" else "ready").toString()
        fun start() { gl.post { try { create(); tick() } catch (e: Throwable) { fail(e) } } }
        private fun create() {
            display = EGL14.eglGetDisplay(EGL14.EGL_DEFAULT_DISPLAY)
            check(EGL14.eglInitialize(display, IntArray(2), 0, IntArray(2), 1))
            val configs = arrayOfNulls<EGLConfig>(1)
            val attributes = intArrayOf(EGL14.EGL_RENDERABLE_TYPE, 0x40, EGL14.EGL_SURFACE_TYPE, EGL14.EGL_WINDOW_BIT,
                EGL14.EGL_RED_SIZE, 8, EGL14.EGL_GREEN_SIZE, 8, EGL14.EGL_BLUE_SIZE, 8, EGL14.EGL_ALPHA_SIZE, 8, EGL14.EGL_NONE)
            check(EGL14.eglChooseConfig(display, attributes, 0, configs, 0, 1, IntArray(1), 0))
            egl = EGL14.eglCreateContext(display, configs[0], EGL14.EGL_NO_CONTEXT, intArrayOf(EGL14.EGL_CONTEXT_CLIENT_VERSION, 3, EGL14.EGL_NONE), 0)
            target = EGL14.eglCreateWindowSurface(display, configs[0], output, intArrayOf(EGL14.EGL_NONE), 0)
            check(egl != EGL14.EGL_NO_CONTEXT && target != EGL14.EGL_NO_SURFACE)
            check(EGL14.eglMakeCurrent(display, target, target, egl))
            EGL14.eglSwapInterval(display, 0)
            renderer = RenderBridgeNative.create(width, height, dims[0], dims[1], false)
            check(renderer != 0L)
            RenderBridgeNative.setSlotLimit(renderer, 2); RenderBridgeNative.enableEdgeFill(renderer)
            val rect = RenderBridgeNative.fullInputRect(renderer)
            content[0] = ceil(rect[0] * dims[0]).toInt(); content[1] = ceil(rect[1] * dims[1]).toInt()
            content[2] = (rect[2] * dims[0]).toInt().coerceAtLeast(1); content[3] = (rect[3] * dims[1]).toInt().coerceAtLeast(1)
            source = SurfaceTexture(RenderBridgeNative.oesTexture(renderer)).apply {
                setDefaultBufferSize(sourceWidth, sourceHeight)
                setOnFrameAvailableListener({ available.set(true) }, gl)
            }
            input = Surface(source)
            program = link(VERTEX, FRAGMENT)
            val names = IntArray(1); GLES30.glGenVertexArrays(1, names, 0); vao = names[0]
            GLES30.glUseProgram(program)
            GLES30.glUniform4fv(GLES30.glGetUniformLocation(program, "content"), 1, rect, 0)
            if (matte) {
                matteStage = RenderBridgeNative.create(width, height, matteSize, matteSize, false)
                check(matteStage != 0L && RenderBridgeNative.enableBorrowedColor(matteStage))
                RenderBridgeNative.setSlotLimit(matteStage, 2)
                matteContent = RenderBridgeNative.fullInputRect(matteStage)
                GLES30.glGenTextures(1, names, 0); matteTexture = names[0]
                GLES30.glBindTexture(GLES30.GL_TEXTURE_2D, matteTexture)
                GLES30.glTexParameteri(GLES30.GL_TEXTURE_2D, GLES30.GL_TEXTURE_MIN_FILTER, GLES30.GL_LINEAR)
                GLES30.glTexParameteri(GLES30.GL_TEXTURE_2D, GLES30.GL_TEXTURE_MAG_FILTER, GLES30.GL_LINEAR)
                GLES30.glTexParameteri(GLES30.GL_TEXTURE_2D, GLES30.GL_TEXTURE_WRAP_S, GLES30.GL_CLAMP_TO_EDGE)
                GLES30.glTexParameteri(GLES30.GL_TEXTURE_2D, GLES30.GL_TEXTURE_WRAP_T, GLES30.GL_CLAMP_TO_EDGE)
                GLES30.glTexImage2D(GLES30.GL_TEXTURE_2D, 0, GLES30.GL_R8, matteSize, matteSize, 0, GLES30.GL_RED, GLES30.GL_UNSIGNED_BYTE, null)
            }
            // Never flash the opaque page while the first person's mask is preparing.
            GLES30.glBindFramebuffer(GLES30.GL_FRAMEBUFFER, 0); GLES30.glClearColor(0f,0f,0f,0f)
            GLES30.glClear(GLES30.GL_COLOR_BUFFER_BIT); check(EGL14.eglSwapBuffers(display, target))
        }
        private fun tick() {
            if (closed.get() || error.isNotEmpty()) return
            try {
                if (retiring != 0L && RenderBridgeNative.retired(renderer, retiring)) retiring = 0
                if (matteRetiring != 0L && RenderBridgeNative.retired(matteStage, matteRetiring)) matteRetiring = 0
                if (pending != 0L && RenderBridgeNative.ready(renderer, pending)) {
                    if (!pendingDepth && !busy && System.nanoTime() - lastInference > 66_666_666L && strength > 0f && depthEnabled) {
                        val rgb = rgbInput
                        if (RenderBridgeNative.readMonoInput(renderer, pending, rgb)) { infer(rgb, pendingEpoch, pendingFrame); pendingDepth = true }
                    }
                    if (matte && pendingEpoch != revision && !matteBusy && matteRetiring == 0L) {
                        if (matteStageToken != 0L) { RenderBridgeNative.retire(matteStage, matteStageToken); matteRetiring = matteStageToken; matteStageToken = 0 }
                        RenderBridgeNative.retire(renderer, pending); retiring = pending; pending = 0; matteWorkToken = 0; matteResult = null
                    } else if (!matte || prepareMatte()) {
                        if (shown != 0L) { RenderBridgeNative.retire(renderer, shown); retiring = shown }
                        shown = pending; shownEpoch = pendingEpoch; shownFrame = pendingFrame; pending = 0; maskUploaded = false; dirty = true
                    }
                }
                if (pending == 0L && retiring == 0L && (latched || available.getAndSet(false))) {
                    if (!latched) { source!!.updateTexImage(); source!!.getTransformMatrix(matrix); latched = true }
                    WebBrowserDepthGeometry.transform(matrix, crop, transform)
                    pending = RenderBridgeNative.capture(renderer, transform)
                    if (pending != 0L) { latched = false; frames++; pendingFrame = frames; pendingEpoch = revision; pendingDepth = false; pendingCapturedNs = System.nanoTime() }
                }
                if (shown != 0L && dirty) dirty = !draw()
                // Catch up to an already captured newer frame as soon as the worker is free.
                // Waiting for another Surface callback unnecessarily quantizes AI cadence to
                // capture timing. Never re-infer a static frame or go behind an inferred pending frame.
                if (shown != 0L && shownEpoch == revision && !busy && strength > 0f && depthEnabled &&
                    (submittedRevision != revision || shownFrame > submittedFrame) && System.nanoTime() - lastInference > 66_666_666L) {
                    val rgb = rgbInput
                    if (RenderBridgeNative.readMonoInput(renderer, shown, rgb)) infer(rgb, revision, shownFrame)
                }
                gl.postDelayed(::tick, 8)
            } catch (e: Throwable) { fail(e) }
        }
        private fun prepareMatte(): Boolean {
            val completed = matteResult
            if (completed != null && completed.token == pending && completed.epoch == revision) {
                if (matteRetiring != 0L && !RenderBridgeNative.retired(matteStage, matteRetiring)) return false
                matteRetiring = 0
                matteLatencyMs = matteLatencyMs * .9 + (System.nanoTime() - pendingCapturedNs) / 1e6 * .1
                matteBytes.clear()
                for (i in 0 until matteSize * matteSize) matteBytes.put((matteLeft.getFloat(i*4).coerceIn(0f,1f)*255f).roundToInt().toByte())
                matteBytes.flip()
                GLES30.glActiveTexture(GLES30.GL_TEXTURE0); GLES30.glBindTexture(GLES30.GL_TEXTURE_2D, matteTexture)
                GLES30.glPixelStorei(GLES30.GL_UNPACK_ALIGNMENT, 1)
                GLES30.glTexSubImage2D(GLES30.GL_TEXTURE_2D,0,0,0,matteSize,matteSize,GLES30.GL_RED,GLES30.GL_UNSIGNED_BYTE,matteBytes)
                matteWorkToken = 0; matteResult = null; matteFrames++
                return true
            }
            if (matteWorkToken != 0L || matteBusy || matteRetiring != 0L || System.nanoTime() - lastMatte < 50_000_000L) return false
            if (matteStageToken == 0L) matteStageToken = RenderBridgeNative.captureTexture(matteStage, RenderBridgeNative.texture(renderer,pending), true)
            if (matteStageToken == 0L || !RenderBridgeNative.ready(matteStage,matteStageToken)) return false
            if (!RenderBridgeNative.readMonoInput(matteStage,matteStageToken,matteRgb)) return false
            RenderBridgeNative.retire(matteStage,matteStageToken); matteRetiring = matteStageToken; matteStageToken = 0
            val ticket = matteLease.begin(pendingEpoch,frames,pending) ?: return false
            matteWorkToken = pending; matteBusy = true; lastMatte = System.nanoTime()
            val token = pending; val epoch = pendingEpoch; val frame = frames
            val pts = System.nanoTime()/1000
            RvmWorkers.video.post {
                try {
                    if (closed.get()) return@post
                    val generation = epoch + 1
                    if (matteRuntime == null) {
                        RvmNative.configureGpu(RvmWarmup.cacheDirectory(host).absolutePath,RvmNative.fp16())
                        matteRuntime = ModelPreparationGate.run { RvmRuntime.prepare(host.assets,true,"${matteSize}x$matteSize",sessionId,generation) }
                        matteEpoch = generation
                    }
                    if (generation > matteEpoch) { check(matteRuntime!!.reset(generation)); matteEpoch = generation }
                    val plane = matteSize * matteSize
                    for (y in 0 until PortraitShotDetector.HEIGHT) for (x in 0 until PortraitShotDetector.WIDTH) {
                        val at = y*matteSize/PortraitShotDetector.HEIGHT*matteSize + x*matteSize/PortraitShotDetector.WIDTH
                        val to = (y*PortraitShotDetector.WIDTH+x)*4
                        for (c in 0..2) shotPixels.put(to+c,(matteRgb.getFloat((c*plane+at)*4)*255f).roundToInt().coerceIn(0,255).toByte())
                        shotPixels.put(to+3,255.toByte())
                    }
                    val cut = shot.observe(shotPixels,pts).cut
                    matteRightRgb.clear(); matteRightRgb.put(matteRgb.duplicate().apply { clear() }); matteRightRgb.clear()
                    val started = System.nanoTime()
                    val result = matteRuntime!!.process(generation,frame,pts,matteRgb,matteRightRgb,matteLeft,matteRight,0,cut,1)
                    matteProcessMs = matteProcessMs * .9 + (System.nanoTime() - started) / 1e6 * .1
                    matteBackend = result.optString("backend")
                    check(result.optString("state") == "ready")
                    if (matteLease.finish(ticket) && !closed.get() && epoch == revision) { matteAcceptedFrame = frame; matteResult = Matte(epoch,token) }
                } catch (e: Throwable) { fail(e) }
                finally { matteLease.finish(ticket); matteBusy = false }
            }
            return false
        }
        private fun infer(rgb: ByteBuffer, generation: Long, frame: Long) {
            busy = true; lastInference = System.nanoTime(); submittedRevision = generation; submittedFrame = frame
            DepthWorker.handler.post {
                try {
                    if (closed.get()) return@post
                    if (model == 0L) model = ModelPreparationGate.run {
                        DepthNative.videoModelFile(host)?.let { DepthNative.createFromFile(it.path, DepthWarmup.cacheDirectory(host).absolutePath) }
                            ?: DepthNative.create(host.assets, DepthWarmup.cacheDirectory(host).absolutePath)
                    }
                    check(model != 0L)
                    if (depthBackend.isEmpty()) depthBackend = JSONObject(DepthNative.describe(model)).optString("backend")
                    val raw = rawInput
                    val near = synchronized(mapLock) { nearPool.first { it !== latest && it !== reading } }
                    val started = System.nanoTime()
                    DepthNative.infer(model, rgb, raw)
                    depthInferMs = depthInferMs * .9 + (System.nanoTime() - started) / 1e6 * .1
                    val reset = modelRevision != generation
                    val result = JSONObject(DepthNative.stabilize(model, raw, rgb, near.left, reset, if (reset) 1 else (frame - modelFrame).coerceIn(1L, 1000L).toInt(),
                        content[0], content[1], content[2], content[3]))
                    modelRevision = generation; modelFrame = frame
                    if (result.optString("state") != "ready") { submittedRevision = -1; return@post }
                    near.right.clear(); near.right.put(near.left.duplicate().apply { clear() }); near.right.clear()
                    synchronized(mapLock) {
                        if (!closed.get() && generation == revision) { latest = near; maps++; gl.post { dirty = true } }
                    }
                } catch (e: Throwable) { error = "Depth: " + e.javaClass.simpleName; android.util.Log.w("BrowserDepth", "Depth pipeline unavailable", e) }
                finally { busy = false }
            }
        }
        private fun draw(): Boolean {
            if (matte && shownEpoch != revision) {
                GLES30.glBindFramebuffer(GLES30.GL_FRAMEBUFFER,0); GLES30.glClearColor(0f,0f,0f,0f)
                GLES30.glClear(GLES30.GL_COLOR_BUFFER_BIT); check(EGL14.eglSwapBuffers(display,target)); return true
            }
            var texture = RenderBridgeNative.texture(renderer, shown)
            val near = synchronized(mapLock) { latest.also { reading = it } }
            var packed = false
            var depthReady = false
            if (near != null && strength > 0f && depthEnabled) {
                if (!maskUploaded) {
                    // Player slots accept a mask exactly once, with non-overlapping eye buffers.
                    try { check(RenderBridgeNative.uploadAlpha(renderer, shown, near.left, near.right)) }
                    finally { synchronized(mapLock) { reading = null } }
                    maskUploaded = true
                }
                RenderBridgeNative.limitNear(renderer, shown, .0175f * strength)
                depthReady = RenderBridgeNative.alphaReady(renderer, shown)
                if (fill && depthReady) {
                    val warped = if (matte) RenderBridgeNative.warpAlpha(renderer,shown,.0175f*strength,convergence,matteTexture,matteContent)
                        else RenderBridgeNative.warp(renderer, shown, .0175f * strength, convergence)
                    if (warped != 0) { texture = warped; packed = true }
                }
            }
            synchronized(mapLock) { reading = null }
            GLES30.glBindFramebuffer(GLES30.GL_FRAMEBUFFER, 0)
            GLES30.glViewport(0, 0, width * 2, height)
            GLES30.glUseProgram(program); GLES30.glBindVertexArray(vao)
            GLES30.glActiveTexture(GLES30.GL_TEXTURE0); GLES30.glBindTexture(GLES30.GL_TEXTURE_2D, texture)
            GLES30.glUniform1i(GLES30.glGetUniformLocation(program, "color"), 0)
            GLES30.glActiveTexture(GLES30.GL_TEXTURE1)
            GLES30.glBindTexture(GLES30.GL_TEXTURE_2D, if (depthReady) RenderBridgeNative.alphaTexture(renderer, shown) else 0)
            GLES30.glUniform1i(GLES30.glGetUniformLocation(program, "depth"), 1)
            GLES30.glUniform1f(GLES30.glGetUniformLocation(program, "shift"), if (depthReady && !packed) .0175f * strength else 0f)
            GLES30.glUniform1f(GLES30.glGetUniformLocation(program, "convergence"), convergence)
            GLES30.glUniform1i(GLES30.glGetUniformLocation(program, "stereo_pair"), if (packed) 1 else 0)
            GLES30.glActiveTexture(GLES30.GL_TEXTURE2); GLES30.glBindTexture(GLES30.GL_TEXTURE_2D,matteTexture)
            GLES30.glUniform1i(GLES30.glGetUniformLocation(program,"matte_map"),2)
            GLES30.glUniform1i(GLES30.glGetUniformLocation(program,"matte_enabled"),if (matte) 1 else 0)
            GLES30.glUniform4fv(GLES30.glGetUniformLocation(program,"matte_content"),1,matteContent,0)
            GLES30.glDrawArrays(GLES30.GL_TRIANGLES, 0, 3)
            check(EGL14.eglSwapBuffers(display, target))
            // Retry the held frame once the non-blocking Alpha upload fence signals.
            return near == null || strength <= 0f || !depthEnabled || depthReady
        }
        private fun fail(e: Throwable) { error = e.javaClass.simpleName; android.util.Log.e("BrowserDepth", "Browser 3D unavailable", e) }
        fun stop(): Boolean {
            matteLease.close()
            if (closed.compareAndSet(false, true)) gl.post {
                try {
                    input?.release(); input = null; source?.release()
                    if (matteStage != 0L) RenderBridgeNative.close(matteStage)
                    if (renderer != 0L) RenderBridgeNative.close(renderer)
                    if (matteTexture != 0) GLES30.glDeleteTextures(1,intArrayOf(matteTexture),0)
                    if (program != 0) GLES30.glDeleteProgram(program)
                    if (vao != 0) GLES30.glDeleteVertexArrays(1, intArrayOf(vao), 0)
                    if (display != EGL14.EGL_NO_DISPLAY) {
                        EGL14.eglMakeCurrent(display, EGL14.EGL_NO_SURFACE, EGL14.EGL_NO_SURFACE, EGL14.EGL_NO_CONTEXT)
                        if (target != EGL14.EGL_NO_SURFACE) EGL14.eglDestroySurface(display, target)
                        if (egl != EGL14.EGL_NO_CONTEXT) EGL14.eglDestroyContext(display, egl)
                        // EGLDisplay is process-shared; do not terminate Godot's display connection.
                    }
                } finally { done.countDown(); thread.quitSafely() }
            }
            DepthWorker.handler.post { if (closed.get() && model != 0L) { DepthNative.close(model); model = 0 } }
            RvmWorkers.video.post { if (closed.get()) { matteRuntime?.close(); matteRuntime = null } }
            return try { done.await(1500, TimeUnit.MILLISECONDS) } catch (_: InterruptedException) { Thread.currentThread().interrupt(); false }
        }
    }
    private fun direct(bytes: Int) = ByteBuffer.allocateDirect(bytes).order(ByteOrder.nativeOrder())
    private fun link(vertex: String, fragment: String): Int {
        fun shader(type: Int, source: String): Int {
            val s = GLES30.glCreateShader(type); GLES30.glShaderSource(s, source); GLES30.glCompileShader(s)
            val ok = IntArray(1); GLES30.glGetShaderiv(s, GLES30.GL_COMPILE_STATUS, ok, 0)
            check(ok[0] != 0) { GLES30.glGetShaderInfoLog(s) }; return s
        }
        val v = shader(GLES30.GL_VERTEX_SHADER, vertex); val f = shader(GLES30.GL_FRAGMENT_SHADER, fragment)
        val p = GLES30.glCreateProgram(); GLES30.glAttachShader(p, v); GLES30.glAttachShader(p, f); GLES30.glLinkProgram(p)
        GLES30.glDeleteShader(v); GLES30.glDeleteShader(f)
        val ok = IntArray(1); GLES30.glGetProgramiv(p, GLES30.GL_LINK_STATUS, ok, 0)
        check(ok[0] != 0) { GLES30.glGetProgramInfoLog(p) }; return p
    }
    private const val VERTEX = """#version 300 es
out vec2 uv;
void main(){ vec2 p=vec2(float((gl_VertexID<<1)&2),float(gl_VertexID&2)); uv=vec2(p.x,1.0-p.y); gl_Position=vec4(p*2.0-1.0,0,1); }
"""
    // Same bounded inverse warp as video_rvm_pair.gdshader; model input is letterboxed.
    private const val FRAGMENT = """#version 300 es
precision highp float;
uniform sampler2D color; uniform sampler2D depth; uniform vec4 content;
uniform float shift; uniform float convergence; uniform bool stereo_pair;
uniform sampler2D matte_map; uniform bool matte_enabled; uniform vec4 matte_content;
in vec2 uv; out vec4 result;
float nearAt(vec2 p){vec2 size=vec2(textureSize(depth,0))*vec2(0.5,1.0); vec2 q=clamp(content.xy+p*content.zw,vec2(0.5)/size,1.0-vec2(0.5)/size); return texture(depth,vec2(q.x*0.5,q.y)).r;}
void main(){
 if(stereo_pair){result=texture(color,uv);return;}
 float eye=step(0.5,uv.x); vec2 p=vec2(fract(uv.x*2.0),uv.y);
 if(shift>0.0){float side=1.0-2.0*eye; float k=shift*0.5;
 float a=p.x-side*(1.0-convergence)*k,b=p.x+side*convergence*k; float lo=min(a,b),hi=max(a,b);
 for(int i=0;i<6;i++){float x=(lo+hi)*0.5; if(x+side*(nearAt(vec2(x,p.y))-convergence)*k>p.x)hi=x;else lo=x;}
 p.x=p.x-side*(nearAt(vec2((lo+hi)*0.5,p.y))-convergence)*k;}
 p=clamp(p,vec2(0),vec2(1)); float a=1.0;
 if(matte_enabled){vec2 half_pixel=0.5/vec2(textureSize(matte_map,0));a=texture(matte_map,clamp(matte_content.xy+p*matte_content.zw,half_pixel,1.0-half_pixel)).r;}
 result=vec4(texture(color,p).rgb*a,a);
}
"""
}
