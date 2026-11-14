package org.vrpassthroughplayer.plugin

import org.junit.Assert.*
import org.junit.Test
import kotlin.math.roundToInt

class WebBrowserViewportTest {
    private val tiers = WebBrowserViewport.PIXEL_UNITS.map { WebBrowserViewport(false, it) }

    @Test fun defaultLayoutIs1440By900AtEveryRasterQuality() {
        for (profile in tiers) {
            assertEquals(1440f, profile.width / profile.density, 0.001f)
            assertEquals(900f, profile.height / profile.density, 0.001f)
            assertTrue(profile.width * profile.height <= 2560 * 1600)
            // Mirror Gecko's integer app-unit quantization, not just a float division.
            val appUnits = (60f / profile.density).roundToInt()
            assertEquals(1440 * 60, profile.width * appUnits)
            assertEquals(900 * 60, profile.height * appUnits)
        }
    }

    @Test fun rasterScalingCannotMoveResizedWindowsAcrossCssBreakpoints() {
        val profiles = tiers
        for (width in 720..1920 step 3) {
            val cssWidths = profiles.map { profile ->
                val pixels = width / 3 * profile.pixelUnits
                pixels * (60f / profile.density).roundToInt() / 60f
            }
            assertEquals(width.toFloat(), cssWidths[0], 0f)
            for (css in cssWidths) {
                assertEquals(cssWidths[0], css, 0f)
                for (breakpoint in listOf(720, 768, 800, 992, 1024, 1200, 1230, 1280, 1400, 1450, 1536)) {
                    assertEquals(cssWidths[0] >= breakpoint, css >= breakpoint)
                }
            }
        }
    }

    @Test fun rayCoordinatesCoverTheSameCssContentInEveryTier() {
        for (profile in tiers) {
            for (uv in listOf(0f, 0.01f, 0.5f, 0.99f, 1f)) {
                // Existing input addresses actual Surface pixels, up to the last pixel.
                val cssX = uv * (profile.width - 1) / profile.density
                val cssY = uv * (profile.height - 1) / profile.density
                assertEquals(uv * 1440, cssX, 1f)
                assertEquals(uv * 900, cssY, 1f)
            }
        }
    }

    @Test fun clarityTiersAndGpuDefaults() {
        assertEquals(listOf(1440 to 900, 1920 to 1200, 2400 to 1500), tiers.map { it.width to it.height })
        assertEquals(4, WebBrowserViewport(true).pixelUnits)
        assertEquals(5, WebBrowserViewport(false).pixelUnits)
        // A stale or hand-edited choice stays within the supported budgets.
        assertEquals(3, WebBrowserViewport(false, 1).pixelUnits)
        assertEquals(5, WebBrowserViewport(true, 9).pixelUnits)
        assertTrue(WebBrowserViewport(false, 3).lowEnd.not())
    }
}
