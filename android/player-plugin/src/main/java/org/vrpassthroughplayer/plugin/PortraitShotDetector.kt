package org.vrpassthroughplayer.plugin

import java.nio.ByteBuffer
import kotlin.math.*

/** Full-source thumbnails, independent of the moving RVM crop. Bounded work and storage; no model.
 * Exposure-normalized spatial RGB catches cuts with identical histograms/person bounds. A small
 * translation search tolerates camera motion; a short reference window also detects dissolves.
 * Thresholds are conservative prototype values, not a claim to identify every editorial cut. */
internal class PortraitShotDetector {
    data class Result(val shot: Long, val cut: Boolean, val reason: String, val difference: Double, val correlation: Double = 1.0)
    private data class Frame(val pixels: FloatArray, val mean: Float, val deviation: Float)
    private data class Difference(val error: Double, val correlation: Double, val coverage: Double = 0.0)
    private var previous: Frame? = null
    private var reference: Frame? = null
    private var referencePts = -1L
    private var pts = -1L
    private var shot = 0L
    private var dissolveVotes = 0
    private var motion = 0.0
    private var motionSamples = 0

    fun observe(rgba: ByteBuffer, timestamp: Long): Result {
        require(rgba.capacity() >= WIDTH * HEIGHT * 4)
        val pixels = FloatArray(WIDTH * HEIGHT * 3)
        var sum = 0.0; var square = 0.0
        for (i in 0 until WIDTH * HEIGHT) {
            for (c in 0..2) pixels[i * 3 + c] = (rgba.get(i * 4 + c).toInt() and 255) / 255f
            val y = (pixels[i*3] + pixels[i*3+1] * 2 + pixels[i*3+2]) * .25
            sum += y; square += y*y
        }
        val mean = sum / (WIDTH * HEIGHT)
        val frame = Frame(pixels, mean.toFloat(), sqrt(max(0.0, square/(WIDTH*HEIGHT)-mean*mean)).toFloat())
        val last = previous
        if (timestamp == pts && last != null) return Result(shot, false, "repeat", 0.0)
        val discontinuity = pts < 0 || timestamp < pts || timestamp - pts > 1_000_000
        val change = if (last == null) Difference(0.0,1.0) else difference(last, frame)
        val difference = change.error
        val frameSteps = ((timestamp-pts)/33_333.0).coerceIn(0.5,6.0)
        // A same-set edit can retain a correlated background. Require a large affected area and
        // an abrupt increase over recent motion, not merely one fast-moving hand or sensor noise.
        val motionCut = motionSamples >= 4 && difference > .04 && change.correlation < .8 &&
            change.coverage > .20 && difference > max(.008,motion) * frameSteps * 3.5
        var reason = when {
            discontinuity -> if (last == null) "initial" else "timeline"
            // A near-white/black exposure flash carries too little structure: keep the reference
            // so its recovery is compared to the pre-flash picture, not treated as a second cut.
            frame.deviation < .018f && (frame.mean > .96f || frame.mean < .015f) -> "flash"
            difference > .19 || (difference > .065 && change.correlation < .25 &&
                frame.deviation > .035 && last != null && last.deviation > .035) -> "hard"
            motionCut -> "motion_cut"
            else -> ""
        }
        if (reason == "flash") { pts = timestamp; return Result(shot, false, reason, difference) }
        if (reason.isEmpty() && reference != null && timestamp - referencePts in 80_000..450_000) {
            val drift = difference(reference!!, frame)
            dissolveVotes = if ((drift.error > .16 || (drift.error > .04 && drift.correlation < .35)) &&
                difference > .005) dissolveVotes + 1 else 0
            if (dissolveVotes >= 2) reason = "dissolve"
        }
        val cut = reason.isNotEmpty()
        if (cut) { shot++; reference = frame; referencePts = timestamp; dissolveVotes = 0; motion = 0.0; motionSamples = 0 }
        else if (reference == null || timestamp-referencePts > 450_000) { reference = frame; referencePts = timestamp; dissolveVotes = 0 }
        if (!cut) {
            val rate = difference / frameSteps
            motion = if (motionSamples == 0) rate else motion * .85 + rate * .15
            motionSamples++
        }
        previous = frame; pts = timestamp
        return Result(shot, cut, reason, difference, change.correlation)
    }

    private fun difference(a: Frame, b: Frame): Difference {
        // Only correct a shared luminance gain/offset: per-channel normalization would hide cuts
        // between different coloured backgrounds. Clamp gain to avoid amplifying flat/noisy scenes.
        val gain = (a.deviation / max(.025f, b.deviation)).coerceIn(.65f, 1.55f)
        val offset = a.mean - b.mean * gain
        var best = Difference(Double.MAX_VALUE,1.0)
        for (dy in -2..2) for (dx in -3..3) {
            var error = 0.0; var n = 0; var changed = 0
            var sumA = 0.0; var sumB = 0.0; var aa = 0.0; var bb = 0.0; var ab = 0.0
            for (y in 2 until HEIGHT-2 step 2) for (x in 3 until WIDTH-3 step 2) {
                val i = (y*WIDTH+x)*3; val j = ((y+dy)*WIDTH+x+dx)*3
                var e = 0.0
                for (c in 0..2) e += abs(a.pixels[i+c] - (b.pixels[j+c]*gain+offset).coerceIn(0f,1f)) / 3
                error += e; n++; if (e > .08) changed++
                val ya = (a.pixels[i]+2*a.pixels[i+1]+a.pixels[i+2])*.25
                val yb = (b.pixels[j]+2*b.pixels[j+1]+b.pixels[j+2])*.25
                sumA += ya; sumB += yb; aa += ya*ya; bb += yb*yb; ab += ya*yb
            }
            // A moving hand/local object alone cannot label the whole picture a new shot.
            val value = error/n
            val covariance = ab-sumA*sumB/n
            val variance = sqrt(max(0.0,aa-sumA*sumA/n)*max(0.0,bb-sumB*sumB/n))
            if (value < best.error) best = Difference(value,if (variance > 1e-6) covariance/variance else 1.0,changed.toDouble()/n)
        }
        return best
    }

    companion object { const val WIDTH = 48; const val HEIGHT = 32 }
}
