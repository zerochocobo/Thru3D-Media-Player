package org.vrpassthroughplayer.plugin

/**
 * Alpha plan B: which fanned-out frames go to RVM (GL thread). One frame infers while the newest waits
 * behind it, so the model starts the next mask at once instead of idling ~20 ms per mask through the
 * capture, copy and upload draws. Quest 3, 8K VR180, passthrough, menus closed (2026-11-10): one at a
 * time 13.6 masks/s, two 17.7 at XR 72-73 with no stale frames, mask latency 80 -> ~130 ms; the RVM
 * OpenCL queue at LOW was worse (16.1, stale frames). With the library open RVM slows by ~30% and two
 * cost XR 72 -> 65. More than two would queue behind a slow model past the frames' hold.
 * Frames are spaced by their own timestamps at the Alpha rate, never by when the GL thread happens to
 * draw: a wall-clock gap from the last capture skipped every other 30 fps frame at 72 Hz.
 */
internal class LayerAlphaCadence(private val limit: Int = IN_FLIGHT) {
    private val inFlight = LinkedHashMap<Long, Long>() // token -> capture time (ns)
    private var lastTimestampNs = Long.MIN_VALUE

    init { require(limit >= 1) }

    val size get() = inFlight.size

    /** Room for another capture. A capture whose mask never comes (dropped by the model) stops counting
     * after [STALE_NS]. */
    fun hasRoom(nowNs: Long): Boolean {
        inFlight.values.removeAll { nowNs - it > STALE_NS }
        return inFlight.size < limit
    }

    /** True when the frame at [timestampNs] is due at [fps]: a frame period less a tenth (timestamp
     * jitter) after the last capture, as LayerCopy keeps them. A timestamp going back (seek) starts again. */
    fun due(timestampNs: Long, fps: Int): Boolean {
        if (lastTimestampNs == Long.MIN_VALUE) return true
        val period = 1_000_000_000L / fps.coerceAtLeast(1)
        return timestampNs - lastTimestampNs !in 0 until period * 9 / 10
    }

    fun captured(token: Long, timestampNs: Long, nowNs: Long) {
        lastTimestampNs = timestampNs
        inFlight[token] = nowNs
    }

    /** The mask of [token] is back, or its lease retired without one: room for the next frame. */
    fun finished(token: Long) { inFlight.remove(token) }

    companion object {
        /** Debug builds: adb shell setprop debug.vrpp.alpha.in_flight 1..3 (1: one at a time; with
         * debug.vrpp.cl.priority low for the RVM queue to compare as above). */
        const val IN_FLIGHT = 2
        const val STALE_NS = 1_000_000_000L
        fun debugLimit(): Int {
            if (!BuildConfig.DEBUG) return IN_FLIGHT
            return try {
                val value = Class.forName("android.os.SystemProperties").getMethod("get", String::class.java)
                    .invoke(null, "debug.vrpp.alpha.in_flight") as String
                value.toIntOrNull()?.coerceIn(1, 3) ?: IN_FLIGHT
            } catch (_: Throwable) { IN_FLIGHT }
        }
    }
}
