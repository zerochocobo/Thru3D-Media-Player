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
    @JvmStatic external fun createImage(width: Int, height: Int, levels: Int, isStatic: Boolean): Boolean
    @JvmStatic external fun destroyImage()
    @JvmStatic external fun acquireImage(): Int
    @JvmStatic external fun uploadRows(y: Int, rows: Int, pixels: ByteArray, channels: Int): Boolean
    @JvmStatic external fun copyTexture(texture: Int): Boolean
    @JvmStatic external fun copyBand(texture: Int, y: Int, rows: Int): Boolean
    @JvmStatic external fun releaseImage(mipmaps: Boolean): Boolean
    @JvmStatic external fun runtimeExtensions(): String
    /** Layers can carry a colour scale/bias (the colour grade) instead of leaving the compositor. */
    @JvmStatic external fun colorScaleBias(): Boolean
    @JvmStatic external fun layerCount(): Int
    @JvmStatic external fun layerAddress(index: Int): Long
}
