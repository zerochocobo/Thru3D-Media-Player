package org.vrpassthroughplayer.plugin

import org.junit.Assert.*
import org.junit.Test
import kotlin.math.roundToInt

class WebBrowserViewportTest {
    @Test fun defaultLayoutIs1440By900AtBothRasterQualities() {
        for (low in listOf(false, true)) {
            val profile = WebBrowserViewport(low)
            assertEquals(1440f, profile.width / profile.density, 0.001f)
            assertEquals(900f, profile.height / profile.density, 0.001f)
            assertTrue(profile.width * profile.height <= if (low) 1920 * 1200 else 2560 * 1600)
            // Mirror Gecko's integer app-unit quantization, not just a float division.
            val appUnits = (60f / profile.density).roundToInt()
            assertEquals(1440 * 60, profile.width * appUnits)
            assertEquals(900 * 60, profile.height * appUnits)
        }
    }

    @Test fun rasterScalingCannotMoveResizedWindowsAcrossCssBreakpoints() {
        val profiles = listOf(WebBrowserViewport(false), WebBrowserViewport(true))
        for (width in 1281..1920 step 3) {
            val cssWidths = profiles.map { profile ->
                val pixels = width / 3 * profile.pixelUnits
                pixels * (60f / profile.density).roundToInt() / 60f
            }
            assertEquals(width.toFloat(), cssWidths[0], 0f)
            assertEquals(cssWidths[0], cssWidths[1], 0f)
            for (breakpoint in listOf(992, 1024, 1200, 1230, 1280, 1400, 1450, 1536)) {
                assertEquals(cssWidths[0] >= breakpoint, cssWidths[1] >= breakpoint)
            }
        }
    }

    @Test fun rayCoordinatesCoverTheSameCssContentInBothTiers() {
        for (low in listOf(false, true)) {
            val profile = WebBrowserViewport(low)
            for (uv in listOf(0f, 0.01f, 0.5f, 0.99f, 1f)) {
                // Existing input addresses actual Surface pixels, up to the last pixel.
                val cssX = uv * (profile.width - 1) / profile.density
                val cssY = uv * (profile.height - 1) / profile.density
                assertEquals(uv * 1440, cssX, 1f)
                assertEquals(uv * 900, cssY, 1f)
            }
        }
    }
}
