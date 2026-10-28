package org.vrpassthroughplayer.plugin

import android.content.res.AssetManager
import java.nio.ByteBuffer

internal object RvmNative {
    val unavailable: String? = try {
        System.loadLibrary("quest_rvm")
        null
    } catch (error: LinkageError) { error.javaClass.simpleName }

    @JvmStatic external fun setGeneration(id: Int)
    @JvmStatic external fun runBenchmark(assets: AssetManager, vulkan: Boolean, id: Int, profile: String): String
    @JvmStatic external fun runtimeCapabilities(): String
    @JvmStatic external fun prepareRuntime(assets: AssetManager, vulkan: Boolean, profile: String, session: Long, generation: Long): Long
    @JvmStatic external fun resetRuntime(handle: Long, generation: Long): Boolean
    @JvmStatic external fun processRuntime(handle: Long, generation: Long, frame: Long, pts: Long,
        left: ByteBuffer, right: ByteBuffer, leftAlpha: ByteBuffer, rightAlpha: ByteBuffer): String
    /** stream 0 drives display; stream 1 is the ROI full-eye scout with separate recurrent states (GPU only). */
    @JvmStatic external fun processRuntimeStream(handle: Long, generation: Long, frame: Long, pts: Long,
        left: ByteBuffer, right: ByteBuffer, leftAlpha: ByteBuffer, rightAlpha: ByteBuffer, stream: Int, resetFirst: Boolean): String
    /** Explicit source eyes. Mono runs once; CPU output is duplicated into the two legacy planes. */
    @JvmStatic external fun processRuntimeStreamEyes(handle: Long, generation: Long, frame: Long, pts: Long,
        left: ByteBuffer, right: ByteBuffer, leftAlpha: ByteBuffer, rightAlpha: ByteBuffer, stream: Int, resetFirst: Boolean, eyes: Int): String
    @JvmStatic external fun closeRuntime(handle: Long)
    /** Zero-copy display/scout stream over render-bridge AHardwareBuffer handles (GPU runtime only). */
    @JvmStatic external fun processRuntimeAhb(handle: Long, generation: Long, frame: Long, pts: Long,
        left: Long, right: Long, leftAlpha: Long, rightAlpha: Long, stream: Int, resetFirst: Boolean): String
    /** Mono writes only leftAlpha; the bridge and ROI reader must reuse that output for both views. */
    @JvmStatic external fun processRuntimeAhbEyes(handle: Long, generation: Long, frame: Long, pts: Long,
        left: Long, right: Long, leftAlpha: Long, rightAlpha: Long, stream: Int, resetFirst: Boolean, eyes: Int): String
    /** R channel of two zero-copy Alpha buffers into [output] (left plane, then right), for ROI analysis. */
    @JvmStatic external fun readAlphaPlanes(left: Long, right: Long, output: ByteBuffer): Boolean
    /** Whether MNN reads and writes AHardwareBuffers on this GPU, tested with the first GPU runtime:
     * -1 not yet, 0 no (Alpha then uses host copies), 1 yes. */
    @JvmStatic external fun zeroCopySupport(): Int
    /** GPU runtimes use MNN OpenCL. Cache keeps compiled programs/tuning per profile and precision. */
    @JvmStatic external fun configureGpu(cacheDirectory: String?, fp16: Boolean)
    /** AI precision setting: FP32 compute for GPUs whose FP16 masks come out wrong; FP16 is faster.
     * Applies to runtimes prepared afterwards. Debug A/B: adb shell setprop debug.vrpp.rvm.precision fp32|fp16 */
    @Volatile var fp32 = false
    fun fp16(): Boolean {
        if (BuildConfig.DEBUG) when (runCatching {
            Class.forName("android.os.SystemProperties").getMethod("get", String::class.java).invoke(null, "debug.vrpp.rvm.precision") as String
        }.getOrDefault("")) { "fp32" -> return false; "fp16" -> return true }
        return !fp32
    }
    /** Compile/tune once into the cache; returns {"profile_key","prepare_ms","gpu_ops"}. */
    /** "fast" (distilled, default) or "quality"; applies to GPU runtimes prepared afterwards. */
    @JvmStatic external fun selectGpuModel(model: String)
    @JvmStatic external fun gpuCachePath(assets: android.content.res.AssetManager, profile: String, model: String): String
    @JvmStatic external fun warmupGpu(assets: android.content.res.AssetManager, profile: String, model: String): String
}
