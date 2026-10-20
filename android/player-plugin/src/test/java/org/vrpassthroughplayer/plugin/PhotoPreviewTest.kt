package org.vrpassthroughplayer.plugin

import org.junit.Assert.*
import org.junit.Test

class PhotoPreviewTest {
    @Test fun samplesLargeAndPortraitPhotosWithoutSquareCropping() {
        assertEquals(512 to 256, PhotoPreviewBridge.dimensions(8192, 4096))
        assertEquals(256 to 512, PhotoPreviewBridge.dimensions(4096, 8192))
        assertEquals(100 to 80, PhotoPreviewBridge.dimensions(100, 80))
        assertEquals(512 to 1, PhotoPreviewBridge.dimensions(32768, 1))
        assertEquals(13 to 512, PhotoPreviewBridge.dimensions(1000, 40000))
        assertEquals(512 to 8, PhotoPreviewBridge.dimensions(65535, 1000))
    }
    @Test fun allLegalSizesFitThePreviewPixelBudget() {
        for (width in listOf(1, 128, 1920, 8192, 32768, 40000, 65535)) {
            for (height in listOf(1, 128, 1080, 8192, 32768, 40000, 65535)) {
                val (w, h) = PhotoPreviewBridge.dimensions(width, height)
                assertTrue(w in 1..512 && h in 1..512)
                assertTrue(w.toLong() * h <= 512L * 512)
            }
        }
    }
    @Test fun invalidDimensionsAreRejectedBeforeBitmapAllocation() {
        for ((width, height) in listOf(0 to 100, -1 to 100, 100 to 65536)) {
            assertThrows(IllegalArgumentException::class.java) { PhotoPreviewBridge.dimensions(width, height) }
        }
    }
}
