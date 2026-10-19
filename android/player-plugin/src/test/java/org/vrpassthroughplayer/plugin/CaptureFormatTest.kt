package org.vrpassthroughplayer.plugin

import org.json.JSONObject
import org.junit.Assert.*
import org.junit.Test
import java.io.ByteArrayInputStream
import java.io.ByteArrayOutputStream
import java.util.Base64

class CaptureFormatTest {
    private val png = Base64.getDecoder().decode("iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mP8/x8AAwMCAO+jRz8AAAAASUVORK5CYII=")
    private fun mode(geometry: Int, tb: Boolean) = JSONObject().put("version", 1).put("geometry", geometry)
        .put("stereo_sbs", true).put("top_bottom", tb).put("stereo_half", false).put("swap_eyes", true).put("fisheye_fov", 190)

    @Test fun portableLayoutsRoundTripWithoutSourceIdentityOrPixelChanges() {
        for (geometry in 1..3) for (tb in listOf(false, true)) {
            val original = mode(geometry, tb).put("uri", "smb://private/source").put("title", "private")
            val output = ByteArrayOutputStream()
            CaptureFormat.png(ByteArrayInputStream(png), output, original)
            val bytes = output.toByteArray()
            val restored = CaptureFormat.readPng(ByteArrayInputStream(bytes))!!
            assertEquals(geometry, restored.getInt("geometry"))
            assertEquals(tb, restored.getBoolean("top_bottom"))
            assertTrue(restored.getBoolean("swap_eyes"))
            assertFalse(restored.has("uri")); assertFalse(restored.has("title"))
            val added = bytes.size - png.size
            assertArrayEquals(png.copyOfRange(33, png.size), bytes.copyOfRange(33 + added, bytes.size))
        }
    }
    @Test fun ordinaryAndDamagedPicturesDoNotGainVrLayout() {
        assertNull(CaptureFormat.readPng(ByteArrayInputStream(png)))
        assertNull(CaptureFormat.readPng(ByteArrayInputStream(byteArrayOf(1, 2, 3))))
        val output = ByteArrayOutputStream()
        CaptureFormat.png(ByteArrayInputStream(png), output, mode(3, false))
        val damaged = output.toByteArray(); damaged[70] = (damaged[70].toInt() xor 1).toByte()
        assertNull(CaptureFormat.readPng(ByteArrayInputStream(damaged)))
    }
    @Test fun unsupportedProjectionIsRejected() {
        for (geometry in listOf(-1, 0, 4, 99)) {
            try { CaptureFormat.clean(mode(geometry, false)); fail("Invalid projection accepted") }
            catch (_: IllegalArgumentException) { }
        }
    }
}
