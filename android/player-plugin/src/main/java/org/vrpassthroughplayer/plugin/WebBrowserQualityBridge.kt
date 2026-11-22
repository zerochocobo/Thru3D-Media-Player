package org.vrpassthroughplayer.plugin

import android.graphics.SurfaceTexture
import android.opengl.EGL14
import android.opengl.EGLConfig
import android.opengl.GLES11Ext
import android.opengl.GLES30
import android.os.Handler
import android.os.HandlerThread
import android.view.Surface
import org.json.JSONObject
import java.util.concurrent.ConcurrentHashMap
import java.util.concurrent.CountDownLatch
import java.util.concurrent.TimeUnit
import java.util.concurrent.atomic.AtomicBoolean
import java.util.concurrent.atomic.AtomicInteger

/** Picture quality mode for a 2D browser page: Gecko draws into [surface] instead of the page's layer, and
 * each page frame is drawn into the layer's surface with the video's region enhanced (WebBrowserPicture).
 * Only while the mode has a video to work on; otherwise Gecko keeps drawing into the layer directly. */
object WebBrowserQualityBridge {
    private val windows = ConcurrentHashMap<Int, Window>()
    private val stopping = ConcurrentHashMap<Int, AtomicInteger>()
    private val stops = java.util.concurrent.Executors.newSingleThreadExecutor { task -> Thread(task, "BrowserQualityStop").apply { isDaemon = true } }

    @JvmStatic fun start(id: Int, output: Surface, width: Int, height: Int): Boolean {
        if (id !in 1..4 || !output.isValid || width !in 256..4096 || height !in 256..4096) return false
        val window = Window(output, width, height)
        if (windows.putIfAbsent(id, window) != null) { window.stop(); return false }
        stopping.remove(id)
        window.start(); return true
    }
    @JvmStatic fun surface(id: Int): Surface? = windows[id]?.input
    /** WebBrowserPicture.look's values; empty for none (the page passes through). */
    @JvmStatic fun configure(id: Int, values: FloatArray) { windows[id]?.configure(values) }
    @JvmStatic fun status(id: Int): String = windows[id]?.status() ?: "{}"
    @JvmStatic fun requestStop(id: Int) {
        val old = stopping[id]
        if (old != null && old.get() >= 0) return
        val state = AtomicInteger(0); stopping[id] = state
        val owned = windows[id]
        stops.execute {
            val ok = runCatching { owned?.stop() ?: true }.getOrDefault(false)
            if (ok && owned != null) windows.remove(id, owned)
            state.set(if (ok) 1 else -1)
        }
    }
    @JvmStatic fun stopState(id: Int): Int = stopping[id]?.get() ?: if (windows[id] == null) 1 else 0
    /** Gecko must acknowledge surfaceDestroyed before this call; stops output before XR destruction. */
    @JvmStatic fun stop(id: Int): Boolean {
        val window = windows[id] ?: return true
        if (!window.stop()) return false
        windows.remove(id, window); return true
    }
    internal fun closeAll() { windows.keys.toList().forEach(::stop) }

    private class Window(val output: Surface, val width: Int, val height: Int) {
        private val thread = HandlerThread("Browser-Quality-GL").apply { start() }
        private val gl = Handler(thread.looper)
        private val closed = AtomicBoolean(false)
        private val done = CountDownLatch(1)
        @Volatile var input: Surface? = null
        @Volatile private var look: WebBrowserPicture.Look? = null
        @Volatile private var error = ""
        @Volatile private var frames = 0L
        @Volatile private var enhanced = 0L
        @Volatile private var drawMs = 0.0
        private val picture = WebBrowserPicture()
        private var display = EGL14.EGL_NO_DISPLAY
        private var egl = EGL14.EGL_NO_CONTEXT
        private var target = EGL14.EGL_NO_SURFACE
        private var source: SurfaceTexture? = null
        private var oes = 0
        private var program = 0
        private var vao = 0
        private var latched = false
        private val matrix = FloatArray(16)

        fun start() { gl.post { try { create() } catch (e: Throwable) { fail(e) } } }
        fun configure(values: FloatArray) {
            val next = WebBrowserPicture.look(values)
            if (next == null && look == null) return
            look = next
            gl.post { if (latched) draw() }
        }
        fun status(): String = JSONObject().put("frames", frames).put("enhanced", enhanced).put("error", error)
            .put("draw_ms_avg", drawMs)
            .put("quality", if (look == null) "off" else if (picture.failed) "failed" else "on")
            .put("state", if (error.isNotEmpty()) "failed" else "ready").toString()

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
            val names = IntArray(1)
            GLES30.glGenTextures(1, names, 0); oes = names[0]
            GLES30.glBindTexture(GLES11Ext.GL_TEXTURE_EXTERNAL_OES, oes)
            GLES30.glTexParameteri(GLES11Ext.GL_TEXTURE_EXTERNAL_OES, GLES30.GL_TEXTURE_MIN_FILTER, GLES30.GL_LINEAR)
            GLES30.glTexParameteri(GLES11Ext.GL_TEXTURE_EXTERNAL_OES, GLES30.GL_TEXTURE_MAG_FILTER, GLES30.GL_LINEAR)
            GLES30.glTexParameteri(GLES11Ext.GL_TEXTURE_EXTERNAL_OES, GLES30.GL_TEXTURE_WRAP_S, GLES30.GL_CLAMP_TO_EDGE)
            GLES30.glTexParameteri(GLES11Ext.GL_TEXTURE_EXTERNAL_OES, GLES30.GL_TEXTURE_WRAP_T, GLES30.GL_CLAMP_TO_EDGE)
            program = link()
            GLES30.glGenVertexArrays(1, names, 0); vao = names[0]
            // Every page frame is latched, shown or not: an unconsumed queue would stall Gecko's compositor.
            source = SurfaceTexture(oes).apply {
                setDefaultBufferSize(width, height)
                setOnFrameAvailableListener({ if (!closed.get() && error.isEmpty()) runCatching { latch() }.onFailure { fail(it) } }, gl)
            }
            input = Surface(source)
            GLES30.glClearColor(0f, 0f, 0f, 1f); GLES30.glClear(GLES30.GL_COLOR_BUFFER_BIT)
            check(EGL14.eglSwapBuffers(display, target))
        }

        private fun latch() {
            source!!.updateTexImage(); source!!.getTransformMatrix(matrix)
            latched = true; frames++
            draw()
        }

        /** The latest page frame into the layer: through the offscreen target and enhanced while there is a
         * look, else directly (also after a failed enhance). */
        private fun draw() {
            if (closed.get() || error.isNotEmpty()) return
            val started = System.nanoTime()
            val current = look
            val staged = current != null && picture.begin(width, height)
            GLES30.glViewport(0, 0, width, height)
            GLES30.glUseProgram(program); GLES30.glBindVertexArray(vao)
            GLES30.glActiveTexture(GLES30.GL_TEXTURE0); GLES30.glBindTexture(GLES11Ext.GL_TEXTURE_EXTERNAL_OES, oes)
            GLES30.glUniform1i(GLES30.glGetUniformLocation(program, "page"), 0)
            GLES30.glUniformMatrix4fv(GLES30.glGetUniformLocation(program, "transform"), 1, false, matrix, 0)
            GLES30.glDrawArrays(GLES30.GL_TRIANGLES, 0, 3)
            if (staged) {
                if (picture.finish(current!!, 1, false)) enhanced++
                else { draw(); return }
            }
            check(EGL14.eglSwapBuffers(display, target))
            val ms = (System.nanoTime() - started) / 1e6
            drawMs = if (drawMs == 0.0) ms else drawMs * .95 + ms * .05
        }

        private fun fail(e: Throwable) { error = e.javaClass.simpleName; android.util.Log.e("BrowserQuality", "Browser picture quality unavailable", e) }

        fun stop(): Boolean {
            if (closed.compareAndSet(false, true)) gl.post {
                try {
                    input?.release(); input = null; source?.release(); source = null
                    picture.release()
                    if (oes != 0) GLES30.glDeleteTextures(1, intArrayOf(oes), 0)
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
            return try { done.await(1500, TimeUnit.MILLISECONDS) } catch (_: InterruptedException) { Thread.currentThread().interrupt(); false }
        }
    }

    private fun link(): Int {
        fun shader(type: Int, source: String): Int {
            val s = GLES30.glCreateShader(type); GLES30.glShaderSource(s, source); GLES30.glCompileShader(s)
            val ok = IntArray(1); GLES30.glGetShaderiv(s, GLES30.GL_COMPILE_STATUS, ok, 0)
            check(ok[0] != 0) { GLES30.glGetShaderInfoLog(s) }; return s
        }
        val v = shader(GLES30.GL_VERTEX_SHADER, VERTEX); val f = shader(GLES30.GL_FRAGMENT_SHADER, FRAGMENT)
        val p = GLES30.glCreateProgram(); GLES30.glAttachShader(p, v); GLES30.glAttachShader(p, f); GLES30.glLinkProgram(p)
        GLES30.glDeleteShader(v); GLES30.glDeleteShader(f)
        val ok = IntArray(1); GLES30.glGetProgramiv(p, GLES30.GL_LINK_STATUS, ok, 0)
        check(ok[0] != 0) { GLES30.glGetProgramInfoLog(p) }; return p
    }
    // The SurfaceTexture's own transform, as any consumer showing it on a surface.
    private const val VERTEX = """#version 300 es
uniform mat4 transform;
out vec2 uv;
void main(){ vec2 p=vec2(float((gl_VertexID<<1)&2),float(gl_VertexID&2)); uv=(transform*vec4(p,0,1)).xy; gl_Position=vec4(p*2.0-1.0,0,1); }
"""
    private const val FRAGMENT = """#version 300 es
#extension GL_OES_EGL_image_external_essl3 : require
precision highp float;
uniform samplerExternalOES page;
in vec2 uv; out vec4 result;
void main(){ result=vec4(texture(page,uv).rgb,1.0); }
"""
}
