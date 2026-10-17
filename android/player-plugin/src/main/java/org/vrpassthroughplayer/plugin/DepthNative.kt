package org.vrpassthroughplayer.plugin

import android.content.Context
import android.content.res.AssetManager
import java.io.File
import java.nio.ByteBuffer

/** Realtime 2D->3D depth (Depth Anything V2 Small, MNN OpenCL) in libquest_rvm. Not thread-safe per handle. */
internal object DepthNative {
    // Loads libquest_rvm on first use of this object.
    val unavailable: String? = RvmNative.unavailable
    /** Compiled-program cache this model uses under [cacheDirectory]. */
    @JvmStatic external fun cachePath(assets: AssetManager, cacheDirectory: String?): String
    /** Builds the OpenCL session (a cold cache compiles for tens of seconds). */
    @JvmStatic external fun create(assets: AssetManager, cacheDirectory: String?): Long
    /** Independent still-photo model, same shared worker but separate compiled-program cache. */
    @JvmStatic external fun createPhoto(assets: AssetManager, cacheDirectory: String?): Long
    /** {"width","height","prepare_ms","gpu_ops","cpu_fallback_ops"} */
    @JvmStatic external fun describe(handle: Long): String
    /** rgb float32 CHW [0,1] -> near float32 HxW [0,1] (1 = nearest). reset restarts the shot's depth band. */
    @JvmStatic external fun process(handle: Long, rgb: ByteBuffer, near: ByteBuffer, reset: Boolean, frameStep: Int): String
    /** No temporal history; padding outside the content rectangle never contributes to near depth. */
    @JvmStatic external fun processPhoto(handle: Long, rgb: ByteBuffer, near: ByteBuffer, x: Int, y: Int, width: Int, height: Int): String
    @JvmStatic external fun close(handle: Long)
    /** Video model from a file (debug A/B of the input size), same session setup as [create]. */
    @JvmStatic external fun createFromFile(modelPath: String, cacheDirectory: String?): Long

    /** Debug A/B of the video depth input size: adb shell setprop debug.vrpp.depth.video_model late_420x238.mnn
     * loads <external files>/depth-mnn/late_420x238.mnn instead of the packaged model; its size comes from the
     * name. Read once per process; empty = packaged model. */
    val videoModelOverride: String? by lazy {
        if (!BuildConfig.DEBUG) null else runCatching {
            Class.forName("android.os.SystemProperties").getMethod("get", String::class.java)
                .invoke(null, "debug.vrpp.depth.video_model") as String
        }.getOrNull()?.takeIf { OVERRIDE.matches(it) }
    }
    fun videoModelFile(context: Context): File? =
        videoModelOverride?.let { File(context.getExternalFilesDir(null), "depth-mnn/$it") }

    /** Model input: 16:9 multiples of the 14 px patch, fixed in the converted graph (tools/models/prepare_depth_mnn.py). */
    val PROFILE: String by lazy { videoModelOverride?.let { OVERRIDE.find(it)?.groupValues?.get(1) } ?: "364x210" }
    private val OVERRIDE = Regex("""[A-Za-z0-9]+_(\d+x\d+)\.mnn""")
}
