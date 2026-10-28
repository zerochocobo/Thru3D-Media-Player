package org.vrpassthroughplayer.plugin

import java.nio.ByteBuffer

/** Every call is made on Godot's GL thread with the creating EGL context current. */
internal object RenderBridgeNative {
    init { System.loadLibrary("quest_render_bridge") }
    /** Worker-only still-image path. RGBA row 0 is top, near is mono RF; output is packed SBS RGBA.
     * Reuses video's forward warp, z-buffer, hole fill, rim and sliver cleanup. Returns elapsed us. */
    @JvmStatic external fun photoStereo(rgba: ByteBuffer, width: Int, height: Int, near: ByteBuffer,
        modelWidth: Int, modelHeight: Int, content: FloatArray, strength: Float, output: ByteBuffer): Long
    /** stereo: two views, side by side unless topBottom (top half is the left eye). */
    fun create(width: Int, height: Int, inputWidth: Int, inputHeight: Int, stereo: Boolean, topBottom: Boolean = false): Long =
        createLayout(width, height, inputWidth, inputHeight, if (!stereo) 0 else if (topBottom) 2 else 1)
    /** layout: 0 mono, 1 side by side, 2 top-bottom. */
    @JvmStatic external fun createLayout(width: Int, height: Int, inputWidth: Int, inputHeight: Int, layout: Int): Long
    @JvmStatic external fun oesTexture(handle: Long): Int
    /** Returns 0 when all three immutable slots are held. */
    @JvmStatic external fun capture(handle: Long, transform: FloatArray): Long
    /** MPV shared RGBA8, canonical top rows. Retain the producer lease through this GPU copy. */
    @JvmStatic external fun captureTexture(handle: Long, texture: Int, stageInputs: Boolean): Long
    /** Constant per-slot opaque R8 shares the color-copy fence; no inference readback. */
    @JvmStatic external fun captureOpaqueTexture(handle: Long, texture: Int): Long
    @JvmStatic external fun stats(handle: Long): String
    @JvmStatic external fun ready(handle: Long, token: Long): Boolean
    @JvmStatic external fun texture(handle: Long, token: Long): Int
    @JvmStatic external fun readInputs(handle: Long, token: Long, left: ByteBuffer, right: ByteBuffer): Boolean
    /** ROI capture: model = rect.xy + eyeUv * rect.zw (zoom window when zw > 1). scout also stages the
     * full-eye input of the same color for readScoutInputs. */
    @JvmStatic external fun captureTextureRoi(handle: Long, texture: Int, rect: FloatArray, scout: Boolean): Long
    /** Full-eye letterbox rect for this source/model aspect. */
    @JvmStatic external fun fullInputRect(handle: Long): FloatArray
    @JvmStatic external fun readScoutInputs(handle: Long, token: Long, left: ByteBuffer, right: ByteBuffer): Boolean
    /** Stage model inputs into per-slot AHardwareBuffers shared with MNN OpenCL (no PBO readback). */
    @JvmStatic external fun enableZeroCopy(handle: Long): Boolean
    /** Memory saver: at most [limit] (2..7) slots in flight, each holding a full-size color. */
    @JvmStatic external fun setSlotLimit(handle: Long, limit: Int): Boolean
    /** Captures keep the producer texture instead of a full-resolution copy; the caller holds the
     * producer lease until [retired] reports the slot free. */
    @JvmStatic external fun enableBorrowedColor(handle: Long): Boolean
    /** Capture a decoder buffer (MPV direct mode): model input scaled from its YUV; the pair shows it. */
    @JvmStatic external fun captureBufferRoi(handle: Long, buffer: Long, bufferWidth: Int, bufferHeight: Int,
                                             rect: FloatArray, scout: Boolean): Long
    /** Normal-playback direct mode: the pair shows the decoder buffer with the constant opaque mask. */
    @JvmStatic external fun captureOpaqueBuffer(handle: Long, buffer: Long, bufferWidth: Int, bufferHeight: Int): Long
    /** EGLImage of a held decoder-buffer slot for Godot's ExternalTexture; 0 for RGBA colors. */
    @JvmStatic external fun colorImage(handle: Long, token: Long): Long
    /** One independent GPU transition copy: {handle, RGBA texture, R8 mask, width, height, copy us, R8 portrait or 0}.
     * Completes before returning so a subsequent MediaCodec seek can safely flush its surface. */
    @JvmStatic external fun freezePair(handle: Long, token: Long, warped: Boolean): LongArray
    @JvmStatic external fun releaseFrozen(handle: Long)
    /** {input L, input R, Alpha L, Alpha R} AHardwareBuffer handles of a held color (scout: its full-eye set). */
    /** Each returned handle holds a reference: pass the array to [releaseBuffers] when done. */
    @JvmStatic external fun zeroCopyBuffers(handle: Long, token: Long, scout: Boolean): LongArray
    @JvmStatic external fun releaseBuffers(buffers: LongArray?)
    /** The native AHardwareBuffer of a Java HardwareBuffer (no added reference): Alpha plan B frames. */
    @JvmStatic external fun hardwareBufferPointer(buffer: android.hardware.HardwareBuffer): Long
    /** Pack the two Alpha buffers into the slot's R8 mask on the GPU; fenced like uploadAlpha. */
    @JvmStatic external fun commitZeroCopyAlpha(handle: Long, token: Long): Boolean
    /** Both eyes validated before upload. Never overwrite a mask still owned by this token. */
    @JvmStatic external fun uploadAlpha(handle: Long, token: Long, left: ByteBuffer, right: ByteBuffer): Boolean
    @JvmStatic external fun alphaReady(handle: Long, token: Long): Boolean
    /** Mono R8 shape decoded by *1.5; optional 64x64 signed residual uses 128 as zero.
     * Resolves private mip levels before Godot's single-level import. */
    @JvmStatic external fun preparePortrait(handle: Long, token: Long, lodBias: Float, residual: ByteBuffer? = null): Int
    @JvmStatic external fun stagePortraitMask(handle: Long, token: Long)
    @JvmStatic external fun readPortraitMask(handle: Long, token: Long, mask: ByteBuffer)
    @JvmStatic external fun stagePortraitInput(handle: Long, token: Long, rect: FloatArray, width: Int, height: Int)
    @JvmStatic external fun readPortraitInput(handle: Long, rgb: ByteBuffer): Boolean
    @JvmStatic external fun stagePortraitShot(handle: Long, token: Long)
    @JvmStatic external fun readPortraitShot(handle: Long, token: Long, rgba: ByteBuffer)
    @JvmStatic external fun restagePortraitFull(handle: Long, token: Long)
    /** 2D->3D: renders the held mono color's stereo pair (2W x H) from the near map just uploaded
     * (PTMediaServer soft_shift with its hole fill); readiness follows alphaReady. 0: unsupported. */
    @JvmStatic external fun warp(handle: Long, token: Long, shift: Float, convergence: Float): Int
    @JvmStatic external fun alphaTexture(handle: Long, token: Long): Int
    /** Development only: exact-size model-height rows of left/right packed R8 bytes. */
    @JvmStatic external fun readAlpha(handle: Long, token: Long, output: ByteBuffer): Boolean
    /** Caller has stopped drawing/reading this token before releasing it. */
    @JvmStatic external fun retire(handle: Long, token: Long)
    @JvmStatic external fun retired(handle: Long, token: Long): Boolean
    @JvmStatic external fun close(handle: Long)
    /** Context recreation only: forget old names without deleting them in a new context. */
    @JvmStatic external fun abandon(handle: Long)
}
