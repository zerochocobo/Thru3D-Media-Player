package org.vrpassthroughplayer.plugin

import android.graphics.Bitmap
import java.io.ByteArrayOutputStream
import java.io.File
import java.io.OutputStream

internal object BitmapTransfer {
    private fun rows(bitmap: Bitmap, output: OutputStream, check: () -> Unit) {
        val lines=minOf(16,bitmap.height)
        val argb=IntArray(bitmap.width*lines); val rgba=ByteArray(argb.size*4)
        for(y in 0 until bitmap.height step lines) {
            check(); val h=minOf(lines,bitmap.height-y)
            bitmap.getPixels(argb,0,bitmap.width,0,y,bitmap.width,h)
            RawPhoto.rgba(argb,rgba,bitmap.width*h); output.write(rgba,0,bitmap.width*h*4)
        }
    }
    fun write(file: File, bitmap: Bitmap, check: () -> Unit = {}) =
        RawPhoto.write(file,bitmap.width,bitmap.height,check) { rows(bitmap,it,check) }
    // Small bridge payloads only (embedded cover); large photos always use bounded file writes.
    fun bytes(bitmap: Bitmap): ByteArray {
        require(bitmap.width <= 1024 && bitmap.height <= 1024)
        return ByteArrayOutputStream(16+bitmap.width*bitmap.height*4).also {
            it.write(RawPhoto.header(bitmap.width,bitmap.height)); rows(bitmap,it,{})
        }.toByteArray()
    }
}
