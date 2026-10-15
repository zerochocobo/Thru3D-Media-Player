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
    /** Producer surface of a new swapchain; destroys the previous one. */
    @JvmStatic external fun createSurface(width: Int, height: Int): Surface
    @JvmStatic external fun destroySurface()
    /** 20 floats per layer: see native/xr-layer/video_layer.cpp. Count 0 hides the video. */
    @JvmStatic external fun setLayers(count: Int, values: FloatArray): Boolean
    /** RGBA picture swapchain (2D->3D pairs, photos) on Godot's render thread: create, acquire,
     * fill (row slices or a GPU copy), then release (optionally mipmapped) before a layer shows it. */
    /** slot: 0 photos and 2D->3D pairs, 1 subtitles, 2 the photo magnifier. */
    @JvmStatic external fun createImage(slot: Int, width: Int, height: Int, levels: Int, isStatic: Boolean): Boolean
    @JvmStatic external fun destroyImage(slot: Int)
    @JvmStatic external fun acquireImage(slot: Int): Int
    @JvmStatic external fun uploadRows(slot: Int, y: Int, rows: Int, pixels: ByteArray, channels: Int): Boolean
    @JvmStatic external fun copyTexture(slot: Int, texture: Int): Boolean
    @JvmStatic external fun copyBand(slot: Int, texture: Int, y: Int, rows: Int): Boolean
    /** A colour band times an R8 mask band of the same size, premultiplied: a photo's portrait cutout. */
    @JvmStatic external fun copyBandMasked(slot: Int, color: Int, mask: Int, y: Int, rows: Int): Boolean
    /** Alpha plan B: RVM's packed R8 mask drawn over the frame layout (0 mono, 1 SBS, 2 TB) into the
     * acquired image of [slot] as alpha; rect maps eye UV to model UV (the pair's model_content_rect). */
    @JvmStatic external fun drawMask(slot: Int, mask: Int, rect: FloatArray, layout: Int, modelWidth: Int, modelHeight: Int,
                                     edgeLow: Float, edgeHigh: Float): Boolean
    /** Counts a released mask; [maskVersion] is what Godot polls before it shows the mask layer. */
    @JvmStatic external fun maskDrawn(): Long
    @JvmStatic external fun maskVersion(): Long
    /** GPU copy prototype: the compositor surface's buffer size (RGBA8) before the copy's EGL surface. */
    @JvmStatic external fun setWindowGeometry(surface: Surface, width: Int, height: Int): Boolean
    /** Draws a decoder buffer's [width] x [height] picture over the current EGL surface of [outWidth] x
     * [outHeight] (copy thread); flip puts its first row on top. */
    @JvmStatic external fun blitBuffer(buffer: android.hardware.HardwareBuffer, width: Int, height: Int, bufferWidth: Int, bufferHeight: Int,
                                       outWidth: Int, outHeight: Int, flip: Boolean): Boolean
    @JvmStatic external fun releaseBlit()
    @JvmStatic external fun releaseImage(slot: Int, mipmaps: Boolean): Boolean
    @JvmStatic external fun runtimeExtensions(): String
    /** Layers can carry a colour scale/bias (the colour grade) instead of leaving the compositor. */
    @JvmStatic external fun colorScaleBias(): Boolean
    @JvmStatic external fun layerCount(): Int
    @JvmStatic external fun layerAddress(index: Int): Long
}
