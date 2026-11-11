package org.vrpassthroughplayer.plugin

import android.media.MediaCodecInfo
import android.media.MediaCodecList
import android.os.Build
import org.json.JSONObject
import java.util.concurrent.ConcurrentHashMap

/**
 * What this device's hardware decoders advertise for one video. Queried on the running device,
 * never from a chip table, so a newer headset reports its own limits. Advertised, not measured:
 * it explains a failure; it never decides whether playback is attempted.
 */
internal object DecoderCapacity {
    private val mimes = mapOf("h264" to "video/avc", "hevc" to "video/hevc", "av1" to "video/av01",
        "vp9" to "video/x-vnd.on2.vp9", "vp8" to "video/x-vnd.on2.vp8", "mpeg2video" to "video/mpeg2",
        "mpeg4" to "video/mp4v-es")
    private val decoders = ConcurrentHashMap<String, List<MediaCodecInfo>>()

    private fun hardware(mime: String) = decoders.getOrPut(mime) {
        MediaCodecList(MediaCodecList.REGULAR_CODECS).codecInfos.filter { info ->
            !info.isEncoder && !info.isAlias && info.isHardwareAccelerated && mime in info.supportedTypes &&
                runCatching { !info.getCapabilitiesForType(mime).isFeatureRequired(MediaCodecInfo.CodecCapabilities.FEATURE_SecurePlayback) }.getOrDefault(false)
        }
    }

    /** Container parameters from the native details' video_stream, or null when they are incomplete. */
    fun stream(details: JSONObject?): Stream? {
        val video = details?.optJSONObject("video_stream") ?: return null
        val width = video.optString("width").toIntOrNull() ?: return null
        val height = video.optString("height").toIntOrNull() ?: return null
        if (width <= 0 || height <= 0) return null
        return Stream(video.optString("codec"), width, height, video.optString("fps").toDoubleOrNull()?.takeIf { it > 0 && it.isFinite() } ?: 0.0)
    }

    data class Stream(val codec: String, val width: Int, val height: Int, val fps: Double) {
        fun json(): JSONObject = JSONObject().put("codec", codec).put("width", width).put("height", height)
            .put("fps", Math.round(fps * 100) / 100.0)
    }

    /** The hardware decoder closest to handling the stream, with its advertised limits and verdict. */
    fun describe(stream: Stream): JSONObject {
        val result = JSONObject().put("device", Build.MODEL)
        val mime = mimes[stream.codec] ?: return result.put("mime", "").put("hardware", false).put("exceeded", false)
        result.put("mime", mime)
        val candidates = hardware(mime).mapNotNull { info ->
            runCatching { info to info.getCapabilitiesForType(mime).videoCapabilities!! }.getOrNull()
        }
        if (candidates.isEmpty()) return result.put("hardware", false).put("exceeded", true)
        fun verdict(video: MediaCodecInfo.VideoCapabilities) = when {
            stream.fps > 0 && video.areSizeAndRateSupported(stream.width, stream.height, stream.fps) -> 2
            video.isSizeSupported(stream.width, stream.height) -> 1
            else -> 0
        }
        val (info, video) = candidates.maxWith(compareBy({ verdict(it.second) }, { largest(it.second)?.let { p -> p.first.toLong() * p.second * p.third } ?: 0L }))
        val level = verdict(video)
        result.put("hardware", true).put("decoder", info.name)
            .put("max_width", video.supportedWidths.upper).put("max_height", video.supportedHeights.upper)
            .put("size_supported", level >= 1).put("rate_supported", level == 2 || stream.fps <= 0 && level >= 1)
            .put("exceeded", level == 0 || stream.fps > 0 && level < 2)
        largest(video)?.let { (w, h, fps) -> result.put("peak_width", w).put("peak_height", h).put("peak_fps", fps) }
        // The tallest picture the decoder takes at this width (its block budget, as the device reports it).
        runCatching { video.getSupportedHeightsFor(stream.width).upper }.getOrNull()?.let { result.put("max_height_at_width", it) }
        return result
    }

    /** The largest advertised performance point: width, height, frames per second. */
    private fun largest(video: MediaCodecInfo.VideoCapabilities): Triple<Int, Int, Int>? =
        video.supportedPerformancePoints?.maxWithOrNull(compareBy({ it.toString().let(::area) }, { fpsOf(it.toString()) }))
            ?.toString()?.let { text -> size(text)?.let { (w, h) -> Triple(w, h, fpsOf(text)) } }

    // PerformancePoint exposes its size and rate only through toString(), e.g. "PerformancePoint(7680x4320@60, 59 blocks/s)".
    private fun size(text: String) = Regex("(\\d+)x(\\d+)@").find(text)?.destructured?.let { (w, h) -> w.toInt() to h.toInt() }
    private fun area(text: String) = size(text)?.let { (w, h) -> w.toLong() * h } ?: 0L
    private fun fpsOf(text: String) = Regex("@(\\d+)").find(text)?.groupValues?.get(1)?.toInt() ?: 0
}
