package org.vrpassthroughplayer.plugin

import java.io.File
import java.io.OutputStream
import java.io.RandomAccessFile
import java.nio.ByteBuffer
import java.nio.ByteOrder
import java.nio.file.Files
import java.nio.file.StandardCopyOption.ATOMIC_MOVE
import java.nio.file.StandardCopyOption.REPLACE_EXISTING

/** Internal T3DI v2: 16-byte LE header, tightly packed straight-alpha sRGB RGBA8.
 * V1 native HDR caches contain Bitmap-premultiplied rows; never reinterpret those as v2.
 * Shares the existing magazine/TIFF row layout. Never encode an image just to hand pixels
 * to another component. Writers have bounded scratch, cancellation and atomic publication. */
internal object RawPhoto {
    const val MAX_PIXELS = 32L * 1024 * 1024
    fun header(width: Int, height: Int): ByteArray {
        require(width in 1..8192 && height in 1..8192 && width.toLong()*height <= MAX_PIXELS)
        return ByteBuffer.allocate(16).order(ByteOrder.LITTLE_ENDIAN)
            .put(byteArrayOf(84,51,68,73)).putInt(width).putInt(height).putInt(2).array()
    }
    fun straightAlpha(file: File): Boolean = RandomAccessFile(file,"r").use {
        it.seek(12); Integer.reverseBytes(it.readInt()) == 2
    }
    fun write(file: File, width: Int, height: Int, check: () -> Unit = {}, body: (OutputStream) -> Unit) {
        val header = header(width,height)
        check()
        require(file.parentFile!!.usableSpace > 16 + width.toLong()*height*4 + 64L*1024*1024) { "PHOTO_TOO_LARGE" }
        val temporary = File.createTempFile(file.name + "-", ".part", file.parentFile)
        try {
            temporary.outputStream().buffered(65536).use { output -> output.write(header); body(output) }
            require(temporary.length() == 16 + width.toLong()*height*4) { "PHOTO_DECODE_FAILED" }
            check()
            // Same-directory rename: never expose a partial tile or delete the old one first.
            Files.move(temporary.toPath(),file.toPath(),ATOMIC_MOVE,REPLACE_EXISTING)
        } finally { temporary.delete() }
    }
    fun writeRgba(file: File, width: Int, height: Int, rgba: ByteArray, check: () -> Unit = {}) {
        require(rgba.size.toLong() == width.toLong()*height*4)
        write(file,width,height,check) { output ->
            var at=0
            while(at<rgba.size) { check(); val n=minOf(65536,rgba.size-at); output.write(rgba,at,n); at+=n }
        }
    }
    /** getPixels supplies non-premultiplied sRGB ARGB, unlike copyPixelsToBuffer. */
    fun rgba(argb: IntArray, output: ByteArray, count: Int = argb.size) {
        require(count in 0..argb.size && output.size.toLong() >= count.toLong()*4)
        for(i in 0 until count) { val p=argb[i]; val at=i*4
            output[at]=(p ushr 16).toByte(); output[at+1]=(p ushr 8).toByte()
            output[at+2]=p.toByte(); output[at+3]=(p ushr 24).toByte()
        }
    }
}
