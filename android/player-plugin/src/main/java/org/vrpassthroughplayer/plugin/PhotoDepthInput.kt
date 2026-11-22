package org.vrpassthroughplayer.plugin

import android.content.Context
import android.graphics.Bitmap
import android.graphics.BitmapFactory
import android.graphics.Canvas
import android.graphics.Color
import android.graphics.ImageDecoder
import android.graphics.Matrix
import android.graphics.Paint
import android.graphics.Rect
import android.media.ExifInterface
import java.io.File
import java.nio.ByteBuffer
import java.nio.ByteOrder

/** One orientation-preserving photo input; the full-resolution color is decoded separately. */
internal object PhotoDepthInput {
    const val WIDTH = 518
    const val HEIGHT = 518
    data class Content(val x: Int, val y: Int, val width: Int, val height: Int)
    data class Input(val rgb: ByteBuffer, val content: Content, val steps: String = "")

    // Video warmup removes obsolete files in its own directory. Keep photo programs separate.
    fun cacheDirectory(context: Context) = File(context.cacheDir, "photo-depth-mnn").apply { mkdirs() }

    // Stretch the whole photo over the model input. Letterbox bars join the ViT's global attention
    // and skew the content's depth (worst 0.29 vs 0.07 on 40 portraits, 0.087 vs 0.042 on Quest);
    // the depth map is stretched back over the photo through the full content rect.
    fun fit(width: Int, height: Int): Content {
        require(width > 0 && height > 0)
        return Content(0, 0, WIDTH, HEIGHT)
    }

    fun prepare(source: File, width: Int = WIDTH, height: Int = HEIGHT, selectLeftEye: Boolean = false): Input =
        prepareRegions(source, width, height, selectLeftEye).single()

    /** One decode, one input per horizontal [regions] share of the upright photo (a spread's pages),
     * each stretched over the whole model input. */
    fun prepareRegions(source: File, width: Int = WIDTH, height: Int = HEIGHT, selectLeftEye: Boolean = false,
                       regions: List<ClosedFloatingPointRange<Float>> = listOf(0f..1f)): List<Input> {
        require(width in 1..WIDTH && height in 1..HEIGHT && regions.isNotEmpty() && regions.all { it.start >= 0f && it.endInclusive <= 1f && it.start < it.endInclusive })
        require(!selectLeftEye || regions.size == 1)
        if (selectLeftEye) {
            val info = HeifPhotoInfo.read(source) ?: error("PHOTO_DECODE_FAILED")
            val copy = File(source.parentFile,"scene-depth-left.heic")
            try {
                source.copyTo(copy,overwrite=true)
                info.selectPrimary(copy,info.left)
                val bitmap = ImageDecoder.decodeBitmap(ImageDecoder.createSource(copy)) { decoder, _, _ ->
                    HeifPhotoDecoder.configure8Bit(decoder)
                    decoder.setTargetSize(width,height)
                }
                try { return listOf(encodeInput(bitmap,width,height)) } finally { bitmap.recycle() }
            } finally { copy.delete() }
        }
        val clock = PhotoStereo.StepClock()
        val bounds = PhotoBitmap.bounds(source)
        require(bounds.outWidth > 0 && bounds.outHeight > 0) { "PHOTO_DECODE_FAILED" }
        // Retain at least 518 pixels on the longest edge before the final filtered resize.
        var sample = 1
        while (maxOf(bounds.outWidth, bounds.outHeight) / (sample * 2) >= maxOf(width, height)) sample *= 2
        clock.lap("bounds")
        val original = PhotoBitmap.decode(source, BitmapFactory.Options().apply { inSampleSize = sample }) ?: error("PHOTO_DECODE_FAILED")
        clock.lap("decode")
        var upright = original
        try {
            val orientation = PhotoBitmap.orientation(source)
            val matrix = Matrix().apply { when (orientation) {
                2 -> setScale(-1f, 1f); 3 -> setRotate(180f); 4 -> setScale(1f, -1f)
                5 -> { setRotate(90f); postScale(-1f, 1f) }; 6 -> setRotate(90f)
                7 -> { setRotate(90f); postScale(1f, -1f) }; 8 -> setRotate(270f)
            } }
            upright = Bitmap.createBitmap(original, 0, 0, original.width, original.height, matrix, true)
            clock.lap("orient")
            val content = Content(0, 0, width, height)
            val inputs = regions.map { region ->
                val input = Bitmap.createBitmap(width, height, Bitmap.Config.ARGB_8888)
                try {
                    val from = (region.start * upright.width).toInt().coerceIn(0, upright.width - 1)
                    val to = (region.endInclusive * upright.width).toInt().coerceIn(from + 1, upright.width)
                    Canvas(input).apply {
                        drawColor(Color.BLACK)
                        drawBitmap(upright, Rect(from, 0, to, upright.height), Rect(content.x, content.y, content.x + content.width, content.y + content.height), Paint(Paint.FILTER_BITMAP_FLAG))
                    }
                    clock.lap("resize")
                    encodeInput(input,width,height).also { clock.lap("float") }
                } finally { input.recycle() }
            }
            return inputs.map { it.copy(steps = "$clock decoded=${original.width}x${original.height} sample=$sample") }
        } finally { if (upright !== original) upright.recycle(); original.recycle() }
    }

    /** Bilinear float32 map resize by pixel centres. The fast model's 512x512 map becomes the 518x518
     * map every consumer (stereo warp, portrait, kept maps, Godot) reads. */
    fun resample(source: ByteBuffer, width: Int, height: Int, targetWidth: Int = WIDTH, targetHeight: Int = HEIGHT): ByteBuffer {
        require(width > 0 && height > 0 && targetWidth > 0 && targetHeight > 0 && source.remaining() >= width * height * 4)
        val input = source.duplicate().order(ByteOrder.LITTLE_ENDIAN).asFloatBuffer()
        val values = FloatArray(width * height).also { input.get(it) }
        val output = ByteBuffer.allocateDirect(targetWidth * targetHeight * 4).order(ByteOrder.LITTLE_ENDIAN)
        for (y in 0 until targetHeight) {
            val fy = ((y + 0.5f) * height / targetHeight - 0.5f).coerceIn(0f, height - 1f)
            val y0 = fy.toInt(); val y1 = minOf(y0 + 1, height - 1); val wy = fy - y0
            for (x in 0 until targetWidth) {
                val fx = ((x + 0.5f) * width / targetWidth - 0.5f).coerceIn(0f, width - 1f)
                val x0 = fx.toInt(); val x1 = minOf(x0 + 1, width - 1); val wx = fx - x0
                val top = values[y0 * width + x0] * (1 - wx) + values[y0 * width + x1] * wx
                val bottom = values[y1 * width + x0] * (1 - wx) + values[y1 * width + x1] * wx
                output.putFloat(top * (1 - wy) + bottom * wy)
            }
        }
        output.rewind()
        return output
    }

    private fun encodeInput(bitmap: Bitmap, width: Int, height: Int): Input {
        val pixels = IntArray(width * height)
        bitmap.getPixels(pixels,0,width,0,0,width,height)
        val rgb = ByteBuffer.allocateDirect(width * height * 12).order(ByteOrder.LITTLE_ENDIAN)
        for (shift in listOf(16,8,0)) for (pixel in pixels) rgb.putFloat(((pixel shr shift) and 255)/255f)
        rgb.rewind()
        return Input(rgb,Content(0,0,width,height))
    }
}
