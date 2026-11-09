package org.vrpassthroughplayer.plugin

import org.junit.Assert.*
import org.junit.Test
import java.io.File
import java.nio.ByteBuffer
import java.nio.ByteOrder
import java.nio.file.Files

class RawPhotoTest {
    @Test fun straightAlphaAndAllChannelValuesArePreserved() {
        val pixels=IntArray(1024) { i -> ((i%256) shl 24) or (((i*17)%256) shl 16) or (((i*31)%256) shl 8) or ((i*73)%256) }
        val bytes=ByteArray(pixels.size*4)
        RawPhoto.rgba(pixels,bytes)
        for(i in pixels.indices) {
            val at=i*4
            val p=((bytes[at+3].toInt() and 255) shl 24) or ((bytes[at].toInt() and 255) shl 16) or
                ((bytes[at+1].toInt() and 255) shl 8) or (bytes[at+2].toInt() and 255)
            assertEquals(pixels[i],p)
        }
    }
    @Test fun invalidDimensionsFailBeforeCreatingOutput() {
        for((w,h) in listOf(0 to 10, -1 to 1, 8193 to 1, 8192 to 8192, Int.MAX_VALUE to Int.MAX_VALUE))
            assertThrows(IllegalArgumentException::class.java) { RawPhoto.header(w,h) }
        assertEquals(16,RawPhoto.header(8192,4096).size)
    }
    @Test fun publishedFileHasExactPortableHeaderAndPayload() {
        val dir=Files.createTempDirectory("raw-photo-test").toFile()
        try {
            val file=File(dir,"preview.t3di"); val pixels=ByteArray(257*31*4) { (it*37).toByte() }
            RawPhoto.writeRgba(file,257,31,pixels)
            val bytes=file.readBytes(); val header=ByteBuffer.wrap(bytes).order(ByteOrder.LITTLE_ENDIAN)
            assertEquals("T3DI",String(bytes,0,4,Charsets.US_ASCII))
            assertEquals(257,header.getInt(4)); assertEquals(31,header.getInt(8)); assertEquals(2,header.getInt(12))
            assertArrayEquals(pixels,bytes.copyOfRange(16,bytes.size)); assertEquals(1,dir.listFiles()!!.size)
            val next=ByteArray(pixels.size) { (it*13).toByte() }
            RawPhoto.writeRgba(file,257,31,next)
            assertArrayEquals(next,file.readBytes().copyOfRange(16,bytes.size))
            assertEquals(1,dir.listFiles()!!.size)
        } finally { dir.deleteRecursively() }
    }
    @Test fun legacyHdrCacheRetainsItsPremultipliedInterpretation() {
        val dir=Files.createTempDirectory("raw-photo-alpha").toFile()
        try {
            val file=File(dir,"new.t3di")
            RawPhoto.writeRgba(file,1,1,byteArrayOf(128.toByte(),64,32,128.toByte()))
            assertTrue(RawPhoto.straightAlpha(file))
            val legacy=file.readBytes(); ByteBuffer.wrap(legacy).order(ByteOrder.LITTLE_ENDIAN).putInt(12,1)
            file.writeBytes(legacy)
            assertFalse(RawPhoto.straightAlpha(file))
        } finally { dir.deleteRecursively() }
    }
    @Test fun cancellationAndShortWriteKeepPreviousResultAndRemoveTemporary() {
        val dir=Files.createTempDirectory("raw-photo-cancel").toFile()
        try {
            val file=File(dir,"tile.t3di"); val prior=byteArrayOf(9,8,7); file.writeBytes(prior)
            var checks=0
            assertThrows(InterruptedException::class.java) {
                RawPhoto.writeRgba(file,1028,1028,ByteArray(1028*1028*4), { if(++checks==4)throw InterruptedException() })
            }
            assertArrayEquals(prior,file.readBytes()); assertEquals(1,dir.listFiles()!!.size)
            assertThrows(IllegalArgumentException::class.java) { RawPhoto.write(file,10,10) { it.write(byteArrayOf(1)) } }
            assertArrayEquals(prior,file.readBytes()); assertEquals(1,dir.listFiles()!!.size)
        } finally { dir.deleteRecursively() }
    }
}
