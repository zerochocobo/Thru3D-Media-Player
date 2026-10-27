package org.vrpassthroughplayer.plugin

import android.content.Context
import android.graphics.Bitmap
import android.graphics.BitmapFactory
import android.graphics.Canvas
import android.graphics.Paint
import android.graphics.Rect
import android.media.ExifInterface
import org.json.JSONObject
import java.io.File
import java.nio.ByteBuffer
import java.nio.ByteOrder
import kotlin.math.roundToInt

/** A fresh still-image RVM state; the resulting matte uses the exact existing colour warp. */
internal object PhotoPortrait {
    const val EDGE = 512
    fun alphaByte(value: Float): Int {
        require(value.isFinite() && value in 0f..1f)
        return (value * 255).roundToInt().coerceIn(0,255)
    }

    fun prepare(context: Context, source: File, strength: Float, token: Int, check: () -> Unit): JSONObject {
        val nearFile = File(source.parentFile,"depth.bin")
        val depth = JSONObject(File(source.parentFile,"depth.json").readText())
        require(depth.optString("photo_cache") == "da2-518-stretch-v2" && nearFile.length() == 518L*518*4)
        val directory = File(source.parentFile,"portrait").apply { mkdirs() }
        val sourceMask = File(directory,"mask.png")
        if (!sourceMask.isFile) {
            check()
            val rgb = PhotoDepthInput.prepare(source,EDGE,EDGE).rgb
            val alpha = ByteBuffer.allocateDirect(EDGE*EDGE*4).order(ByteOrder.LITTLE_ENDIAN)
            val other = ByteBuffer.allocateDirect(EDGE*EDGE*4).order(ByteOrder.LITTLE_ENDIAN)
            val secondRgb = ByteBuffer.allocateDirect(rgb.capacity()).order(ByteOrder.LITTLE_ENDIAN)
            secondRgb.put(rgb.duplicate()); secondRgb.rewind()
            RvmNative.configureGpu(RvmWarmup.cacheDirectory(context).absolutePath,RvmNative.fp16())
            val runtime = ModelPreparationGate.run {
                check(); RvmRuntime.prepare(context.assets,true,"512x512",token.toLong(),1)
            }
            runtime.use {
                check()
                val report = it.process(1,0,0,rgb,secondRgb,alpha,other,0,true)
                require(report.optString("state") == "ready")
            }
            check()
            alpha.rewind()
            var foreground = 0
            val pixels = IntArray(EDGE*EDGE) {
                val byte = alphaByte(alpha.float)
                if (byte > 89) foreground++
                (0xff000000.toInt() or (byte shl 16) or (byte shl 8) or byte)
            }
            require(foreground >= 26) { "PHOTO_NO_PERSON" }
            val small = Bitmap.createBitmap(pixels,EDGE,EDGE,Bitmap.Config.ARGB_8888)
            val bounds = PhotoBitmap.bounds(source)
            val orientation = PhotoBitmap.orientation(source)
            val (w,h) = if (orientation in 5..8) PhotoStereo.size(bounds.outHeight,bounds.outWidth) else PhotoStereo.size(bounds.outWidth,bounds.outHeight)
            val full = Bitmap.createBitmap(w,h,Bitmap.Config.ARGB_8888)
            try {
                Canvas(full).drawBitmap(small,null,Rect(0,0,w,h),Paint(Paint.FILTER_BITMAP_FLAG))
                val temporary = File(directory,"mask-$token.tmp")
                try {
                    temporary.outputStream().use { require(full.compress(Bitmap.CompressFormat.PNG,100,it)) }
                    check(); require(temporary.renameTo(sourceMask))
                } finally { temporary.delete() }
            } finally { full.recycle(); small.recycle() }
        }
        check()
        val maskBounds = BitmapFactory.Options().apply { inJustDecodeBounds = true }
        BitmapFactory.decodeFile(sourceMask.path,maskBounds)
        val (eyeWidth,h) = PhotoStereo.size(maskBounds.outWidth,maskBounds.outHeight)
        val w = eyeWidth*2
        val target = File(directory,"matte-${(strength*100).roundToInt()}-${w}x$h.r8")
        // Repeated slider values reuse the per-eye matte, not another GPU colour warp.
        if (target.length() == w.toLong()*h) return metadata(target,w,h)
        val near = ByteBuffer.allocateDirect(518*518*4).order(ByteOrder.LITTLE_ENDIAN)
        near.put(nearFile.readBytes()); near.rewind()
        val rect = depth.getJSONArray("rect")
        // Same oriented dimensions, gradient limits, convergence and disocclusion as colour.
        val pair = PhotoStereo.prepare(sourceMask,near,FloatArray(4) { rect.getDouble(it).toFloat() },strength,token)
        require(pair.getInt("stereo_width") == w && pair.getInt("stereo_height") == h)
        val raw = File(pair.getString("stereo_path"))
        if (target.length() != w.toLong()*h) {
            val pixels = raw.readBytes(); require(pixels.size == w*h*4)
            val red = ByteArray(w*h) { pixels[it*4] }
            check(); target.writeBytes(red)
        }
        raw.delete() // Godot retains only one byte per mask texel; no second full RGBA pair.
        check()
        retainRecentMattes(directory,target)
        return metadata(target,w,h)
    }

    internal fun retainRecentMattes(directory: File, current: File) {
        // A 0..200% drag must not accumulate 201 full-resolution mattes on disk.
        directory.listFiles()?.filter { it.name.startsWith("matte-") && it.extension == "r8" && it != current }
            ?.sortedByDescending { it.lastModified() }?.drop(2)?.forEach { it.delete() }
    }

    private fun metadata(file: File, width: Int, height: Int) = JSONObject()
        .put("path",file.path).put("width",width).put("height",height)
        .put("format","r8_sbs").put("strategy","video_soft_shift_gpu")
}
