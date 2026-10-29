package org.vrpassthroughplayer.plugin

import org.junit.After
import org.junit.Assert.*
import org.junit.Test
import java.util.concurrent.atomic.AtomicInteger

class DiscTitlesCacheTest {
    private class Bytes(private val data: ByteArray, val reads: AtomicInteger = AtomicInteger()) : StreamSource {
        override val size = data.size.toLong()
        override fun open() = object : StreamSource.Reader {
            override fun read(offset: Long, buffer: ByteArray, length: Int): Int {
                reads.incrementAndGet()
                val n = minOf(length.toLong(), size - offset).toInt()
                data.copyInto(buffer, 0, offset.toInt(), offset.toInt() + n)
                return n
            }
            override fun close() {}
        }
    }

    @After fun clear() { IsoMetadataMemory.clear(); DiscPreflight.clear() }

    private fun read(cache: IsoReadCache, offset: Long): ByteArray {
        val buffer = ByteArray(2048)
        cache.open().use { assertEquals(2048, it.read(offset, buffer, buffer.size)) }
        return buffer
    }

    @Test fun reopenedDiscStartsFromThePreviousLeaseMetadataBlocks() {
        val data = ByteArray(4 * 65536) { (it % 253).toByte() }
        val key = IsoMetadataMemory.key("account", "/disc.iso", data.size, 1)
        val first = Bytes(data)
        IsoReadCache(first, key).also { read(it, 32768); read(it, 3 * 65536L + 10) }.close()
        val loads = first.reads.get()
        val second = Bytes(data)
        val reopened = IsoReadCache(second, memoryKey = key)
        assertArrayEquals(data.copyOfRange(32768, 32768 + 2048), read(reopened, 32768))
        assertArrayEquals(data.copyOfRange(3 * 65536 + 10, 3 * 65536 + 10 + 2048), read(reopened, 3 * 65536L + 10))
        assertEquals(0, second.reads.get())
        assertEquals(2L, reopened.stats().getValue("recalled_blocks"))
        assertTrue(loads > 0)
        reopened.close()
        // Another object (or the same path with a new size) never sees those bytes.
        val other = IsoReadCache(Bytes(data), memoryKey = IsoMetadataMemory.key("account", "/disc.iso", data.size + 1, 1))
        assertEquals(0L, other.stats().getValue("recalled_blocks")); other.close()
        IsoMetadataMemory.clear()
        val cleared = IsoReadCache(Bytes(data), memoryKey = key)
        assertEquals(0L, cleared.stats().getValue("recalled_blocks")); cleared.close()
    }

    @Test fun onlyTwoDiscsAreKept() {
        val data = ByteArray(65536)
        for (disc in 1..3) IsoReadCache(Bytes(data), memoryKey = "disc$disc").also { read(it, 0) }.close()
        assertTrue(IsoMetadataMemory.recall("disc1").isEmpty())
        assertEquals(1, IsoMetadataMemory.recall("disc2").size)
        assertEquals(1, IsoMetadataMemory.recall("disc3").size)
    }

    @Test fun dvdKeepsAllNinetyNineTitles() {
        val rows = (1..99).joinToString(",") { "{\"playlist\":$it,\"dvd_title\":$it}" }
        val json = """{"width":720,"height":576,"mvc":false,"playlist":1,"disc_type":"dvd","menu":"dvd","titles":[$rows]}"""
        assertEquals(1, DiscPreflight.parse(json).playlist)
        assertThrows(IllegalArgumentException::class.java) {
            DiscPreflight.parse(json.replace("\"disc_type\":\"dvd\",", ""))
        }
        assertThrows(IllegalArgumentException::class.java) {
            DiscPreflight.parse(json.replace("[$rows]", "[$rows,{\"playlist\":100}]"))
        }
    }

    @Test fun preflightIsReusedForTheDefaultAndSelectedTitle() {
        val calls = AtomicInteger()
        val json = """{"width":1920,"height":1080,"duration_us":5,"mvc":false,"playlist":100,"titles":[{"playlist":100},{"playlist":201}]}"""
        val read = { _: String, playlist: Int -> calls.incrementAndGet(); assertEquals(-1, playlist); json }
        val first = DiscPreflight.probe("cloud://a/disc.iso", "http://127.0.0.1/1/disc.iso", -1, read)
        assertEquals(100, first.playlist)
        assertSame(first, DiscPreflight.probe("cloud://a/disc.iso", "http://127.0.0.1/2/disc.iso", -1, read))
        assertSame(first, DiscPreflight.probe("cloud://a/disc.iso", "http://127.0.0.1/3/disc.iso", 100, read))
        assertEquals(1, calls.get())
        assertNull(DiscPreflight.cached("cloud://a/disc.iso", 201))
        assertNull(DiscPreflight.cached("cloud://a/disc.iso", -1, System.currentTimeMillis() + 31 * 60 * 1000L))
        assertThrows(IllegalArgumentException::class.java) {
            DiscPreflight.parse("""{"width":0,"height":1080,"mvc":false,"playlist":1,"titles":[]}""")
        }
    }
}
