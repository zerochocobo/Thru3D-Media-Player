package org.vrpassthroughplayer.plugin

import org.junit.Assert.*
import org.junit.Test

class PanoramaPictureNameTest {
    @Test fun newOriginalsPreserveTheirRealFormat() {
        for(ext in listOf("avif","apng","gif","heif","heic"))
            assertEquals("motion.$ext",PanoramaPictureName.make("motion.jpg","image/$ext",false))
        assertEquals("camera.cr3",PanoramaPictureName.make("camera.CR3","image/x-camera-raw",false))
        assertEquals("camera.nef",PanoramaPictureName.make("camera.jpg","image/x-nikon-nef",false))
    }
    @Test fun savingTiffOriginalKeepsItsFormatAndProjectionSuffix() {
        assertEquals("sky_360_2D.tif", PanoramaPictureName.make("sky.tiff", "image/tiff", true))
    }
    @Test fun savesCorrectFileTypeAndPanoramaHintWithoutChangingBytes() {
        assertEquals("Night sky_360_2D.jpg", PanoramaPictureName.make("Night sky.jpg", "image/jpeg", true))
        assertEquals("Night sky_360_2D.jpg", PanoramaPictureName.make("Night sky_360_2D.jpg", "image/jpeg", true))
        assertEquals("Night sky.png", PanoramaPictureName.make("Night sky.jpg", "image/png", false))
        assertEquals("panorama.webp", PanoramaPictureName.make("...", "image/webp", false))
    }
    @Test fun onlyLeafNamesAndBoundedUtf8ReachMediaStore() {
        assertEquals("sky_360_2D.jpg", PanoramaPictureName.make("../../sky.jpg", "image/jpeg", true))
        assertEquals("sky.jpg", PanoramaPictureName.make("folder\\sky", "image/jpeg", false))
        val name = PanoramaPictureName.make("全景天空".repeat(100) + ".jpg", "image/jpeg", true)
        assertTrue(name.toByteArray(Charsets.UTF_8).size < 200)
        assertTrue(name.endsWith("_360_2D.jpg"))
        assertFalse(PanoramaPictureName.make("image:<test>.jpg", "image/jpeg", false).contains(':'))
    }
}
