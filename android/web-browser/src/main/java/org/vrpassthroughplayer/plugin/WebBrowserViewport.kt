package org.vrpassthroughplayer.plugin

/** Raster quality is independent of the desktop CSS viewport, including on XR2 Gen1. */
internal class WebBrowserViewport(val lowEnd: Boolean) {
    companion object {
        const val WIDTH = 1440
        const val HEIGHT = 900
        const val CSS_UNITS = 3
    }

    // Gecko rounds 60 / density to integer app units. 5/3 and 4/3 are exact in that
    // representation (36 and 45 app units); 2560 / 1440 is not. Keep both budgets
    // below the previous 2560x1600 / 1920x1200 allocation.
    val pixelUnits = if (lowEnd) 4 else 5
    val density = pixelUnits.toFloat() / CSS_UNITS
    val dpi = kotlin.math.round(160f * density).toInt()
    val width = WIDTH / CSS_UNITS * pixelUnits
    val height = HEIGHT / CSS_UNITS * pixelUnits
}
