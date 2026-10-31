package org.vrpassthroughplayer.plugin

import android.graphics.Bitmap
import android.graphics.BitmapFactory
import org.json.JSONObject
import java.io.File
import java.nio.ByteBuffer

internal object ExtendedImageNative {
    init { System.loadLibrary("quest_image") }
    external fun kind(path: String, rawHint: Boolean): Int
    external fun open(path: String, edge: Int, preview: Boolean): Long
    external fun info(id: Long): LongArray?
    external fun next(id: Long, checkpoint: Runnable): LongArray?
    external fun pixels(token: Long): ByteArray?
    external fun reset(id: Long)
    external fun releaseFrame(token: Long)
    external fun close(id: Long)
    external fun upload(token: Long, texture: Int, mipmaps: Boolean): Boolean
}

/** Only candidate signatures enter a native probe; directory scans never decode or fetch media. */
internal object ExtendedPhoto {
    const val AVIF = 1
    const val WEBP = 2
    const val GIF = 3
    const val APNG = 4
    const val RAW = 5
    fun kind(file: File): Int {
        val b = file.inputStream().use { it.readBytes(65536) }
        if (b.size < 12) return 0
        fun text(at: Int, count: Int) = String(b, at, count, Charsets.ISO_8859_1)
        val candidate = text(0, 3) == "GIF" || text(4, 4) == "ftyp" || text(0, 4) == "RIFF" ||
            text(0, 2) in setOf("II", "MM") || text(0, 8) == "FUJIFILM"
        if (candidate) return ExtendedImageNative.kind(file.path, false)
        if (b[0] == 0x89.toByte() && text(1, 3) == "PNG") return ExtendedImageNative.kind(file.path, false)
        return 0
    }
    // Kotlin readBytes(Int) is an allocation estimate, not a bound. Read a bounded prefix explicitly.
    private fun java.io.InputStream.readBytes(limit: Int): ByteArray {
        val buffer=ByteArray(limit);var count=0
        while(count<limit) {val n=read(buffer,count,limit-count);if(n<0)break;count+=n}
        return buffer.copyOf(count)
    }
    private data class Decoded(val rgba: ByteArray,val info: LongArray,val width: Int,val height: Int)
    private fun read(file: File,edge: Int,preview: Boolean,check: ()->Unit): Decoded {
        check();var id=ExtendedImageNative.open(file.path,edge.coerceIn(64,8192),preview)
        require(id>0) { "PHOTO_FORMAT_UNSUPPORTED" }
        var token=0L
        try {
            val initial=ExtendedImageNative.info(id) ?: error("PHOTO_DECODE_FAILED")
            if(edge>2048 && initial[3]>1 && initial[0].toInt()!=RAW){ExtendedImageNative.close(id);id=ExtendedImageNative.open(file.path,2048,preview);require(id>0)}
            val frame=ExtendedImageNative.next(id,Runnable {check()}) ?: error("PHOTO_DECODE_FAILED")
            token=frame[0];require(token>0) { "PHOTO_DECODE_FAILED" }
            val info=ExtendedImageNative.info(id) ?: error("PHOTO_DECODE_FAILED")
            val pixels=ExtendedImageNative.pixels(token) ?: error("PHOTO_DECODE_FAILED")
            check();return Decoded(pixels,info,frame[1].toInt(),frame[2].toInt())
        } finally {if(token>0)ExtendedImageNative.releaseFrame(token);ExtendedImageNative.close(id)}
    }
    fun bitmap(file: File, edge: Int, preview: Boolean, check: () -> Unit = {}): Pair<Bitmap, LongArray> {
        val data=read(file,edge,preview,check)
        val image=Bitmap.createBitmap(data.width,data.height,Bitmap.Config.ARGB_8888)
        try {fill(image,data.rgba);return image to data.info}catch(failure: Throwable){image.recycle();throw failure}
    }
    fun fill(bitmap: Bitmap,pixels: ByteArray) {
        require(pixels.size==bitmap.width*bitmap.height*4)
        val row=IntArray(bitmap.width)
        for(y in 0 until bitmap.height){for(x in row.indices){val at=(y*bitmap.width+x)*4
            row[x]=((pixels[at+3].toInt() and 255) shl 24) or ((pixels[at].toInt() and 255) shl 16) or
                ((pixels[at+1].toInt() and 255) shl 8) or (pixels[at+2].toInt() and 255)}
            bitmap.setPixels(row,0,bitmap.width,0,y,bitmap.width,1)}
    }
    fun bounds(file: File): BitmapFactory.Options {
        val id=ExtendedImageNative.open(file.path,512,true);require(id>0) {"PHOTO_FORMAT_UNSUPPORTED"}
        try {val info=ExtendedImageNative.info(id) ?: error("PHOTO_DECODE_FAILED")
            return BitmapFactory.Options().apply {outWidth=info[1].toInt();outHeight=info[2].toInt();outMimeType=mime(info[0].toInt())}
        } finally {ExtendedImageNative.close(id)}
    }
    fun mime(kind: Int) = when(kind) {AVIF->"image/avif";WEBP->"image/webp";GIF->"image/gif";APNG->"image/apng";else->"image/x-camera-raw"}
    fun prepare(source: File,directory: File,preview: Boolean,check: () -> Unit,publish: (JSONObject)->Unit): JSONObject {
        val data=read(source,if(preview)512 else 8192,preview,check)
        val info=data.info
        val image=Bitmap.createBitmap(data.width,data.height,Bitmap.Config.ARGB_8888)
        fill(image,data.rgba)
        try {
            val animated=info[3]>1 && info[0].toInt()!=RAW
            val metadata=JSONObject().put("state","metadata").put("width",info[1]).put("height",info[2])
                .put("orientation",info[5]).put("panorama",false).put("mime",mime(info[0].toInt()))
                .put("animated",animated).put("animation_plays",info[4]).put("raw_preview",info[7]!=0L)
            check();publish(JSONObject(metadata.toString()))
            val path=File(directory,"extended.rgba")
            path.outputStream().use {output->var at=0;while(at<data.rgba.size){check();val count=minOf(65536,data.rgba.size-at);output.write(data.rgba,at,count);at+=count}}
            File(directory,"extended-size.json").writeText(JSONObject().put("width",image.width).put("height",image.height).toString())
            val ratio=minOf(1.0,384.0/maxOf(image.width,image.height))
            val thumb=Bitmap.createScaledBitmap(image,maxOf(1,(image.width*ratio).toInt()),maxOf(1,(image.height*ratio).toInt()),true)
            try {val file=File(directory,"thumbnail.jpg");file.outputStream().use {require(thumb.compress(Bitmap.CompressFormat.JPEG,85,it))};metadata.put("thumbnail_path",file.path)}
            finally {if(thumb!==image)thumb.recycle()}
            check();return metadata.put("state","ready").put("path",path.path).put("raw_rgba",true)
                .put("decoded_width",image.width).put("decoded_height",image.height)
        }finally {image.recycle()}
    }
    fun posterSnapshot(source: File,check: ()->Unit): File {
        check();val root=source.parentFile?:error("PHOTO_DECODE_FAILED")
        val size=JSONObject(File(root,"extended-size.json").readText())
        val width=size.getInt("width");val height=size.getInt("height")
        require(width in 1..8192&&height in 1..8192&&width.toLong()*height<=32*1024*1024)
        val bitmap=Bitmap.createBitmap(width,height,Bitmap.Config.ARGB_8888)
        var file: File?=null
        try{fill(bitmap,File(root,"extended.rgba").readBytes());check()
            file=File.createTempFile("animation-effect-",".png",root)
            file.outputStream().use {require(bitmap.compress(Bitmap.CompressFormat.PNG,100,it))};check();return file
        }catch(failure: Throwable){file?.delete();throw failure}finally {bitmap.recycle()}
    }
}
