package org.vrpassthroughplayer.plugin

import org.junit.Assert.*
import org.junit.Test

class ComicPageCacheTest {
    @Test fun identityIncludesEveryPixelAndPageGeometry(){
        val rgb=ByteArray(16*32*3){it.toByte()}
        val key=ComicPageCache.key(16,32,rgb)
        assertEquals(key,ComicPageCache.key(16,32,rgb.copyOf()))
        assertNotEquals(key,ComicPageCache.key(32,16,rgb))
        rgb[rgb.lastIndex]=(rgb.last()+1).toByte()
        assertNotEquals(key,ComicPageCache.key(16,32,rgb))
        assertNotEquals(ComicPageCache.speechKey(key,0,"Mei","ja"),ComicPageCache.speechKey(key,0,"Xiaoyu","ja"))
        assertNotEquals(ComicPageCache.speechKey(key,0,"Mei","ja"),ComicPageCache.speechKey(key,0,"Mei","zh"))
    }
    @Test fun cacheEvictsByRecencyAndBytesAndReleaseForgetsEverything(){
        val cache=ComicPageCache(2,20)
        cache.put("a","123");cache.put("b","456");assertEquals("123",cache.get("a"))
        cache.put("c","789");assertNull(cache.get("b"));assertEquals(2,cache.size())
        cache.put("large","123456789");assertNull(cache.get("a"));assertNull(cache.get("c"))
        cache.put("oversized","12345678901");assertNull(cache.get("oversized"))
        cache.clear();assertEquals(0,cache.size());assertNull(cache.get("large"))
    }
}
