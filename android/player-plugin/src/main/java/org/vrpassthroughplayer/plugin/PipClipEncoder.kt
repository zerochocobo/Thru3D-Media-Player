package org.vrpassthroughplayer.plugin

import android.graphics.Bitmap
import android.graphics.BitmapFactory
import android.media.MediaCodec
import android.media.MediaCodecInfo
import android.media.MediaCodecList
import android.media.MediaFormat
import android.media.MediaMuxer
import org.json.JSONObject
import java.io.File
import java.nio.ByteBuffer
import java.util.function.BooleanSupplier

internal object PipClipNative {
    @JvmStatic external fun open(path: String): Long
    @JvmStatic external fun size(handle: Long): IntArray
    @JvmStatic external fun next(handle: Long, target: Bitmap, cancelled: BooleanSupplier): Long
    @JvmStatic external fun close(handle: Long)
    @JvmStatic external fun render(source: Bitmap, images: Array<Bitmap>, mode: IntArray, windows: FloatArray,
        planes: Array<ByteBuffer>, rows: IntArray, strides: IntArray, cancelled: BooleanSupplier): Boolean
    @JvmStatic external fun mux(video: String, source: String, output: String, mode: String, cancelled: BooleanSupplier): Boolean
}

/** Offline composition on the clip worker; the playback decoder and render thread are untouched. */
internal object PipClipEncoder {
    fun encode(source: File, encoded: File, output: String, baseUs: Long, mode: JSONObject,
               timeline: PipClipTimeline, durationUs: Long, cancelled: BooleanSupplier,
               progress: (Int) -> Unit): JSONObject {
        check(!cancelled.asBoolean) { "Clip export cancelled" }
        val handle = PipClipNative.open(source.path)
        check(handle != 0L) { "Picture in picture recording unavailable" }
        var codec: MediaCodec? = null; var muxer: MediaMuxer? = null; var bitmap: Bitmap? = null
        val images = linkedMapOf<Int, Bitmap>()
        var started = false
        try {
            val dimensions = PipClipNative.size(handle)
            val plan = choose(dimensions[0], dimensions[1])
            val format = MediaFormat.createVideoFormat("video/avc", plan.width, plan.height).apply {
                setInteger(MediaFormat.KEY_COLOR_FORMAT, MediaCodecInfo.CodecCapabilities.COLOR_FormatYUV420Flexible)
                setInteger(MediaFormat.KEY_BIT_RATE, plan.bitrate)
                setInteger(MediaFormat.KEY_FRAME_RATE, 30); setInteger(MediaFormat.KEY_I_FRAME_INTERVAL, 1)
                setInteger(MediaFormat.KEY_COLOR_STANDARD, MediaFormat.COLOR_STANDARD_BT709)
                setInteger(MediaFormat.KEY_COLOR_RANGE, MediaFormat.COLOR_RANGE_LIMITED)
                setInteger(MediaFormat.KEY_COLOR_TRANSFER, MediaFormat.COLOR_TRANSFER_SDR_VIDEO)
                setInteger(MediaFormat.KEY_MAX_B_FRAMES, 0)
            }
            val encoder = MediaCodec.createByCodecName(plan.codec); codec = encoder
            encoder.configure(format, null, null, MediaCodec.CONFIGURE_FLAG_ENCODE); encoder.start()
            val writer = MediaMuxer(encoded.path, MediaMuxer.OutputFormat.MUXER_OUTPUT_MPEG_4); muxer = writer
            val pixels = Bitmap.createBitmap(plan.width, plan.height, Bitmap.Config.ARGB_8888); bitmap = pixels
            val flags = intArrayOf(mode.getInt("geometry"), if(mode.optBoolean("stereo_sbs"))1 else 0,
                if(mode.optBoolean("top_bottom"))1 else 0, if(mode.optBoolean("stereo_half"))1 else 0,
                if(mode.optBoolean("swap_eyes"))1 else 0, mode.getInt("fisheye_fov"))
            val info = MediaCodec.BufferInfo(); var track = -1; var inputEnd = false; var outputEnd = false
            var count = 0; var lastProgress = System.nanoTime()
            while (!outputEnd) {
                check(!cancelled.asBoolean) { "Clip export cancelled" }
                check(System.nanoTime() - lastProgress < 30_000_000_000L) { "Picture in picture recording unavailable" }
                if (!inputEnd) {
                    val index = encoder.dequeueInputBuffer(10_000)
                    if (index >= 0) {
                        val pts = PipClipNative.next(handle, pixels, cancelled)
                        check(pts >= -1) { if(pts == -3L) "HDR picture in picture recording unavailable" else "Picture in picture recording unavailable" }
                        if (pts == -1L) {
                            encoder.queueInputBuffer(index, 0, 0, 0, MediaCodec.BUFFER_FLAG_END_OF_STREAM); inputEnd = true
                        } else {
                            val recipe = timeline.at(baseUs + pts)
                            val previews = recipe.previews()
                            // At most three displayed previews resident, regardless of page turns during recording.
                            val needed = previews.map { it.first }.toSet()
                            images.keys.filter { it !in needed }.forEach { images.remove(it)?.recycle() }
                            val frames = previews.map { (id, file) -> images.getOrPut(id) {
                                val bounds = BitmapFactory.Options().apply { inJustDecodeBounds = true }
                                BitmapFactory.decodeFile(file.path, bounds)
                                check(bounds.outWidth in 1..2048 && bounds.outHeight in 1..2048)
                                BitmapFactory.decodeFile(file.path, BitmapFactory.Options().apply {
                                    inPreferredConfig = Bitmap.Config.ARGB_8888; inScaled = false
                                }) ?: error("Picture in picture capture unavailable")
                            } }.toTypedArray()
                            val image = encoder.getInputImage(index) ?: error("Picture in picture recording unavailable")
                            image.use {
                                check(image.width == plan.width && image.height == plan.height &&
                                    image.cropRect.left == 0 && image.cropRect.top == 0 && image.planes.size == 3) { "Picture in picture recording unavailable" }
                                check(PipClipNative.render(pixels, frames, flags, recipe.packed(),
                                    image.planes.map { it.buffer.slice() }.toTypedArray(), image.planes.map { it.rowStride }.toIntArray(),
                                    image.planes.map { it.pixelStride }.toIntArray(), cancelled)) { "Picture in picture recording unavailable" }
                            }
                            encoder.queueInputBuffer(index, 0, plan.width * plan.height * 3 / 2, pts, 0)
                            count++
                        }
                        lastProgress = System.nanoTime()
                    }
                }
                val index = encoder.dequeueOutputBuffer(info, 10_000)
                if (index == MediaCodec.INFO_OUTPUT_FORMAT_CHANGED) {
                    check(!started); track = writer.addTrack(encoder.outputFormat); writer.start(); started = true
                } else if (index >= 0) {
                    try {
                        if (info.size > 0 && info.flags and MediaCodec.BUFFER_FLAG_CODEC_CONFIG == 0) {
                            check(started); writer.writeSampleData(track, encoder.getOutputBuffer(index)!!, info)
                            progress((info.presentationTimeUs.coerceAtLeast(0) * 98 / durationUs.coerceAtLeast(1)).coerceIn(0, 98).toInt())
                        }
                        outputEnd = info.flags and MediaCodec.BUFFER_FLAG_END_OF_STREAM != 0
                    } finally { encoder.releaseOutputBuffer(index, false) }
                    lastProgress = System.nanoTime()
                }
            }
            check(count >= 2) { "Recording is too short" }
            writer.stop(); started = false; writer.release(); muxer = null
            encoder.stop(); encoder.release(); codec = null
            check(!cancelled.asBoolean) { "Clip export cancelled" }
            progress(99)
            check(PipClipNative.mux(encoded.path, source.path, output, mode.toString(), cancelled)) { "Capture save failed" }
            return JSONObject().put("state", "saved").put("extension", "mkv").put("pip_composed", true)
                .put("width", plan.width).put("height", plan.height).put("max_fps", 30).put("video_frames", count)
        } finally {
            runCatching { codec?.stop() }; runCatching { codec?.release() }
            if (started) runCatching { muxer?.stop() }; runCatching { muxer?.release() }
            bitmap?.recycle(); images.values.forEach { it.recycle() }; PipClipNative.close(handle)
        }
    }
    data class Plan(val codec: String, val width: Int, val height: Int, val bitrate: Int)
    private fun choose(width: Int, height: Int): Plan {
        for (limit in listOf(3840, 2560, 1920)) {
            for (codec in MediaCodecList(MediaCodecList.REGULAR_CODECS).codecInfos) {
                if (!codec.isEncoder || !codec.isHardwareAccelerated || !codec.supportedTypes.contains("video/avc")) continue
                val caps = codec.getCapabilitiesForType("video/avc")
                if (!caps.colorFormats.contains(MediaCodecInfo.CodecCapabilities.COLOR_FormatYUV420Flexible)) continue
                val video = caps.videoCapabilities ?: continue
                val scale = minOf(1.0, limit.toDouble() / maxOf(width, height))
                // Four-pixel packing keeps both eyes chroma-aligned for SBS and TB sources.
                val wa = lcm4(video.widthAlignment); val ha = lcm4(video.heightAlignment)
                val w = (width * scale).toInt() / wa * wa; val h = (height * scale).toInt() / ha * ha
                if (w < 4 || h < 4 || !video.areSizeAndRateSupported(w, h, 30.0)) continue
                val bitrate = video.bitrateRange.clamp((w.toLong() * h * 5).coerceIn(4_000_000, 60_000_000).toInt())
                return Plan(codec.name, w, h, bitrate)
            }
        }
        error("Picture in picture recording unavailable")
    }
    private fun lcm4(alignment: Int): Int = if(alignment % 4 == 0) alignment else alignment * (if(alignment % 2 == 0) 2 else 4)
}
