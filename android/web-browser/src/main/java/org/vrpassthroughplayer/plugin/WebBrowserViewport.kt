package org.vrpassthroughplayer.plugin

/** Raster quality is independent of the desktop CSS viewport, including on XR2 Gen1. */
internal class WebBrowserViewport(val lowEnd: Boolean, units: Int = if (lowEnd) 4 else 5) {
    companion object {
        const val WIDTH = 1440
        const val HEIGHT = 900
        const val CSS_UNITS = 3
        /** Browser clarity choices: low, medium, high. */
        val PIXEL_UNITS = 3..5
    }

    // Gecko rounds 60 / density to integer app units. 3/3, 4/3 and 5/3 are exact in that
    // representation (60, 45 and 36 app units); 2560 / 1440 is not. Keep every budget
    // below the previous 2560x1600 allocation.
    val pixelUnits = units.coerceIn(PIXEL_UNITS)
    val density = pixelUnits.toFloat() / CSS_UNITS
    val dpi = kotlin.math.round(160f * density).toInt()
    val width = WIDTH / CSS_UNITS * pixelUnits
    val height = HEIGHT / CSS_UNITS * pixelUnits
}
