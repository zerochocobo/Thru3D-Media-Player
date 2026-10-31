package org.vrpassthroughplayer.plugin

import android.graphics.Bitmap
import android.graphics.Matrix
import android.os.Handler
import android.os.HandlerThread
import android.view.PixelCopy
import android.view.Surface
import java.nio.ByteBuffer
import kotlin.math.max
import kotlin.math.min
import kotlin.math.roundToInt

/**
 * Library picture of a video shown on the compositor layer: the decoder writes straight into the
 * layer's surface, so neither Godot nor MPV ever holds the frame. PixelCopy reads the surface's last
 * queued buffer once (one GPU draw into a small bitmap); nothing changes on the per-frame path.
 */
internal object LayerThumbnail {
    /** The copy is scaled to the crop's needs, at most this many pixels on its longer side. */
    private const val MAX_COPY = 2048
    private val handler by lazy { Handler(HandlerThread("LayerThumbnail").apply { start() }.looper) }
    /** Finished requests: RGBA8 rows of the requested size, or "failed:<reason>". */
    private val results = FrameCopyResults()

    /** A full coded frame for a mode transition, never a library crop or a single-eye view. */
    fun snapshot(surface: Surface?, outWidth: Int, outHeight: Int): Int =
        request(surface, outWidth, outHeight, 0, floatArrayOf(0f, 0f, 1f, 1f), outWidth, outHeight, MAX_COPY)

    /** [width] x [height] is the displayed frame (after [rotation], clockwise); [crop] is (x, y, w, h)
     * of it in UV, row 0 on top. Returns a request id for [take], or 0 when nothing was requested. */
    fun request(surface: Surface?, width: Int, height: Int, rotation: Int, crop: FloatArray, outWidth: Int, outHeight: Int,
                maxOutput: Int = 1024): Int {
        if (surface == null || !surface.isValid || width <= 0 || height <= 0 || crop.size != 4 ||
            outWidth !in 1..maxOutput || outHeight !in 1..maxOutput || rotation % 90 != 0) return 0
        val turned = rotation % 180 != 0
        val bufferWidth = if (turned) height else width
        val bufferHeight = if (turned) width else height
        // Enough pixels for the crop to fill the output, never more than the source has.
        val scale = min(min(1.0, MAX_COPY.toDouble() / max(bufferWidth, bufferHeight)),
            max(outWidth / (crop[2] * width).toDouble(), outHeight / (crop[3] * height).toDouble()))
        val copy = Bitmap.createBitmap(max(1, (bufferWidth * scale).roundToInt()), max(1, (bufferHeight * scale).roundToInt()),
            Bitmap.Config.ARGB_8888)
        val id = results.reserve()
        if (id == 0) { copy.recycle(); return 0 }
        try {
            PixelCopy.request(surface, copy, { result ->
                val completed = try {
                    if (result == PixelCopy.SUCCESS) crop(copy, rotation, crop, outWidth, outHeight) else "failed:pixel_copy_$result"
                } catch (failure: Throwable) { "failed:${failure.javaClass.simpleName}" } finally { copy.recycle() }
                results.complete(id, completed)
            }, handler)
        } catch (failure: Throwable) {
            copy.recycle(); results.complete(id, "failed:${failure.javaClass.simpleName}")
        }
        return id
    }

    private fun crop(copy: Bitmap, rotation: Int, crop: FloatArray, outWidth: Int, outHeight: Int): ByteArray {
        val shown = if (rotation == 0) copy
            else Bitmap.createBitmap(copy, 0, 0, copy.width, copy.height, Matrix().apply { postRotate(rotation.toFloat()) }, true)
        val x = (crop[0] * shown.width).roundToInt().coerceIn(0, shown.width - 1)
        val y = (crop[1] * shown.height).roundToInt().coerceIn(0, shown.height - 1)
        val w = (crop[2] * shown.width).roundToInt().coerceIn(1, shown.width - x)
        val h = (crop[3] * shown.height).roundToInt().coerceIn(1, shown.height - y)
        val region = Bitmap.createBitmap(shown, x, y, w, h)
        val picture = Bitmap.createScaledBitmap(region, outWidth, outHeight, true)
        val pixels = ByteBuffer.allocate(outWidth * outHeight * 4)
        picture.copyPixelsToBuffer(pixels) // ARGB_8888 lies in memory as R, G, B, A
        for (bitmap in setOf(shown, region, picture)) if (bitmap !== copy) bitmap.recycle()
        return pixels.array()
    }

    /** "pending", "ready" (pixels in [pixels]) or "failed:<reason>"; a finished result is handed out once. */
    fun state(id: Int): String = results.state(id)

    fun pixels(id: Int): ByteArray = results.take(id)
    fun cancel(id: Int) = results.cancel(id)
}
