package org.vrpassthroughplayer.plugin

import java.io.File
import java.io.RandomAccessFile
import java.nio.ByteBuffer
import java.nio.ByteOrder
import org.junit.Assert.*
import org.junit.Rule
import org.junit.Test
import org.junit.rules.TemporaryFolder

class TiffRegionCacheTest {
    @get:Rule val temporary = TemporaryFolder()
    private fun cache(w: Int, h: Int, version: Int = 1): File {
        val file = temporary.newFile("regions-${System.nanoTime()}.t3di")
        RandomAccessFile(file,"rw").use {
            it.write("T3DI".toByteArray())
            it.write(ByteBuffer.allocate(12).order(ByteOrder.LITTLE_ENDIAN).putInt(w).putInt(h).putInt(version).array())
            if (w>0 && h>0 && w.toLong()*h<1_000_000) it.setLength(16L+w.toLong()*h*4)
        }
        return file
    }
    @Test fun completePrivateCacheHasOriginalDimensions() {
        assertArrayEquals(intArrayOf(640,320),PhotoBitmap.rawBounds(cache(640,320)))
    }
    @Test fun incompleteWrongVersionAndOverflowedCachesNeverReachTheRegionReader() {
        val partial=cache(640,320)
        RandomAccessFile(partial,"rw").use { it.setLength(it.length()-1) }
        for (file in listOf(partial,cache(640,320,2),cache(-1,320),cache(Int.MAX_VALUE,Int.MAX_VALUE)))
            assertTrue(file.name,runCatching { PhotoBitmap.rawBounds(file) }.isFailure)
    }
    @Test fun normalOriginalsAreNotMistakenForInternalRegionCaches() {
        val original=temporary.newFile("picture.tif").apply { writeBytes("T3DI".toByteArray()) }
        assertNull(PhotoBitmap.rawBounds(original))
    }
}
