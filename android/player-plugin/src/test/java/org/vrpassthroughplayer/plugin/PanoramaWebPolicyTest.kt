package org.vrpassthroughplayer.plugin

import org.junit.Assert.*
import org.junit.Test

class PanoramaWebPolicyTest {
    @Test fun tiffOriginalsAndCommonsImageOverlaysAreRecognizedWithoutTreatingDescriptionPagesAsImages() {
        assertTrue(PanoramaWebPolicy.imageNavigation("https://storage.noirlab.edu/media/archives/images/original/sky.tif", true, "GET"))
        assertTrue(PanoramaWebPolicy.imageNavigation("https://cdn.example.org/sky.TIFF?download=1", true, "GET"))
        assertFalse(PanoramaWebPolicy.imageNavigation("https://commons.wikimedia.org/wiki/File:sky.tiff", true, "GET"))
        assertTrue(PanoramaWebPolicy.mediaOverlay("https://commons.wikimedia.org/wiki/File:sky.jpg#/media/File:sky.jpg"))
        assertFalse(PanoramaWebPolicy.mediaOverlay("https://example.org/#/media/File:sky.jpg"))
        assertFalse(PanoramaWebPolicy.mediaOverlay("https://commons.wikimedia.org/wiki/File:sky.jpg"))
        assertEquals("image/tiff", PanoramaWebPolicy.mime("image/x-tiff; charset=binary"))
        for (header in listOf(byteArrayOf(73,73,42,0),byteArrayOf(77,77,0,42),byteArrayOf(73,73,43,0),byteArrayOf(77,77,0,43)))
            assertTrue(PanoramaWebPolicy.imageHeader(header.copyOf(12)))
        assertFalse(PanoramaWebPolicy.imageHeader("<html>error</html>".toByteArray()))
    }
    @Test fun wikiImageDescriptionStaysInBrowserWhileCdnOriginalIsIntercepted() {
        assertFalse(PanoramaWebPolicy.imageNavigation("https://commons.wikimedia.org/wiki/File:Laon_Cathedral.jpg", true, "GET"))
        assertTrue(PanoramaWebPolicy.imageNavigation("https://upload.wikimedia.org/wikipedia/commons/8/82/Laon_Cathedral.jpg", true, "GET"))
    }
    @Test fun onlyExplicitMainFrameImagesLeaveTheWebsite() {
        val url = "https://cdn.example.org/original/sky.JPG?download=1"
        assertTrue(PanoramaWebPolicy.imageNavigation(url, true, "GET"))
        assertFalse(PanoramaWebPolicy.imageNavigation(url, false, "GET"))
        assertFalse(PanoramaWebPolicy.imageNavigation(url, true, "POST"))
        assertFalse(PanoramaWebPolicy.imageNavigation("https://example.org/photo.jpg/details", true, "GET"))
        assertFalse(PanoramaWebPolicy.imageNavigation("https://example.org/?file=sky.jpg", true, "GET"))
    }
    @Test fun localSchemesAndCredentialsAreNeverPassedToDownloader() {
        for (url in listOf("file:///data/local/image.jpg", "content://photos/image.jpg", "javascript:alert(1)",
            "data:image/jpeg;base64,AA", "http://example.org/image.jpg", "intent://example.org", "https://user:pass@example.org/image.jpg")) {
            assertFalse(url, PanoramaWebPolicy.allowed(url))
        }
        assertTrue(PanoramaWebPolicy.allowed("https://commons.wikimedia.org/wiki/Category:360%C2%B0_panoramas?uselang=zh"))
    }
    @Test fun referrerContainsOnlyOriginAndNoSearchOrAccountInformation() {
        assertEquals("https://example.org/", PanoramaWebPolicy.origin("https://example.org/photos/private?token=secret#fragment"))
        assertEquals("https://example.org:8443/", PanoramaWebPolicy.origin("https://example.org:8443/sky"))
        assertEquals("", PanoramaWebPolicy.origin("https://user:secret@example.org/"))
    }
    @Test fun highResolutionGateRejectsPreviewsAndMalformedDimensions() {
        for (size in listOf(1024 to 512, 4096 to 2048, 8191 to 4096, 0 to 8192, 20778 to 0, 65536 to 32768, 65535 to 65535))
            assertFalse("$size", PanoramaWebPolicy.highResolution(size.first, size.second))
        for (size in listOf(8192 to 4096, 16384 to 8192, 20778 to 10389, 32768 to 16384))
            assertTrue("$size", PanoramaWebPolicy.highResolution(size.first, size.second))
        assertEquals("image/jpeg", PanoramaWebPolicy.mime(" Image/JPEG ; charset=binary"))
    }
    @Test fun hdrAndExrOriginalsAreRecognizedButDocumentsAndArchivesAreRejected() {
        assertTrue(PanoramaWebPolicy.imageHeader(byteArrayOf(255.toByte(), 216.toByte(), 255.toByte()) + ByteArray(9)))
        assertTrue(PanoramaWebPolicy.imageHeader(byteArrayOf(137.toByte(), 80, 78, 71, 13, 10, 26, 10) + ByteArray(4)))
        assertTrue(PanoramaWebPolicy.imageHeader("RIFF0000WEBP".toByteArray()))
        assertTrue(PanoramaWebPolicy.imageHeader("#?RADIANCE\nFORMAT=32-bit_rle_rgbe".toByteArray()))
        assertTrue(PanoramaWebPolicy.imageHeader("#?RGBE\nFORMAT=32-bit_rle_rgbe".toByteArray()))
        assertTrue(PanoramaWebPolicy.imageHeader(byteArrayOf(0x76,0x2f,0x31,1)+ByteArray(8)))
        for(extension in listOf("HDR","rgbe","exr")) {
            assertTrue(PanoramaWebPolicy.imageNavigation("https://dl.polyhaven.org/file/sky.$extension?download=1",true,"GET"))
            assertFalse(PanoramaWebPolicy.imageNavigation("https://dl.polyhaven.org/file/sky.$extension",false,"GET"))
        }
        assertEquals("image/x-exr",PanoramaWebPolicy.mime("image/exr"))
        assertEquals("image/vnd.radiance",PanoramaWebPolicy.mime("image/x-hdr"))
        for (header in listOf("<!DOCTYPE html>", "PK\u0003\u0004archive", "", "RIFF0000WAVE"))
            assertFalse(header, PanoramaWebPolicy.imageHeader(header.toByteArray()))
    }
}
