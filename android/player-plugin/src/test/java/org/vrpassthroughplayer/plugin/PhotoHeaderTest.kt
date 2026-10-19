package org.vrpassthroughplayer.plugin

import org.junit.Assert.*
import org.junit.Test

class PhotoHeaderTest {
    @Test fun undefinedExifOrientationPreservesPixelOrderAndAllowsUhdRegions() {
        assertEquals(1, PhotoHeader.normalizedOrientation(0))
        assertEquals(1, PhotoHeader.normalizedOrientation(-1))
        assertEquals(1, PhotoHeader.normalizedOrientation(255))
        for (orientation in 1..8) assertEquals(orientation, PhotoHeader.normalizedOrientation(orientation))
    }
    @Test fun pngDimensionsArriveWithoutPixelData() {
        val b = ByteArray(32)
        byteArrayOf(0x89.toByte(), 80, 78, 71).copyInto(b)
        b[18] = 0x20; b[22] = 0x10
        assertEquals(PhotoHeader(8192, 4096), PhotoHeader.read(b))
        b[16] = 0x7f
        assertNull("Unbounded dimensions are rejected", PhotoHeader.read(b))
    }

    @Test fun jpegReadsOrientationAndBoundsBeforeCompressedScan() {
        val exif = byteArrayOf(69,120,105,102,0,0,73,73,42,0,8,0,0,0,1,0,18,1,3,0,1,0,0,0,6,0,0,0,0,0,0,0)
        val b = byteArrayOf(0xff.toByte(),0xd8.toByte(),0xff.toByte(),0xe1.toByte(),0,34) + exif +
            byteArrayOf(0xff.toByte(),0xc2.toByte(),0,8,8,0x10,0,0x20,0,3,0xff.toByte(),0xda.toByte())
        assertEquals(PhotoHeader(8192, 4096, 6), PhotoHeader.read(b))
        assertNull(PhotoHeader.read(b.copyOf(30)))
        // A bogus EXIF table offset cannot overflow back into the prefix.
        val malformed = b.clone()
        for (i in 16..19) malformed[i] = 0xff.toByte()
        assertEquals(PhotoHeader(8192,4096), PhotoHeader.read(malformed))
    }

    @Test fun webpHandlesExtendedLosslessAndLossyHeaders() {
        fun prefix(format: String): ByteArray = ByteArray(32).apply {
            "RIFF".toByteArray().copyInto(this); "WEBP".toByteArray().copyInto(this,8)
            format.toByteArray().copyInto(this,12)
        }
        val extended = prefix("VP8X").apply { this[24]=0xff.toByte(); this[25]=0x0f; this[27]=0xff.toByte(); this[28]=0x07 }
        assertEquals(PhotoHeader(4096,2048),PhotoHeader.read(extended))
        val lossless = prefix("VP8L").apply { this[20]=0x2f; this[21]=0xff.toByte(); this[22]=0x03; this[23]=0x80.toByte() }
        assertEquals(PhotoHeader(1024,513),PhotoHeader.read(lossless))
        val lossy = prefix("VP8 ").apply { this[23]=0x9d.toByte(); this[24]=1; this[25]=0x2a; this[27]=4; this[29]=2 }
        assertEquals(PhotoHeader(1024,512),PhotoHeader.read(lossy))
        assertNull(PhotoHeader.read(ByteArray(100)))
        assertNull(PhotoHeader.read(ByteArray(10)))
    }
}
