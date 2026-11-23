package org.vrpassthroughplayer.plugin

import java.io.File
import java.nio.ByteBuffer
import java.nio.ByteOrder
import java.nio.file.Files
import kotlin.math.abs
import org.junit.Assert.*
import org.junit.Test

class PhotoDepthModelTest {
    private fun map(width: Int, height: Int, value: (Int, Int) -> Float): ByteBuffer {
        val buffer = ByteBuffer.allocateDirect(width * height * 4).order(ByteOrder.LITTLE_ENDIAN)
        for (y in 0 until height) for (x in 0 until width) buffer.putFloat(value(x, y))
        buffer.rewind()
        return buffer
    }

    @Test fun fastMapResamplesToTheSharedPhotoMap() {
        val fast = PhotoDepthModel.FAST
        val ramp = map(fast.width, fast.height) { x, _ -> x / (fast.width - 1f) }
        val out = PhotoDepthInput.resample(ramp, fast.width, fast.height)
        assertEquals(PhotoDepthInput.WIDTH * PhotoDepthInput.HEIGHT * 4, out.remaining())
        assertEquals(0, ramp.position())
        val values = out.asFloatBuffer()
        val row = FloatArray(PhotoDepthInput.WIDTH) { values.get(it) }
        assertEquals(0f, row.first(), 1e-6f)
        assertEquals(1f, row.last(), 1e-6f)
        for (x in 1 until row.size) assertTrue("monotone at $x", row[x] >= row[x - 1])
        // Pixel-centre mapping: the middle of the output is the middle of the input.
        assertEquals(0.5f, (row[258] + row[259]) / 2, 2e-3f)
        val flat = PhotoDepthInput.resample(map(4, 4) { _, _ -> 0.25f }, 4, 4, 7, 5).asFloatBuffer()
        repeat(35) { assertEquals(0.25f, flat.get(), 0f) }
    }

    @Test fun modelsAndModesHaveStableNames() {
        assertEquals("da2-518-stretch-v2", PhotoDepthModel.QUALITY.cache) // kept maps from earlier releases stay valid
        assertEquals(PhotoDepthModel.FAST, PhotoDepthModel.ofCache("zip-512-stretch-v1"))
        assertNull(PhotoDepthModel.ofCache("da2-518-stretch-v1"))
        assertEquals(PhotoDepthModel.FAST, PhotoDepthMode.PROGRESSIVE.firstModel)
        assertEquals(PhotoDepthModel.FAST, PhotoDepthMode.FAST.firstModel)
        assertEquals(PhotoDepthModel.QUALITY, PhotoDepthMode.QUALITY.firstModel)
        assertEquals(PhotoDepthMode.QUALITY, PhotoDepthMode.of("quality"))
        assertNull(PhotoDepthMode.of("turbo"))
    }

    @Test fun storeKeysReadTheFileOnceWithTheSameResultAsSingleKeys() {
        val cache = Files.createTempDirectory("photo-depth-keys").toFile()
        try {
            val store = PhotoDepthStore(cache)
            val picture = File(cache, "picture").apply { writeBytes(ByteArray(300_000) { (it % 253).toByte() }) }
            val variants = PhotoDepthModel.entries.flatMap { listOf(it.cache, it.cache + "-left") }
            val keys = store.keys(picture, variants)
            assertEquals(4, keys.values.toSet().size)
            for (variant in variants) assertEquals(store.key(picture, variant), keys[variant])
        } finally { cache.deleteRecursively() }
    }

    @Test fun fastPairsNeverAnswerForQualityPairs() {
        val quality = PhotoStereo.cachePrefix(1f, 0)
        val fast = PhotoStereo.cachePrefix(1f, 0, fast = true)
        assertTrue(quality.startsWith("stereo-v9-"))
        assertFalse(fast.startsWith(quality))
        assertFalse(quality.startsWith(fast))
        assertTrue(abs(fast.length - quality.length) == 1)
    }
}
