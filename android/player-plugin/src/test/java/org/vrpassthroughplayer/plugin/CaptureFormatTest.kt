package org.vrpassthroughplayer.plugin

import org.json.JSONObject
import org.junit.Assert.*
import org.junit.Test
import java.io.ByteArrayInputStream
import java.io.ByteArrayOutputStream
import java.util.Base64

class CaptureFormatTest {
    @Test fun flatLayoutRequiresExplicitOptIn() {
        val flat = mode(0, false)
        assertEquals(0, CaptureFormat.clean(flat, allowFlat = true).getInt("geometry"))
        try { CaptureFormat.clean(flat); fail("Flat layout accepted without opt-in") } catch (_: IllegalArgumentException) { }
    }
    private val png = Base64.getDecoder().decode("iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mP8/x8AAwMCAO+jRz8AAAAASUVORK5CYII=")
    private fun mode(geometry: Int, tb: Boolean) = JSONObject().put("version", 1).put("geometry", geometry)
        .put("stereo_sbs", true).put("top_bottom", tb).put("stereo_half", false).put("swap_eyes", true).put("fisheye_fov", 190)

    @Test fun portableLayoutsRoundTripWithoutSourceIdentityOrPixelChanges() {
        for (geometry in 0..3) for (tb in listOf(false, true)) {
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

    @Test fun streamedJpegPreservesPixelsAndPortableLayoutsAcrossHeaderSplits() {
        // Real synthetic 16x8 JPEG; the entire encoded payload must remain byte-identical.
        val original = Base64.getDecoder().decode("/9j/4AAQSkZJRgABAQAAAQABAAD/2wBDAAgGBgcGBQgHBwcJCQgKDBQNDAsLDBkSEw8UHRofHh0aHBwgJC4nICIsIxwcKDcpLDAxNDQ0Hyc5PTgyPC4zNDL/2wBDAQgJCQwLDBgNDRgyIRwhMjIyMjIyMjIyMjIyMjIyMjIyMjIyMjIyMjIyMjIyMjIyMjIyMjIyMjIyMjIyMjIyMjL/wAARCAAIABADASIAAhEBAxEB/8QAHwAAAQUBAQEBAQEAAAAAAAAAAAECAwQFBgcICQoL/8QAtRAAAgEDAwIEAwUFBAQAAAF9AQIDAAQRBRIhMUEGE1FhByJxFDKBkaEII0KxwRVS0fAkM2JyggkKFhcYGRolJicoKSo0NTY3ODk6Q0RFRkdISUpTVFVWV1hZWmNkZWZnaGlqc3R1dnd4eXqDhIWGh4iJipKTlJWWl5iZmqKjpKWmp6ipqrKztLW2t7i5usLDxMXGx8jJytLT1NXW19jZ2uHi4+Tl5ufo6erx8vP09fb3+Pn6/8QAHwEAAwEBAQEBAQEBAQAAAAAAAAECAwQFBgcICQoL/8QAtREAAgECBAQDBAcFBAQAAQJ3AAECAxEEBSExBhJBUQdhcRMiMoEIFEKRobHBCSMzUvAVYnLRChYkNOEl8RcYGRomJygpKjU2Nzg5OkNERUZHSElKU1RVVldYWVpjZGVmZ2hpanN0dXZ3eHl6goOEhYaHiImKkpOUlZaXmJmaoqOkpaanqKmqsrO0tba3uLm6wsPExcbHyMnK0tPU1dbX2Nna4uPk5ebn6Onq8vP09fb3+Pn6/9oADAMBAAIRAxEAPwDmLHwV0/dfpXR2Pgrp+6/SiivJxWZYjuebkGb4nTU//9k=")
        for (geometry in 0..3) for (tb in listOf(false, true)) for (chunk in listOf(1, 2, 3, 1024)) {
            val output = ByteArrayOutputStream()
            val count = CaptureFormat.jpeg(output, mode(geometry, tb).put("uri", "smb://private/source")) { stream ->
                var offset = 0
                while (offset < original.size) {
                    val length = minOf(chunk, original.size - offset)
                    stream.write(original, offset, length); offset += length
                }
            }
            val bytes = output.toByteArray()
            assertEquals(bytes.size.toLong(), count)
            val restored = CaptureFormat.read(bytes.inputStream())!!
            assertEquals(geometry, restored.getInt("geometry")); assertEquals(tb, restored.getBoolean("top_bottom"))
            assertTrue(restored.getBoolean("swap_eyes")); assertFalse(restored.has("uri"))
            val added = bytes.size - original.size
            assertArrayEquals(original.copyOfRange(2, original.size), bytes.copyOfRange(2 + added, bytes.size))
        }
        assertNull(CaptureFormat.read(original.inputStream()))
        val pngOutput = ByteArrayOutputStream()
        CaptureFormat.png(png.inputStream(), pngOutput, mode(3, false))
        assertEquals(3, CaptureFormat.read(pngOutput.toByteArray().inputStream())!!.getInt("geometry"))
    }

    @Test fun damagedOrUnboundedJpegMetadataIsIgnored() {
        val output = ByteArrayOutputStream()
        CaptureFormat.jpeg(output, mode(2, true)) { it.write(byteArrayOf(-1, -40, -1, -39)) }
        val damaged = output.toByteArray(); damaged[70] = (damaged[70].toInt() xor 1).toByte()
        assertNull(CaptureFormat.read(damaged.inputStream()))
        assertNull(CaptureFormat.read(output.toByteArray().copyOf(20).inputStream()))
        assertNull(CaptureFormat.read(byteArrayOf(-1, -40, -1, -17, -1, -1).inputStream()))
        assertNull(CaptureFormat.read(byteArrayOf(-1, -40, -1, -38, 0, 2).inputStream()))
        for (header in listOf(byteArrayOf(), byteArrayOf(-1), byteArrayOf(0, 0))) {
            try {
                CaptureFormat.jpeg(ByteArrayOutputStream(), mode(1, false)) { it.write(header) }
                fail("Invalid JPEG accepted")
            } catch (_: IllegalArgumentException) { }
        }
    }
}
