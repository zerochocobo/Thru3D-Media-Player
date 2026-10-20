package org.vrpassthroughplayer.plugin

import android.graphics.Bitmap
import android.graphics.BitmapFactory
import android.media.ExifInterface
import org.json.JSONObject
import java.io.File
import java.nio.ByteBuffer
import java.nio.ByteOrder
import java.io.RandomAccessFile

internal object TiffPhotoNative {
    init { System.loadLibrary("quest_tiff") }
    external fun inspect(path: String): IntArray?
    external fun pixels(path: String, left: Int, top: Int, width: Int, height: Int, sample: Int, checkpoint: Runnable, cache: String?): ByteArray?
}

internal object HdrPhotoNative {
    init { System.loadLibrary("quest_hdr") }
    external fun inspect(path: String): IntArray?
    external fun pixels(path: String, left: Int, top: Int, width: Int, height: Int, sample: Int, checkpoint: Runnable, cache: String?): ByteArray?
}

/** Shared by local, SMB, cloud, web originals, previews and the existing photo effects. */
internal object PhotoBitmap {
    fun hdrHeader(bytes: ByteArray): Boolean = bytes.size>=4 && (
        bytes.take(4)==listOf(0x76.toByte(),0x2f.toByte(),0x31.toByte(),1.toByte()) ||
        String(bytes,Charsets.ISO_8859_1).let { it.startsWith("#?RADIANCE") || it.startsWith("#?RGBE") })
    fun isHdr(file: File): Boolean = file.inputStream().use { input ->
        val header=ByteArray(12); val n=input.read(header); n>=4 && hdrHeader(header.copyOf(n))
    }
    fun isNative(file: File): Boolean = isTiff(file) || isHdr(file)
    fun tiffHeader(bytes: ByteArray): Boolean = bytes.size >= 4 && (
        (bytes[0] == 73.toByte() && bytes[1] == 73.toByte() && bytes[2] in listOf(42.toByte(), 43.toByte()) && bytes[3] == 0.toByte()) ||
        (bytes[0] == 77.toByte() && bytes[1] == 77.toByte() && bytes[2] == 0.toByte() && bytes[3] in listOf(42.toByte(), 43.toByte())))
    fun isTiff(file: File): Boolean = file.inputStream().use { input ->
        val header = ByteArray(4); input.read(header) == 4 && tiffHeader(header)
    }
    fun bounds(file: File): BitmapFactory.Options {
        val result = BitmapFactory.Options().apply { inJustDecodeBounds = true }
        rawBounds(file)?.let { result.outWidth=it[0]; result.outHeight=it[1]; result.outMimeType="application/x-thru3d-rgba"; return result }
        if (isHdr(file)) {
            val info=HdrPhotoNative.inspect(file.path) ?: error("PHOTO_FORMAT_UNSUPPORTED")
            result.outWidth=info[0]; result.outHeight=info[1]; result.outMimeType=if(info[3]==1) "image/vnd.radiance" else "image/x-exr"
        } else if (isTiff(file)) {
            val info = TiffPhotoNative.inspect(file.path) ?: error("PHOTO_FORMAT_UNSUPPORTED")
            result.outWidth = info[0]; result.outHeight = info[1]; result.outMimeType = "image/tiff"
        } else BitmapFactory.decodeFile(file.path, result)
        return result
    }
    fun orientation(file: File): Int = if(isHdr(file)) 1 else if (isTiff(file)) TiffPhotoNative.inspect(file.path)?.get(2) ?: 1
        else runCatching { PhotoHeader.normalizedOrientation(ExifInterface(file.path).getAttributeInt(ExifInterface.TAG_ORIENTATION, 1)) }.getOrDefault(1)
    fun rawBounds(file: File): IntArray? {
        if (file.extension != "t3di") return null
        return RandomAccessFile(file, "r").use { input ->
            val header = ByteArray(16); input.readFully(header)
            require(String(header, 0, 4, Charsets.US_ASCII)=="T3DI")
            val words = ByteBuffer.wrap(header).order(ByteOrder.LITTLE_ENDIAN)
            val w=words.getInt(4); val h=words.getInt(8)
            require(words.getInt(12)==1 && w in 1..65535 && h in 1..65535 && w.toLong()*h<=1_000_000_000L && input.length()==16+w.toLong()*h*4)
            intArrayOf(w,h)
        }
    }
    private fun rawPixels(file: File, size: IntArray, left: Int, top: Int, width: Int, height: Int, sample: Int, check: () -> Unit): ByteArray {
        require(sample in 1..65535 && left>=0 && top>=0 && width>0 && height>0 && left.toLong()+width<=size[0] && top.toLong()+height<=size[1])
        val ow=(width+sample-1)/sample; val oh=(height+sample-1)/sample
        require(ow.toLong()*oh<=8*1024*1024)
        val output=ByteArray(ow*oh*4); val row=ByteArray(width*4)
        RandomAccessFile(file,"r").use { input ->
            for (y in 0 until height step sample) {
                check(); input.seek(16L+(top+y).toLong()*size[0]*4+left.toLong()*4); input.readFully(row)
                for (x in 0 until width step sample) row.copyInto(output,((y/sample)*ow+x/sample)*4,x*4,x*4+4)
            }
        }
        return output
    }
    fun region(file: File, left: Int, top: Int, width: Int, height: Int, sample: Int = 1, check: () -> Unit = {}, cache: File? = null): Bitmap {
        check()
        val raw=rawBounds(file)
        val bytes = if (raw!=null) rawPixels(file,raw,left,top,width,height,sample,check)
            else if(isHdr(file)) HdrPhotoNative.pixels(file.path,left,top,width,height,sample,Runnable { check() },cache?.path) ?: error("PHOTO_DECODE_FAILED")
            else TiffPhotoNative.pixels(file.path, left, top, width, height, sample, Runnable { check() }, cache?.path) ?: error("PHOTO_DECODE_FAILED")
        check()
        val image = Bitmap.createBitmap((width + sample - 1) / sample, (height + sample - 1) / sample, Bitmap.Config.ARGB_8888)
        try { image.copyPixelsFromBuffer(ByteBuffer.wrap(bytes)); return image }
        catch (error: Throwable) { image.recycle(); throw error }
    }
    fun decode(file: File, options: BitmapFactory.Options, check: () -> Unit = {}): Bitmap? {
        if (!isNative(file)) return BitmapFactory.decodeFile(file.path, options)
        val info = bounds(file)
        var sample = maxOf(1, options.inSampleSize)
        while (((info.outWidth + sample - 1) / sample).toLong() * ((info.outHeight + sample - 1) / sample) > 8 * 1024 * 1024) sample *= 2
        return region(file, 0, 0, info.outWidth, info.outHeight, sample, check)
    }
}

internal object NativePhoto {
    fun prepare(source: File, directory: File, check: () -> Unit, publish: (JSONObject) -> Unit): JSONObject {
        val info = PhotoBitmap.bounds(source)
        val orientation = PhotoBitmap.orientation(source)
        val floating=PhotoBitmap.isHdr(source)
        val needsCache = (floating || TiffPhotoNative.inspect(source.path)?.get(3)==1) && orientation==1 && info.outWidth>=8192 && info.outWidth==2*info.outHeight
        val cache = if (needsCache) File(directory,"regions.t3di.part") else null
        if (cache!=null) require(directory.usableSpace>info.outWidth.toLong()*info.outHeight*4+64L*1024*1024) { "PHOTO_TOO_LARGE" }
        val metadata = JSONObject().put("state", "metadata").put("width", info.outWidth).put("height", info.outHeight)
            .put("orientation", orientation).put("panorama", false).put("mime", info.outMimeType)
        if(floating) metadata.put("tone_mapping","global-logmean-aces-srgb-v1")
        check(); publish(JSONObject(metadata.toString()))
        var sample = 1
        while ((info.outWidth + sample - 1) / sample > 8192 || (info.outHeight + sample - 1) / sample > 8192 ||
            ((info.outWidth + sample - 1) / sample).toLong() * ((info.outHeight + sample - 1) / sample) > 8 * 1024 * 1024) sample *= 2
        val image = PhotoBitmap.region(source, 0, 0, info.outWidth, info.outHeight, sample, check, cache)
        try {
            val preview = File(directory, "preview.png")
            preview.outputStream().use { require(image.compress(Bitmap.CompressFormat.PNG, 100, it)) }
            val scale = minOf(1.0, 384.0 / maxOf(image.width, image.height))
            val thumbnail = Bitmap.createScaledBitmap(image, maxOf(1, (image.width * scale).toInt()), maxOf(1, (image.height * scale).toInt()), true)
            try {
                val file = File(directory, "thumbnail.jpg")
                file.outputStream().use { require(thumbnail.compress(Bitmap.CompressFormat.JPEG, 85, it)) }
                metadata.put("thumbnail_path", file.path)
            } finally { if (thumbnail !== image) thumbnail.recycle() }
            if (orientation == 1 && info.outWidth >= 8192 && info.outWidth == 2 * info.outHeight) {
                if (cache!=null) {
                    val ready=File(directory,"regions.t3di"); require(cache.renameTo(ready))
                    require(PhotoBitmap.rawBounds(ready)?.contentEquals(intArrayOf(info.outWidth,info.outHeight))==true)
                    metadata.put("region_source",ready.path)
                } else metadata.put("region_source", source.path)
            }
            check()
            return metadata.put("state", "ready").put("path", preview.path).put("sample", sample)
        } finally { image.recycle() }
    }
}
