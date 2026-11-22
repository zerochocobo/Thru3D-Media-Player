package org.vrpassthroughplayer.plugin

import android.opengl.GLES30

/** Picture quality mode on a browser effect thread: the thread draws its page into [begin]'s offscreen
 * texture, as it would into its surface, and [finish] draws that into the surface denoised, sharpened and
 * graded over the video's region (the player's passes, video_layer.cpp). GL calls on that thread only. */
internal class WebBrowserPicture {
    /** The player's look (sharpen strength, grade or null, denoise step and tolerance) and the region it
     * covers in each eye's UV, rows as the surface's (its first row the bottom). */
    class Look(val sharpen: Float, val grade: FloatArray?, val denoiseStep: Float, val denoiseTolerance: Float, val region: FloatArray)

    companion object {
        const val VALUES = 19
        /** Godot's values: sharpen, graded (0 or 1), 11 grade values, denoise step and tolerance, then the
         * region x, y, width, height in the eye's top-left UV. Null for none, or nothing for it to do. */
        fun look(values: FloatArray): Look? {
            if (values.size != VALUES || values.any { !it.isFinite() }) return null
            val x0 = values[15].coerceIn(0f, 1f); val y0 = values[16].coerceIn(0f, 1f)
            val x1 = (values[15] + values[17]).coerceIn(0f, 1f); val y1 = (values[16] + values[18]).coerceIn(0f, 1f)
            val graded = values[1] > .5f
            if (x1 <= x0 || y1 <= y0 || values[0] <= 0f && !graded && values[14] <= 0f) return null
            return Look(values[0].coerceIn(0f, 2f), if (graded) values.copyOfRange(2, 13) else null,
                values[13].coerceAtLeast(0f), values[14].coerceAtLeast(0f), floatArrayOf(x0, 1f - y1, x1, 1f - y0))
        }
    }

    private var enhancer = 0L
    private var framebuffer = 0
    private var texture = 0
    private var width = 0
    private var height = 0
    /** A draw failed: the thread shows its page as it is for the rest of its life. */
    var failed = !VideoLayerNative.available()
        private set

    /** Binds an offscreen target of width x height for the page's draw; false (framebuffer 0 bound) when
     * the mode cannot run. */
    fun begin(w: Int, h: Int): Boolean {
        if (failed) { GLES30.glBindFramebuffer(GLES30.GL_FRAMEBUFFER, 0); return false }
        if (texture == 0 || w != width || h != height) {
            deleteTarget()
            val names = IntArray(1)
            GLES30.glGenTextures(1, names, 0); texture = names[0]
            GLES30.glBindTexture(GLES30.GL_TEXTURE_2D, texture)
            GLES30.glTexStorage2D(GLES30.GL_TEXTURE_2D, 1, GLES30.GL_RGBA8, w, h)
            GLES30.glTexParameteri(GLES30.GL_TEXTURE_2D, GLES30.GL_TEXTURE_MIN_FILTER, GLES30.GL_LINEAR)
            GLES30.glTexParameteri(GLES30.GL_TEXTURE_2D, GLES30.GL_TEXTURE_MAG_FILTER, GLES30.GL_LINEAR)
            GLES30.glTexParameteri(GLES30.GL_TEXTURE_2D, GLES30.GL_TEXTURE_WRAP_S, GLES30.GL_CLAMP_TO_EDGE)
            GLES30.glTexParameteri(GLES30.GL_TEXTURE_2D, GLES30.GL_TEXTURE_WRAP_T, GLES30.GL_CLAMP_TO_EDGE)
            GLES30.glGenFramebuffers(1, names, 0); framebuffer = names[0]
            GLES30.glBindFramebuffer(GLES30.GL_FRAMEBUFFER, framebuffer)
            GLES30.glFramebufferTexture2D(GLES30.GL_FRAMEBUFFER, GLES30.GL_COLOR_ATTACHMENT0, GLES30.GL_TEXTURE_2D, texture, 0)
            width = w; height = h
            if (GLES30.glCheckFramebufferStatus(GLES30.GL_FRAMEBUFFER) != GLES30.GL_FRAMEBUFFER_COMPLETE) { fail(); return false }
        }
        GLES30.glBindFramebuffer(GLES30.GL_FRAMEBUFFER, framebuffer)
        return true
    }

    /** Draws the offscreen page into the surface (framebuffer 0) with [look]; eyes: 2 for a stereo pair.
     * False: nothing was drawn and the mode is off from now on; the caller draws its page again directly. */
    fun finish(look: Look, eyes: Int, keepAlpha: Boolean): Boolean {
        GLES30.glBindFramebuffer(GLES30.GL_FRAMEBUFFER, 0)
        if (enhancer == 0L) enhancer = runCatching { VideoLayerNative.createEnhancer() }.getOrDefault(0L)
        val drawn = enhancer != 0L && runCatching {
            VideoLayerNative.enhanceToWindow(enhancer, texture, width, height, eyes, look.sharpen, look.grade,
                look.denoiseStep, look.denoiseTolerance, look.region, keepAlpha)
        }.getOrDefault(false)
        if (!drawn) fail()
        return drawn
    }

    fun release() {
        if (enhancer != 0L) runCatching { VideoLayerNative.destroyEnhancer(enhancer) }
        enhancer = 0L
        deleteTarget()
    }

    private fun fail() {
        failed = true
        android.util.Log.w("BrowserPicture", "Browser picture quality unavailable; showing the page as it is")
        GLES30.glBindFramebuffer(GLES30.GL_FRAMEBUFFER, 0)
        release()
    }

    private fun deleteTarget() {
        if (framebuffer != 0) GLES30.glDeleteFramebuffers(1, intArrayOf(framebuffer), 0)
        if (texture != 0) GLES30.glDeleteTextures(1, intArrayOf(texture), 0)
        framebuffer = 0; texture = 0; width = 0; height = 0
    }
}
