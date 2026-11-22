package org.vrpassthroughplayer.plugin

import android.graphics.Bitmap
import android.graphics.BitmapFactory
import android.graphics.Matrix
import android.media.ExifInterface
import org.json.JSONObject
import java.io.File
import java.nio.ByteBuffer
import java.nio.ByteOrder
import kotlin.math.roundToInt
import kotlin.math.sqrt

/** A still is warped once on the depth worker, then displayed/cached as an ordinary SBS texture. */
internal object PhotoStereo {
    const val MAX_EDGE = 4096 // The shared z-buffer's source column occupies 12 bits.
    const val MAX_PIXELS = 8 * 1024 * 1024
    // Each eye's default size, as video's pair (2560 wide): ~4 MP. 8 MP eyes cost 3x the time
    // (2.9 vs 1.85 s to the first 3D on Quest 3) for detail a headset screen of the photo cannot show;
    // the magnifier still reads the original.
    const val EYE_EDGE = 2560
    const val EYE_PIXELS = 4 * 1024 * 1024

    /** One eye of the pair; every caller (stereo, portrait matte, budget) must agree on it. */
    fun size(width: Int, height: Int): Pair<Int, Int> {
        require(width > 0 && height > 0)
        val (edge, pixels) = eyeCap()
        val ratio = minOf(1.0, edge.toDouble()/maxOf(width,height), sqrt(pixels.toDouble()/width/height))
        return maxOf(1,(width*ratio).toInt()) to maxOf(1,(height*ratio).toInt())
    }

    /** `setprop debug.vrpp.photo.stereo_mp N` (1-8): eye size cap in megapixels for timing/quality A/B. */
    private fun eyeCap(): Pair<Int, Int> = runCatching {
        Class.forName("android.os.SystemProperties").getMethod("getInt", String::class.java, Int::class.javaPrimitiveType)
            .invoke(null, "debug.vrpp.photo.stereo_mp", 0) as Int
    }.getOrDefault(0).let { if (it in 1..8) MAX_EDGE to it * 1024 * 1024 else EYE_EDGE to EYE_PIXELS }

    fun validRotation(rotation: Int) = rotation in listOf(0, 90, 180, 270)
    /** The picture setting: edge stretching (as video's stretch view) instead of the default hole fill. */
    @Volatile var stretch = false
    /** [fast]: a pair warped from the fast model's map, which a later quality map replaces.
     * [stretch]: edge stretching instead of the hole fill. */
    fun cachePrefix(strength: Float, rotation: Int, convergence: Float = 0.35f, fast: Boolean = false, stretch: Boolean = false, pages: Boolean = false): String {
        require(strength.isFinite() && strength in 0f..2f)
        require(validRotation(rotation))
        require(convergence.isFinite() && convergence in 0f..1f)
        return "stereo-v6${if (fast) "f" else ""}${if (stretch) "s" else ""}${if (pages) "p" else ""}-r$rotation-${(strength*100).roundToInt()}-c${(convergence*10000).roundToInt()}-"
    }

    /** The last still's eye-sized colour: the quality refinement, strength and fill changes of the same
     * photo warp it again without decoding the file again (0.3-0.7 s on Quest 3). */
    private class Colour(val key: String, val rgba: ByteBuffer, val width: Int, val height: Int, val steps: String)
    private var colour: Colour? = null
    @Synchronized fun releaseColour() { colour = null }

    @Synchronized private fun colourOf(source: File, clock: StepClock, keep: Boolean): Colour {
        val key = "${source.path}|${source.length()}|${source.lastModified()}|${eyeCap()}"
        colour?.takeIf { it.key == key }?.let { clock.lap("colour_kept"); return it }
        colour = null // never hold two full colours at once
        val bounds = PhotoBitmap.bounds(source)
        val targetSize = size(bounds.outWidth, bounds.outHeight)
        var sample = 1
        while (bounds.outWidth / (sample*2) >= targetSize.first && bounds.outHeight / (sample*2) >= targetSize.second) sample *= 2
        clock.lap("bounds")
        val original = PhotoBitmap.decode(source, BitmapFactory.Options().apply { inSampleSize=sample; inPreferredConfig=Bitmap.Config.ARGB_8888 })
            ?: error("PHOTO_DECODE_FAILED")
        clock.lap("decode")
        var upright = original
        var scaled = original
        try {
            val orientation = PhotoBitmap.orientation(source)
            val matrix = Matrix().apply { when (orientation) {
                2 -> setScale(-1f,1f); 3 -> setRotate(180f); 4 -> setScale(1f,-1f)
                5 -> { setRotate(90f); postScale(-1f,1f) }; 6 -> setRotate(90f)
                7 -> { setRotate(90f); postScale(1f,-1f) }; 8 -> setRotate(270f)
            } }
            upright = Bitmap.createBitmap(original,0,0,original.width,original.height,matrix,true)
            clock.lap("orient")
            val (w,h) = size(upright.width,upright.height)
            scaled = Bitmap.createScaledBitmap(upright,w,h,true)
            clock.lap("scale")
            val rgba = ByteBuffer.allocateDirect(w*h*4).order(ByteOrder.LITTLE_ENDIAN)
            scaled.copyPixelsToBuffer(rgba)
            clock.lap("copy")
            return Colour(key, rgba, w, h, "source=${bounds.outWidth}x${bounds.outHeight} sample=$sample decoded=${original.width}x${original.height}")
                .also { if (keep) colour = it }
        } finally {
            if (scaled !== upright && scaled !== original) scaled.recycle()
            if (upright !== original) upright.recycle()
            original.recycle()
        }
    }

    fun prepare(source: File, near: ByteBuffer, rect: FloatArray, strength: Float, generation: Int, rotation: Int = 0, convergence: Float = 0.35f,
                fast: Boolean = false, stretch: Boolean = false, keepColour: Boolean = true, pages: Float = 0f): JSONObject {
        val prefix = cachePrefix(strength, rotation, convergence, fast, stretch, pages > 0f && rotation == 0)
        // Raw RGBA pair named with its size: a hit is checked by length, with nothing to decode.
        source.parentFile?.listFiles()?.firstOrNull { it.name.startsWith(prefix) && it.extension == "rgba" }?.let { cached ->
            val size = Regex("""-(\d+)x(\d+)$""").find(cached.nameWithoutExtension)?.groupValues
            val w = size?.get(1)?.toIntOrNull() ?: 0; val h = size?.get(2)?.toIntOrNull() ?: 0
            if (w > 0 && h > 0 && cached.length() == w.toLong()*h*4) return metadata(cached, w, h, strength, rotation, convergence, 0, stretch)
        }
        val clock = StepClock()
        val picture = colourOf(source, clock, keepColour)
        val w = picture.width; val h = picture.height
        val rgba = picture.rgba.duplicate().order(ByteOrder.LITTLE_ENDIAN).apply { rewind() }; near.rewind()
        val pair = IntArray(1)
        val paged = pages > 0f && rotation == 0 && w >= 4
        val output: ByteBuffer
        var micros = 0L
        if (paged) {
            // Each page warped on its own region of the spread map, at the spread's parallax; the pages'
            // pairs are joined on the CPU, so no GPU pair is kept for the picture layer.
            val (rects, seam) = PhotoPages.rects(PhotoDepthInput.WIDTH, pages).let { (l, r) ->
                listOf(l, r) to (l[2] * w).roundToInt().coerceIn(1, w - 1) }
            val pairs = listOf(0 to seam, seam to w - seam).mapIndexed { page, (from, columns) ->
                val part = ByteBuffer.allocateDirect(columns*h*8).order(ByteOrder.LITTLE_ENDIAN)
                near.rewind()
                micros += RenderBridgeNative.photoStereo(PhotoPages.crop(rgba,w,h,from,columns),columns,h,near,PhotoDepthInput.WIDTH,PhotoDepthInput.HEIGHT,
                    rects[page],strength,convergence,0,stretch,w,part,IntArray(0)).also { require(it > 0) }
                part
            }
            output = PhotoPages.stitch(pairs[0],seam,pairs[1],w-seam,h)
            pair[0] = 0
        } else {
            output = ByteBuffer.allocateDirect(w*h*8).order(ByteOrder.LITTLE_ENDIAN)
            micros = RenderBridgeNative.photoStereo(rgba,w,h,near,PhotoDepthInput.WIDTH,PhotoDepthInput.HEIGHT,rect,strength,convergence,rotation/90,stretch,0,output,pair)
            require(micros > 0)
        }
        clock.lap("gpu")
        // The GPU pair is already RGBA rows: hand it over raw. PNG encoding a 16.8 MP pair took
        // 4.2-6.4 s on Quest 3 (1.4-1.8 s for 5 MP), most of a large photo's wait.
        val target = File(source.parentFile, "$prefix${w*2}x$h.rgba")
        val temporary = File(source.parentFile,"stereo-$generation.tmp")
        try {
            output.rewind()
            java.io.FileOutputStream(temporary).channel.use { channel -> while (output.hasRemaining()) channel.write(output) }
            require(temporary.renameTo(target))
        } finally { temporary.delete() }
        clock.lap("write")
        // Textures already decoded by Godot own their pixels. Retain the latest few disk pairs.
        source.parentFile?.listFiles()?.filter { it.name.startsWith("stereo-") && it.extension in setOf("png", "rgba") && it != target }
            ?.sortedByDescending { it.lastModified() }?.drop(2)?.forEach { it.delete() }
        clock.lap("prune")
        return metadata(target,w*2,h,strength,rotation,convergence,micros,stretch)
            .apply { if (pair[0] > 0) put("stereo_gpu_pair",pair[0]) } // the picture layer copies this, not the file
            .put("stereo_pages", if (paged) 2 else 1)
            .put("stereo_steps","$clock ${picture.steps} eye=${w}x$h")
    }

    /** Wall-clock laps in ms, for the depth log ("decode=312.4 scale=88.1 ..."). */
    class StepClock {
        private var last = System.nanoTime()
        private val text = StringBuilder()
        fun lap(name: String) {
            val now = System.nanoTime()
            if (text.isNotEmpty()) text.append(' ')
            text.append(name).append('=').append((now - last) / 100_000 / 10.0)
            last = now
        }
        override fun toString() = text.toString()
    }

    private fun metadata(file: File, width: Int, height: Int, strength: Float, rotation: Int, convergence: Float, micros: Long, stretch: Boolean) = JSONObject()
        .put("stereo_path",file.path).put("stereo_width",width).put("stereo_height",height)
        .put("stereo_strength",strength.toDouble()).put("stereo_render_us",micros)
        .put("stereo_rotation",rotation).put("stereo_convergence",convergence.toDouble())
        .put("stereo_strategy","video_soft_shift_gpu").put("stereo_fill", if (stretch) "stretch" else "fill")
}
