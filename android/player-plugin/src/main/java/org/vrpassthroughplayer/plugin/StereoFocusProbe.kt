package org.vrpassthroughplayer.plugin

import android.graphics.Bitmap
import android.graphics.Rect
import android.os.Handler
import android.os.HandlerThread
import android.os.SystemClock
import android.view.PixelCopy
import android.view.Surface
import kotlin.math.ceil
import kotlin.math.floor
import kotlin.math.max
import kotlin.math.min
import kotlin.math.roundToInt
import kotlin.math.sqrt

/**
 * Automatic stereo focus: how far apart the two eyes' pictures of whatever sits at the centre of gaze
 * are, as an angle. The video is on the compositor layer (the decoder writes its surface), so one
 * PixelCopy takes the strip holding both eyes' patches of the same frame, a few times a second, and
 * the patches are matched here off the frame path. A fisheye frame is in a texture instead and bent by
 * its lens: the layer library draws both patches straightened and hands their pixels over.
 */
internal object StereoFocusProbe {
    /** Matched pixels per degree; the strip is copied at twice this and box-filtered. */
    const val DENSITY = 6f
    /** Half the matched window, degrees. */
    const val WINDOW_X = 8f
    const val WINDOW_Y = 6f
    /** Searched disparity, degrees: positive is nearer (the left eye's picture lies further right). */
    const val NEAR = 13f
    const val FAR = -4f
    /** Half of each eye's copied patch: the window and the furthest half shift. */
    const val REACH_X = WINDOW_X + NEAR / 2f

    private val handler by lazy { Handler(HandlerThread("StereoFocusProbe").apply { start() }.looper) }
    @Volatile private var busy = false
    @Volatile private var latest = FloatArray(6)
    private var sequence = 0
    /** When the lens patches now being drawn were asked for; 0 with none. Godot's thread only. */
    private var lensStarted = 0L
    /** The lens patches as drawn: both eyes side by side at twice the matched density. */
    private val lensWidth = (4f * REACH_X * 2f * DENSITY).roundToInt()
    private val lensHeight = (2f * WINDOW_Y * 2f * DENSITY).roundToInt()

    /** [params]: the gaze point in each shown eye's picture as frame UV (left u, v, right u, v), then the
     * degrees one whole frame spans across and down. False while a copy is running or nothing can be read. */
    fun request(surface: Surface?, width: Int, height: Int, params: FloatArray): Boolean {
        if (busy || surface == null || !surface.isValid || width <= 0 || height <= 0 || params.size != 6) return false
        val perDegreeX = width / params[4]
        val perDegreeY = height / params[5]
        if (!(perDegreeX > 0.5f) || !(perDegreeY > 0.5f)) return false
        val reach = floatArrayOf(REACH_X * perDegreeX, WINDOW_Y * perDegreeY)
        val centres = FloatArray(4) { params[it] * (if (it % 2 == 0) width else height) }
        val area = Rect(floor(min(centres[0], centres[2]) - reach[0]).toInt(), floor(min(centres[1], centres[3]) - reach[1]).toInt(),
            ceil(max(centres[0], centres[2]) + reach[0]).toInt(), ceil(max(centres[1], centres[3]) + reach[1]).toInt())
        if (area.left < 0 || area.top < 0 || area.right > width || area.bottom > height) return false
        // Twice the matched density where the source has it, for a 2x2 box filter; never upscaled.
        val scaleX = min(1f, 2f * DENSITY / perDegreeX)
        val scaleY = min(1f, 2f * DENSITY / perDegreeY)
        val copy = Bitmap.createBitmap(max(2, (area.width() * scaleX).roundToInt()), max(2, (area.height() * scaleY).roundToInt()),
            Bitmap.Config.ARGB_8888)
        val started = SystemClock.elapsedRealtime()
        busy = true
        lensStarted = 0L
        try {
            PixelCopy.request(surface, area, copy, { result ->
                val measured = try {
                    if (result != PixelCopy.SUCCESS) null else measure(copy, area, centres,
                        perDegreeX * copy.width / area.width(), perDegreeY * copy.height / area.height())
                } catch (_: Throwable) { null } finally { copy.recycle() }
                publish(measured, started)
            }, handler)
        } catch (_: Throwable) {
            copy.recycle(); publish(null, started)
        }
        return true
    }

    /** The same for the fisheye frame in [texture], on the thread that draws. [params]: layout (1 side by
     * side, 2 top-bottom), half-width eyes, lens degrees, frame width, height, texture UV scale x, y, the
     * gaze longitude and latitude in radians, swapped eyes. */
    fun requestLens(texture: Int, external: Boolean, params: FloatArray): Boolean {
        if (busy || params.size != 10) return false
        val reach = floatArrayOf(Math.toRadians(REACH_X.toDouble()).toFloat(), Math.toRadians(WINDOW_Y.toDouble()).toFloat())
        if (!VideoLayerNative.probeFisheye(texture, external, params.copyOfRange(0, 9) + reach + params[9], lensWidth, lensHeight)) return false
        lensStarted = SystemClock.elapsedRealtime()
        return true
    }

    /** (sequence, state, disparity degrees, peak, runner-up, contrast): state 1 measured, 0 nothing to
     * match, -1 unreadable. The sequence grows with every finished request. Called on the thread that
     * draws: it also collects drawn lens patches. */
    fun result(): FloatArray {
        if (lensStarted != 0L && !busy) {
            val pixels = VideoLayerNative.takeFisheyeProbe()
            if (pixels.size == lensWidth * lensHeight * 4) {
                val started = lensStarted
                lensStarted = 0L
                busy = true
                handler.post { publish(runCatching { measureLens(pixels, lensWidth, lensHeight) }.getOrNull(), started) }
            }
        }
        return latest
    }

    /** [pixels]: RGBA rows of the two eyes' patches side by side, each centred on the gaze, brightness in
     * red, at twice the matched density. Returns as [measure]. */
    fun measureLens(pixels: ByteArray, width: Int, height: Int): FloatArray {
        val halfWidth = width / 2
        val halfHeight = height / 2
        val luma = FloatArray(halfWidth * halfHeight)
        for (y in 0 until halfHeight) for (x in 0 until halfWidth) {
            val at = (y * 2 * width + x * 2) * 4
            luma[y * halfWidth + x] = ((pixels[at].toInt() and 255) + (pixels[at + 4].toInt() and 255) +
                (pixels[at + width * 4].toInt() and 255) + (pixels[at + width * 4 + 4].toInt() and 255)) / 4f
        }
        val matched = match(luma, halfWidth, halfHeight, halfWidth / 4, halfHeight / 2, halfWidth * 3 / 4, halfHeight / 2,
            (WINDOW_X * DENSITY).toInt(), (WINDOW_Y * DENSITY).toInt(), floor(FAR * DENSITY).toInt(), ceil(NEAR * DENSITY).toInt())
        matched[0] /= DENSITY
        return matched
    }

    private fun publish(measured: FloatArray?, started: Long) {
        synchronized(this) {
            sequence += 1
            latest = if (measured == null) floatArrayOf(sequence.toFloat(), -1f, 0f, 0f, 0f, 0f)
                else floatArrayOf(sequence.toFloat(), if (measured[1] > 0f) 1f else 0f, measured[0], measured[1], measured[2], measured[3])
        }
        if (BuildConfig.DEBUG) android.util.Log.d("StereoFocus", "probe ${latest.joinToString(" ")} ms=${SystemClock.elapsedRealtime() - started}")
        busy = false
    }

    private fun measure(copy: Bitmap, area: Rect, centres: FloatArray, perDegreeX: Float, perDegreeY: Float): FloatArray {
        val pixels = IntArray(copy.width * copy.height)
        copy.getPixels(pixels, 0, copy.width, 0, 0, copy.width, copy.height)
        // Halve where the copy holds twice the matched density.
        val stepX = if (perDegreeX >= DENSITY * 1.5f) 2 else 1
        val stepY = if (perDegreeY >= DENSITY * 1.5f) 2 else 1
        val densityX = perDegreeX / stepX
        val width = copy.width / stepX
        val height = copy.height / stepY
        val luma = FloatArray(width * height)
        for (y in 0 until height) for (x in 0 until width) {
            var sum = 0
            for (dy in 0 until stepY) for (dx in 0 until stepX) {
                val pixel = pixels[(y * stepY + dy) * copy.width + x * stepX + dx]
                sum += ((pixel shr 16 and 255) * 77 + (pixel shr 8 and 255) * 150 + (pixel and 255) * 29) shr 8
            }
            luma[y * width + x] = sum.toFloat() / (stepX * stepY)
        }
        val toCopyX = copy.width.toFloat() / area.width() / stepX
        val toCopyY = copy.height.toFloat() / area.height() / stepY
        val matched = match(luma, width, height,
            ((centres[0] - area.left) * toCopyX).roundToInt(), ((centres[1] - area.top) * toCopyY).roundToInt(),
            ((centres[2] - area.left) * toCopyX).roundToInt(), ((centres[3] - area.top) * toCopyY).roundToInt(),
            (WINDOW_X * densityX).toInt(), (WINDOW_Y * perDegreeY / stepY).toInt(),
            floor(FAR * densityX).toInt(), ceil(NEAR * densityX).toInt())
        matched[0] /= densityX
        return matched
    }

    /**
     * Zero-mean normalised correlation of a window around (leftX, leftY) and (rightX, rightY) in [luma],
     * the left window moved right and the right one left by half of each candidate disparity so the
     * matched thing stays at the centre of gaze. Returns (disparity pixels, peak, best score away from
     * the peak, the left window's standard deviation); a peak of 0 means nothing was matched (the best
     * candidate lay on an end of the search, or a window left the picture).
     */
    fun match(luma: FloatArray, width: Int, height: Int, leftX: Int, leftY: Int, rightX: Int, rightY: Int,
              halfX: Int, halfY: Int, far: Int, near: Int): FloatArray {
        val none = floatArrayOf(0f, 0f, 0f, 0f)
        if (halfX < 2 || halfY < 2 || near <= far) return none
        val scores = FloatArray(near - far + 1)
        var contrast = 0f
        for (index in scores.indices) {
            val disparity = far + index
            val leftShift = Math.floorDiv(disparity + 1, 2)
            val left = leftX + leftShift
            val right = rightX - (disparity - leftShift)
            if (left - halfX < 0 || left + halfX > width || right - halfX < 0 || right + halfX > width ||
                min(leftY, rightY) - halfY < 0 || max(leftY, rightY) + halfY > height) { scores[index] = -2f; continue }
            var sumL = 0.0; var sumR = 0.0; var sumLL = 0.0; var sumRR = 0.0; var sumLR = 0.0
            for (y in -halfY until halfY) {
                var l = (leftY + y) * width + left - halfX
                var r = (rightY + y) * width + right - halfX
                for (x in 0 until halfX * 2) {
                    val a = luma[l++]; val b = luma[r++]
                    sumL += a; sumR += b; sumLL += a * a; sumRR += b * b; sumLR += a * b
                }
            }
            val count = (halfX * 2 * halfY * 2).toDouble()
            val varL = sumLL - sumL * sumL / count
            val varR = sumRR - sumR * sumR / count
            scores[index] = if (varL > 1e-3 && varR > 1e-3) ((sumLR - sumL * sumR / count) / sqrt(varL * varR)).toFloat() else 0f
            if (disparity == 0) contrast = sqrt(max(0.0, varL) / count).toFloat()
        }
        var best = 0
        for (index in scores.indices) if (scores[index] > scores[best]) best = index
        if (best == 0 || best == scores.lastIndex || scores[best - 1] < -1f || scores[best + 1] < -1f || scores[best] <= 0f) return none
        val curve = scores[best - 1] - 2f * scores[best] + scores[best + 1]
        val fine = if (curve < 0f) 0.5f * (scores[best - 1] - scores[best + 1]) / curve else 0f
        var other = -1f
        for (index in scores.indices) if (kotlin.math.abs(index - best) > halfX / 2 && scores[index] > other) other = scores[index]
        return floatArrayOf(far + best + fine, scores[best], other, contrast)
    }
}
