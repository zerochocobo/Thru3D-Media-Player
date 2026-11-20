package org.vrpassthroughplayer.plugin

import android.view.Surface

/** OpenXR video composition layers (native/xr-layer). Godot keeps the session and frame loop; a script
 * provider returns layerAddress(i) for layerCount() layers to Godot's frame end. */
internal object VideoLayerNative {
    private val loaded = try { System.loadLibrary("quest_video_layer"); true } catch (_: UnsatisfiedLinkError) { false }
    /** Resolves the swapchain functions; false when the runtime lacks Android-surface swapchains. */
    fun bindSession(instance: Long, session: Long, getProcAddr: Long, playSpace: Long) =
        loaded && runCatching { bind(instance, session, getProcAddr, playSpace) }.getOrDefault(false)
    @JvmStatic private external fun bind(instance: Long, session: Long, getProcAddr: Long, playSpace: Long): Boolean
    /** New producer; refuses replacement until the preceding decoder has released its Surface. */
    @JvmStatic external fun createSurface(width: Int, height: Int): Surface
    @JvmStatic external fun destroySurface()
    /** 28 floats per layer: see native/xr-layer/video_layer.cpp. Count 0 hides the video. */
    @JvmStatic external fun setLayers(count: Int, values: FloatArray): Boolean
    /** RGBA picture swapchain (2D->3D pairs, photos) on Godot's render thread: create, acquire,
     * fill (row slices or a GPU copy), then release (optionally mipmapped) before a layer shows it. */
    /** slot: 0 photos and 2D->3D pairs, 1 subtitles, 2 photo magnifier, 3 video PiP atlas. */
    @JvmStatic external fun createImage(slot: Int, width: Int, height: Int, levels: Int, isStatic: Boolean): Boolean
    @JvmStatic external fun destroyImage(slot: Int)
    @JvmStatic external fun acquireImage(slot: Int): Int
    @JvmStatic external fun uploadRows(slot: Int, y: Int, rows: Int, pixels: ByteArray, channels: Int): Boolean
    @JvmStatic external fun copyTexture(slot: Int, texture: Int): Boolean
    /** Fisheye frame remapped to equirect into the acquired image (params: see video_layer.cpp). */
    @JvmStatic external fun remapFisheye(slot: Int, texture: Int, external: Boolean, params: FloatArray): Boolean
    /** [remapFisheye] with picture quality mode's look (22 values, see video_layer.cpp's remap_fisheye). */
    /** Picture quality mode for the eye buffers: the frame drawn denoised, enlarged and sharpened into a
     * texture of width x height the native side keeps; its GL name, or 0 (see video_layer.cpp). */
    @JvmStatic external fun enhanceFrameTexture(texture: Int, external: Boolean, sourceWidth: Int, sourceHeight: Int,
                                                scaleX: Float, scaleY: Float, width: Int, height: Int,
                                                sharpen: Float, denoiseStep: Float, denoiseTolerance: Float): Int
    @JvmStatic external fun enhanceFisheye(slot: Int, texture: Int, external: Boolean, params: FloatArray, look: FloatArray): Boolean
    /** Runtime graphics limits: max layer count, swapchain image width, height. */
    @JvmStatic external fun compositorLimits(): String
    @JvmStatic external fun pipMetrics(): String
    @JvmStatic external fun pipSamples(request: Boolean): String
    @JvmStatic external fun pipMainSamples(request: Boolean): String
    @JvmStatic external fun renderPipFeatherMask(slot: Int, feathers: FloatArray): Boolean
    /** Production shader: active 1..7 selects guttered PiP rows; 8 processes the full main frame. */
    @JvmStatic external fun renderPip(slot: Int, color: Int, external: Boolean, mask: Int, active: Int, eyes: Int,
                                      common: FloatArray, windows: FloatArray): Boolean
    /** Automatic stereo focus of a fisheye frame (params: see video_layer.cpp); the pixels follow later. */
    @JvmStatic external fun probeFisheye(texture: Int, external: Boolean, params: FloatArray, width: Int, height: Int): Boolean
    @JvmStatic external fun takeFisheyeProbe(): ByteArray
    @JvmStatic external fun requestFisheyeReadback(step: Int)
    @JvmStatic external fun takeFisheyeReadback(): ByteArray
    @JvmStatic external fun copyBand(slot: Int, texture: Int, y: Int, rows: Int): Boolean
    /** A colour band times an R8 mask band of the same size, premultiplied: a photo's portrait cutout. */
    @JvmStatic external fun copyBandMasked(slot: Int, color: Int, mask: Int, y: Int, rows: Int): Boolean
    /** Alpha plan B: RVM's packed R8 mask drawn over the frame layout (0 mono, 1 SBS, 2 TB) into the
     * acquired image of [slot] as alpha; rect maps eye UV to model UV (the pair's model_content_rect). */
    @JvmStatic external fun drawMask(slot: Int, mask: Int, rect: FloatArray, layout: Int, modelWidth: Int, modelHeight: Int,
                                     edgeLow: Float, edgeHigh: Float, nextMask: Int, nextRect: FloatArray?, blend: Float): Boolean
    /** Counts a released mask; [maskVersion] is what Godot polls before it shows the mask layer. */
    @JvmStatic external fun maskDrawn(): Long
    @JvmStatic external fun maskVersion(): Long
    /** GPU copy prototype: the compositor surface's buffer size before the copy's EGL surface; RGBA8, or
     * 10 bits a channel when [deep]. */
    @JvmStatic external fun setWindowGeometry(surface: Surface, width: Int, height: Int, deep: Boolean): Boolean
    /** The ADataSpace the compositor reads the copy's buffers in (HDR), after the copy's EGL surface. */
    @JvmStatic external fun setWindowDataSpace(surface: Surface, dataSpace: Int): Boolean
    /** Draws a decoder buffer's [width] x [height] picture over the current EGL surface of [outWidth] x
     * [outHeight] (copy thread); flip puts its first row on top. [quality] (picture quality mode):
     * [sharpen] 0..1 sharpens it (RCAS), within [window] when given: centre u, v and half width, height in
     * one eye's UV, eyes across and down, 1 when longitude wraps, 1 to tint the window (debug); [grade] is
     * the colour grade: gain, gamma and offset per channel, contrast, saturation. A [denoiseTolerance]
     * above 0 denoises first, its samples [denoiseStep] source pixels apart; a negative [sharpen] holds
     * the window's work back while no direction is known. */
    @JvmStatic external fun blitBuffer(buffer: android.hardware.HardwareBuffer, width: Int, height: Int, bufferWidth: Int, bufferHeight: Int,
                                       outWidth: Int, outHeight: Int, flip: Boolean, quality: Boolean, sharpen: Float,
                                       window: FloatArray?, grade: FloatArray?, denoiseStep: Float, denoiseTolerance: Float): Boolean
    /** Smoothed GPU milliseconds of one [blitBuffer]; 0 without a timer or before its first result. */
    @JvmStatic external fun blitGpuMs(): Double
    /** Memory saver: copies a decoder buffer into packed [slot] (luma + half-size chroma) at [outWidth] x
     * [outHeight] on the copy thread; the buffer is free for the decoder when this returns. */
    @JvmStatic external fun packBuffer(buffer: android.hardware.HardwareBuffer, width: Int, height: Int, bufferWidth: Int, bufferHeight: Int,
                                       outWidth: Int, outHeight: Int, flip: Boolean, slot: Int): Boolean
    /** Draws packed [slot] over the current EGL surface (the layer window). */
    @JvmStatic external fun drawPacked(slot: Int): Boolean
    @JvmStatic external fun releaseBlit()
    /** Picture quality mode on the picture layer: draws a GL texture of [sourceWidth] x [sourceHeight] into
     * the acquired image of [slot], enlarged (EASU) when the image is larger, sharpened and graded as the
     * layer copy does ([grade]: 11 values, or null). For frames a software decoder made. */
    @JvmStatic external fun enhanceTexture(slot: Int, texture: Int, sourceWidth: Int, sourceHeight: Int, sharpen: Float, grade: FloatArray?,
                                           denoiseStep: Float, denoiseTolerance: Float): Boolean
    @JvmStatic external fun releaseImage(slot: Int, mipmaps: Boolean): Boolean
    @JvmStatic external fun runtimeExtensions(): String
    /** Layers can carry a colour scale/bias (the colour grade) instead of leaving the compositor. */
    @JvmStatic external fun colorScaleBias(): Boolean
    /** The instance enabled XR_QIYU_passthrough (iQIYI QIYU factory runtime). */
    @JvmStatic external fun qiyuPassthrough(): Boolean
    /** Starts/pauses QIYU passthrough: its layer's address, 0 when paused or absent, or a negative XrResult. */
    @JvmStatic external fun qiyuPassthroughLayer(enabled: Boolean): Long
    @JvmStatic external fun layerCount(): Int
    @JvmStatic external fun layerAddress(index: Int): Long
}
