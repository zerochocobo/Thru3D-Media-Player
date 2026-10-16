package org.vrpassthroughplayer.plugin

import android.graphics.Bitmap
import android.graphics.ColorSpace
import android.graphics.ImageDecoder
import android.graphics.PixelFormat
import org.json.JSONObject
import java.io.File
import kotlin.math.roundToInt
import kotlin.math.sqrt

/** Android 28+ primary-image decoding, including grid tiles, orientation and color conversion.
 * A private HEIF copy selects the explicit ster eye IDs, avoiding index-order assumptions. */
internal object HeifPhotoDecoder {
    private const val MAX_PIXELS = 16 * 1024 * 1024
    private const val MAX_EDGE = 8192

    /** High-bit-depth HEIF otherwise selects F16, which older Android HEIF codecs reject.
     * LOW_RAM plus a pixel-preserving postprocessor requests N32 instead of RGB565.
     * This is the same 8-bit sRGB precision used by our raw photo surface. */
    fun configure8Bit(decoder: ImageDecoder) {
        decoder.allocator = ImageDecoder.ALLOCATOR_SOFTWARE
        decoder.memorySizePolicy = ImageDecoder.MEMORY_POLICY_LOW_RAM
        decoder.setPostProcessor { PixelFormat.UNKNOWN }
        decoder.setTargetColorSpace(ColorSpace.get(ColorSpace.Named.SRGB))
    }

    fun prepare(source: File, directory: File, info: HeifPhotoInfo,
                checkCurrent: () -> Unit, metadataReady: (JSONObject) -> Unit): JSONObject {
        val metadata = JSONObject().put("state", "metadata").put("width", info.packedWidth).put("height", info.height)
            .put("orientation", 1).put("panorama", false).put("native_stereo", info.stereo)
            .put("heif", true).put("left_item", info.left).put("right_item", info.right ?: 0)
            .put("spatial_disparity", info.disparity)
        if (info.stereo && info.horizontalFovDegrees != null)
            metadata.put("spatial_metadata", JSONObject().put("horizontal_fov_degrees", info.horizontalFovDegrees))
        checkCurrent(); metadataReady(JSONObject(metadata.toString()))
        val working = File(directory, "decode-view.heic")
        var left: Bitmap? = null; var right: Bitmap? = null
        try {
            source.inputStream().use { input -> working.outputStream().use { output ->
                val buffer = ByteArray(65536)
                while (true) {
                    checkCurrent(); val n = input.read(buffer); if (n < 0) break
                    output.write(buffer, 0, n)
                }
            } }
            val eyes = if (info.stereo) 2 else 1
            val scale = minOf(1.0, MAX_EDGE.toDouble() / info.packedWidth, MAX_EDGE.toDouble() / info.height,
                sqrt(MAX_PIXELS.toDouble() / info.width / info.height / eyes))
            val width = maxOf(1, (info.width * scale).toInt())
            val height = maxOf(1, (info.height * scale).toInt())
            fun decode(item: Int): Bitmap {
                checkCurrent(); info.selectPrimary(working, item)
                val image = ImageDecoder.decodeBitmap(ImageDecoder.createSource(working)) { decoder, imageInfo, _ ->
                    require(imageInfo.size.width in 1..32768 && imageInfo.size.height in 1..32768) { "PHOTO_TOO_LARGE" }
                    configure8Bit(decoder)
                    decoder.setTargetSize(width, height)
                }
                try { checkCurrent() } catch (error: Throwable) { image.recycle(); throw error }
                return if (image.config == Bitmap.Config.ARGB_8888) image else {
                    try { image.copy(Bitmap.Config.ARGB_8888, false) ?: error("PHOTO_DECODE_FAILED") }
                    finally { image.recycle() }
                }
            }
            left = decode(info.left)
            if (info.right != null) right = decode(info.right)
            require(left.width == width && left.height == height &&
                (right == null || (right.width == width && right.height == height))) { "PHOTO_DECODE_FAILED" }
            val packed = File(directory, if (info.stereo) "native-stereo.rgba" else "heif-mono.rgba")
            val row = IntArray(width); val bytes = ByteArray(width * eyes * 4)
            // Raw rows avoid several seconds of PNG compression on large photos.
            packed.outputStream().use { output ->
                for (y in 0 until height) {
                    checkCurrent()
                    for (eye in 0 until eyes) {
                        val bitmap = if (eye == 0) left else right!!
                        bitmap.getPixels(row, 0, width, 0, y, width, 1)
                        var at = eye * width * 4
                        for (color in row) {
                            bytes[at++] = (color shr 16).toByte(); bytes[at++] = (color shr 8).toByte()
                            bytes[at++] = color.toByte(); bytes[at++] = (color ushr 24).toByte()
                        }
                    }
                    output.write(bytes)
                }
            }
            val ratio = minOf(1.0, 384.0 / maxOf(width, height))
            val thumbnail = Bitmap.createScaledBitmap(left, maxOf(1, (width * ratio).roundToInt()),
                maxOf(1, (height * ratio).roundToInt()), true)
            try {
                val path = File(directory, "thumbnail.jpg")
                path.outputStream().use { require(thumbnail.compress(Bitmap.CompressFormat.JPEG, 85, it)) { "PHOTO_DECODE_FAILED" } }
                metadata.put("thumbnail_path", path.path)
            } finally { if (thumbnail !== left) thumbnail.recycle() }
            checkCurrent()
            return metadata.put("state", "ready").put("path", packed.path).put("raw_rgba", true)
                .put("decoded_width", width * eyes).put("decoded_height", height).put("sample", 1.0 / scale)
        } finally {
            left?.recycle(); right?.recycle(); working.delete()
        }
    }
}
