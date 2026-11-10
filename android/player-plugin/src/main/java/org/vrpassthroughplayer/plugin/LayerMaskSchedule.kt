package org.vrpassthroughplayer.plugin

/**
 * Alpha plan B (GL thread): which finished masks the frame on the layer shows. RVM finishes a mask for
 * about two of every three frames shown; a frame without its own used to keep the mask before it. With
 * [blend] it shows the masks before and after it mixed by its place between them, which halved its edge
 * error offline (benchmarks/mask_interpolation_sim.py, 8K VR180, 18-20 masks a second; extrapolating
 * from the two masks before gained nothing). The later mask must be finished when the frame is drawn:
 * frames are held one mask interval longer ([intervalMs]) when the reader has room for them.
 */
internal class LayerMaskSchedule<T>(var blend: Boolean = true) {
    class Mask<T>(val token: Long, val frame: Long, val value: T)
    /** [mask] alone ([next] null), or mixed with [next] by [weight] in (0, 1). */
    class Shown<T>(val mask: Mask<T>, val next: Mask<T>?, val weight: Float)

    private val masks = ArrayDeque<Mask<T>>() // by frame, oldest first; the first may be on the layer
    private var drawn = Triple(0L, 0L, 0L) // mask token, next token and frame of the last draw
    private var lastNs = Long.MIN_VALUE
    /** Smoothed time between finished masks (ms); 0 until two have come. */
    var intervalMs = 0.0
        private set

    val size get() = masks.size

    fun add(token: Long, frame: Long, value: T, nowNs: Long) {
        if (lastNs != Long.MIN_VALUE) {
            val gap = (nowNs - lastNs) / 1e6
            // A pause or seek is not the model's pace.
            if (gap > 0 && gap < GAP_LIMIT_MS) intervalMs = if (intervalMs == 0.0) gap else intervalMs * 0.9 + gap * 0.1
        }
        lastNs = nowNs
        masks.addLast(Mask(token, frame, value))
    }

    /** What to draw now that frame [presented] is on the layer; null when the layer already shows it or
     * the first mask's frame has not come. Masks left behind go to [retire]. Masks never wait for long:
     * past [LIMIT] the oldest goes although the copy has stalled. */
    fun show(presented: Long, retire: (Long) -> Unit): Shown<T>? {
        var forced = false
        while (masks.size >= 2 && (masks[1].frame <= presented || masks.size > LIMIT)) {
            forced = forced || masks[1].frame > presented
            retire(masks.removeFirst().token)
        }
        val mask = masks.firstOrNull() ?: return null
        if (mask.frame > presented && !forced && drawn.first != mask.token) return null
        // Masks far apart (a seek, a stall) are not one motion: the earlier one stays as it is.
        val next = masks.getOrNull(1)?.takeIf { blend && presented > mask.frame && it.frame > presented && it.frame - mask.frame <= SPAN_LIMIT }
        val weight = if (next == null) 0f else (presented - mask.frame).toFloat() / (next.frame - mask.frame)
        val key = Triple(mask.token, next?.token ?: 0L, if (next == null) 0L else presented)
        if (key == drawn) return null
        drawn = key
        return Shown(mask, next, weight)
    }

    companion object {
        const val LIMIT = 4
        const val GAP_LIMIT_MS = 300.0
        const val SPAN_LIMIT = 8L // frames (decoder sequence) between two masks that still mix
        /** Debug builds: adb shell setprop debug.vrpp.alpha.blend 0 keeps the earlier mask as before. */
        fun debugBlend(): Boolean {
            if (!BuildConfig.DEBUG) return true
            return try {
                Class.forName("android.os.SystemProperties").getMethod("get", String::class.java)
                    .invoke(null, "debug.vrpp.alpha.blend") as String != "0"
            } catch (_: Throwable) { true }
        }
    }
}
