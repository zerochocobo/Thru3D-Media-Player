package org.vrpassthroughplayer.plugin

import android.hardware.HardwareBuffer
import android.view.Surface
import org.json.JSONObject

/** A decoded frame's buffer for the RVM input (Alpha plan B); the taker closes [buffer]. */
internal class LayerFrame(val buffer: HardwareBuffer, val width: Int, val height: Int, val bufferWidth: Int, val bufferHeight: Int,
                          val sequence: Long, val timestampNs: Long)

/**
 * Alpha plan B: where the decoder writes while its frames reach the compositor layer and RVM sees them.
 * [LayerCopy] draws each frame into the layer surface after a fixed delay (masks switch when their own
 * frame is drawn); [LayerFanout] hands the decoder's buffers on (debug comparison only: on Quest the
 * decoder then allocates a new buffer per frame faster than they are freed).
 */
internal interface LayerFrames {
    /** The decoder's output surface. */
    val surface: Surface
    /** Keep the newest frame's buffer for [take] (an Alpha session). */
    var keepFrames: Boolean
    /** Hold frames for their masks (an Alpha session); off sends every held frame on at once. */
    var hold: Boolean
    /** How long frames wait before they are shown (ms): the audio delay that keeps them in sync. */
    val holdMs: Double
    /** True: frames are shown at their own pace and a mask goes up only once [presented] reaches its
     * frame. False: a mask releases the frames it belongs with ([releaseThrough]). */
    val presentsLater: Boolean
    /** The sequence of the newest frame shown. */
    val presented: Long
    fun take(): LayerFrame?
    fun releaseThrough(sequence: Long)
    fun releaseStale(limitMs: Long)
    /** The measured capture-to-mask time (ms), so delayed presentation can wait as long. */
    fun maskLatency(ms: Double) {}
    fun stats(): JSONObject
    fun close()
}
