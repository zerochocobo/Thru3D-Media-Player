package org.vrpassthroughplayer.plugin

import android.graphics.SurfaceTexture
import android.opengl.GLES11Ext
import android.opengl.GLES30
import android.os.Handler
import android.os.Looper
import android.view.Surface
import java.util.concurrent.ConcurrentHashMap
import java.util.concurrent.atomic.AtomicBoolean
import java.util.concurrent.atomic.AtomicLong

/**
 * Browser pages on runtimes without Android-surface swapchains (the QIYU factory runtime): Gecko
 * draws into a SurfaceTexture behind a Godot ExternalTexture and the page is sampled in the eye
 * buffer. Godot's frame thread calls in; GL work runs on its render thread. Detach Gecko before release.
 */
object WebBrowserTextureBridge {
    private class Page(val token: Long, val texture: SurfaceTexture, val surface: Surface) {
        val scheduled = AtomicBoolean(false)
        val matrix = FloatArray(16)
        var frames = 0L
        var closed = false
    }
    private val pages = ConcurrentHashMap<Int, Page>()
    private val retiring = ConcurrentHashMap.newKeySet<Long>()
    private val tokens = AtomicLong(0)
    @Volatile private var render: ((Runnable) -> Unit)? = null
    internal fun install(run: (Runnable) -> Unit) { render = run }

    /** Token of the new producer for [id] (four browser windows and the login surface), or 0. */
    @JvmStatic fun create(id: Int, textureId: Int, width: Int, height: Int): Long {
        val run = render ?: return 0
        if (id !in 1..5 || textureId <= 0 || width !in 16..4096 || height !in 16..4096 || pages.containsKey(id)) return 0
        // No GL here: the consumer first touches the texture when a frame is latched.
        val texture = SurfaceTexture(textureId).apply { setDefaultBufferSize(width, height) }
        val page = Page(tokens.incrementAndGet(), texture, Surface(texture))
        // Latch every frame, shown or not: an unconsumed queue would stall Gecko's compositor.
        texture.setOnFrameAvailableListener({
            if (page.scheduled.compareAndSet(false, true)) run(Runnable {
                page.scheduled.set(false)
                synchronized(page) {
                    if (page.closed) return@Runnable
                    runCatching {
                        preserveOes { texture.updateTexImage() }
                        texture.getTransformMatrix(page.matrix); page.frames++
                    }
                }
            })
        }, Handler(Looper.getMainLooper()))
        pages[id] = page
        return page.token
    }

    @JvmStatic fun surface(id: Int, token: Long): Surface? = pages[id]?.takeIf { it.token == token }?.surface

    /** The latched frame's texture transform as 16 comma separated floats; empty before the first frame. */
    @JvmStatic fun frame(id: Int, token: Long): String {
        val page = pages[id]?.takeIf { it.token == token } ?: return ""
        return synchronized(page) { if (page.frames > 0) page.matrix.joinToString(",") else "" }
    }

    @JvmStatic fun release(id: Int, token: Long) {
        val page = pages[id]?.takeIf { it.token == token } ?: return
        pages.remove(id); retiring.add(token)
        val close = Runnable {
            synchronized(page) { page.closed = true; page.surface.release(); page.texture.release() }
            retiring.remove(token)
        }
        render?.invoke(close) ?: close.run()
    }

    /** Whether the render thread let go of a released producer's texture, so Godot may free it. */
    @JvmStatic fun released(token: Long): Boolean = !retiring.contains(token)

    private fun preserveOes(action: () -> Unit) {
        val binding = IntArray(1); GLES30.glGetIntegerv(GLES11Ext.GL_TEXTURE_BINDING_EXTERNAL_OES, binding, 0)
        try { action() } finally { GLES30.glBindTexture(GLES11Ext.GL_TEXTURE_EXTERNAL_OES, binding[0]) }
    }
}
