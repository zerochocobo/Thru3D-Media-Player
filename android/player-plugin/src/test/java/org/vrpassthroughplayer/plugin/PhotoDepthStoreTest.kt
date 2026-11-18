package org.vrpassthroughplayer.plugin

import java.io.File
import java.nio.ByteBuffer
import java.nio.ByteOrder
import java.nio.file.Files
import kotlin.math.abs
import org.junit.Assert.*
import org.junit.Test

class PhotoDepthStoreTest {
    private fun near(width: Int, height: Int, seed: Int): ByteBuffer {
        val buffer = ByteBuffer.allocateDirect(width * height * 4).order(ByteOrder.LITTLE_ENDIAN)
        repeat(width * height) { buffer.putFloat(((it * 31 + seed * 97) % 1000) / 999f) }
        buffer.rewind()
        return buffer
    }

    @Test fun mapReturnsWithinSixteenBitsForTheSameBytesAndVariant() {
        val cache = Files.createTempDirectory("photo-depth-store").toFile()
        try {
            val store = PhotoDepthStore(cache)
            val picture = File(cache, "picture").apply { writeBytes(ByteArray(200_000) { (it % 251).toByte() }) }
            val copy = File(cache, "elsewhere").apply { writeBytes(picture.readBytes()) }
            val other = File(cache, "other").apply { writeBytes(ByteArray(200_000) { (it % 241).toByte() }) }
            val key = store.key(picture, "model")
            assertEquals(key, store.key(copy, "model"))
            assertNotEquals(key, store.key(other, "model"))
            assertNotEquals(key, store.key(picture, "model-left"))
            assertNull(store.get(key, 37, 29))
            val source = near(37, 29, 1)
            val rect = floatArrayOf(0f, 0.125f, 1f, 0.75f)
            assertTrue(store.put(key, source, 37, 29, rect))
            assertEquals(0, source.position())
            val entry = store.get(key, 37, 29)!!
            assertArrayEquals(rect, entry.rect, 0f)
            assertEquals(37 * 29 * 4, entry.near.remaining())
            val expected = source.asFloatBuffer(); val actual = entry.near.asFloatBuffer()
            repeat(37 * 29) { assertTrue(abs(expected.get() - actual.get()) <= 1f / 65535f) }
            assertNull(store.get(key, 29, 37))
        } finally { cache.deleteRecursively() }
    }

    @Test fun photoSizedMapsOfAnyCompressibilityReturn() {
        val cache = Files.createTempDirectory("photo-depth-store").toFile()
        try {
            val store = PhotoDepthStore(cache)
            val size = PhotoDepthInput.WIDTH
            val smooth = ByteBuffer.allocateDirect(size * size * 4).order(ByteOrder.LITTLE_ENDIAN)
            repeat(size * size) { smooth.putFloat((it / size) / (size - 1f)) }
            smooth.rewind()
            val steps = ByteBuffer.allocateDirect(size * size * 4).order(ByteOrder.LITTLE_ENDIAN)
            repeat(size * size) { steps.putFloat(if (it < size * size / 2) 0.35f else 0.36f) }
            steps.rewind()
            for ((name, map) in listOf("smooth" to smooth, "steps" to steps, "noise" to near(size, size, 5))) {
                assertTrue(name, store.put(name, map, size, size, floatArrayOf(0f, 0f, 1f, 1f)))
                val entry = store.get(name, size, size)
                assertNotNull(name, entry)
                val expected = map.asFloatBuffer(); val actual = entry!!.near.asFloatBuffer()
                repeat(size * size) { assertTrue(name, abs(expected.get() - actual.get()) <= 1f / 65535f) }
            }
        } finally { cache.deleteRecursively() }
    }

    @Test fun damagedEntryIsDroppedAndNonFiniteMapIsRefused() {
        val cache = Files.createTempDirectory("photo-depth-store").toFile()
        try {
            val store = PhotoDepthStore(cache)
            assertTrue(store.put("a", near(16, 16, 2), 16, 16, floatArrayOf(0f, 0f, 1f, 1f)))
            val file = File(cache, "${PhotoDepthStore.NAME}/a.d16")
            file.writeBytes(file.readBytes().copyOf(40))
            assertNull(store.get("a", 16, 16))
            assertFalse(file.exists())
            val broken = near(16, 16, 3).apply { putFloat(0, Float.NaN) }
            assertFalse(store.put("b", broken, 16, 16, floatArrayOf(0f, 0f, 1f, 1f)))
            assertFalse(File(cache, "${PhotoDepthStore.NAME}/b.d16").exists())
            val flat = ByteBuffer.allocateDirect(16 * 16 * 4).order(ByteOrder.LITTLE_ENDIAN)
            repeat(16 * 16) { flat.putFloat(0.35f) }
            flat.rewind()
            assertFalse(store.put("c", flat, 16, 16, floatArrayOf(0f, 0f, 1f, 1f)))
        } finally { cache.deleteRecursively() }
    }

    @Test fun oldestEntriesMakeRoomAndTheCacheCleanerOwnsTheDirectory() {
        val cache = Files.createTempDirectory("photo-depth-store").toFile()
        try {
            val one = PhotoDepthStore(cache)
            assertTrue(one.put("first", near(64, 64, 4), 64, 64, floatArrayOf(0f, 0f, 1f, 1f)))
            val size = File(cache, "${PhotoDepthStore.NAME}/first.d16").length()
            val store = PhotoDepthStore(cache, size * 2 + size / 2)
            File(cache, "${PhotoDepthStore.NAME}/first.d16").setLastModified(1_000_000)
            assertTrue(store.put("second", near(64, 64, 4), 64, 64, floatArrayOf(0f, 0f, 1f, 1f)))
            File(cache, "${PhotoDepthStore.NAME}/second.d16").setLastModified(2_000_000)
            assertNotNull(store.get("first", 64, 64)) // read again: now the newest
            assertTrue(store.put("third", near(64, 64, 4), 64, 64, floatArrayOf(0f, 0f, 1f, 1f)))
            assertNotNull(store.get("first", 64, 64))
            assertNull(store.get("second", 64, 64))
            assertNotNull(store.get("third", 64, 64))
            assertEquals(2L, PhotoCache.usage(cache).first)
            PhotoCache.clear(cache, emptySet(), leftovers = true) // at app start
            assertEquals(2L, PhotoCache.usage(cache).first)
            PhotoCache.clear(cache, emptySet())
            assertEquals(0L to 0L, PhotoCache.usage(cache))
            assertNull(store.get("first", 64, 64))
        } finally { cache.deleteRecursively() }
    }
}
