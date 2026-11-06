package org.vrpassthroughplayer.plugin

/** Top-left browser crop composed before the player's OES-to-canonical copy. */
internal object WebBrowserDepthGeometry {
    fun valid(c: FloatArray) = c.size == 4 && c.all { it.isFinite() } && c[0] >= 0 && c[1] >= 0 &&
        c[2] >= .04f && c[3] >= .04f && c[0] + c[2] <= 1.000001f && c[1] + c[3] <= 1.000001f
    fun transform(source: FloatArray, crop: FloatArray, out: FloatArray) {
        require(source.size == 16 && out.size == 16 && valid(crop))
        // Native copy flips canonical Y before this matrix. Crop is therefore bottom-origin here.
        val x = crop[0]; val y = 1f - crop[1] - crop[3]
        for (r in 0..3) {
            out[r] = source[r] * crop[2]; out[4+r] = source[4+r] * crop[3]
            out[8+r] = source[8+r]; out[12+r] = source[12+r] + source[r]*x + source[4+r]*y
        }
    }
}
