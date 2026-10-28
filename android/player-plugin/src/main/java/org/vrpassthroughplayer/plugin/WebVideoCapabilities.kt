package org.vrpassthroughplayer.plugin

import android.media.MediaCodecInfo
import android.media.MediaCodecList
import android.media.MediaFormat

/** A conservative first-pass filter, not a sustained-performance claim. Decode is verified on device. */
internal class WebVideoCapabilities(private val maxHeight: Int = 1080) {
    private val codecs by lazy { MediaCodecList(MediaCodecList.REGULAR_CODECS).codecInfos.filter { !it.isEncoder && it.isHardwareAccelerated } }
    fun accepts(track: WebVideoTrack): Boolean {
        val limit = if (track.projectionHint.isNotEmpty()) maxOf(maxHeight, 2160) else maxHeight
        if (minOf(track.width, track.height) > limit || maxOf(track.width, track.height) > limit * 2) return false
        // Some sites publish neither CODECS nor dimensions. The normal player's decoder
        // must probe those streams; do not fabricate H.264 or 1080p metadata.
        if (track.videoCodec == "unknown" || track.width == 0 || track.height == 0) return track.projectionHint.isEmpty()
        val mime = when {
            track.videoCodec.startsWith("avc1") || track.videoCodec == "h264" -> "video/avc"
            track.videoCodec.startsWith("vp09") || track.videoCodec == "vp9" -> "video/x-vnd.on2.vp9"
            track.videoCodec.startsWith("av01") -> "video/av01"
            track.videoCodec.startsWith("hev1") || track.videoCodec.startsWith("hvc1") || track.videoCodec == "hevc" -> "video/hevc"
            else -> return false
        }
        // Reject high bit-depth/HDR until that representation has an explicit output policy.
        if (mime == "video/x-vnd.on2.vp9" && track.videoCodec.startsWith("vp09.") && track.videoCodec.split('.').getOrNull(1) != "00") return false
        if (mime == "video/av01" && track.videoCodec.split('.').getOrNull(3) != "08") return false
        return codecs.any { codec -> runCatching {
            val caps = codec.getCapabilitiesForType(mime)
            val video = caps.videoCapabilities ?: return@runCatching false
            val rate = track.fps.takeIf { it > 0 } ?: 30.0
            video.areSizeAndRateSupported(track.width, track.height, rate) && caps.isFormatSupported(
                MediaFormat.createVideoFormat(mime, track.width, track.height).apply {
                    setFloat(MediaFormat.KEY_FRAME_RATE, rate.toFloat())
                    // Decoder profile/level support for AVC is checked against the RFC 6381 value.
                    if (mime == "video/avc" && track.videoCodec.startsWith("avc1.")) {
                        val value = track.videoCodec.substringAfter('.')
                        val profile = when (value.take(2).toIntOrNull(16)) {
                            66 -> MediaCodecInfo.CodecProfileLevel.AVCProfileBaseline
                            77 -> MediaCodecInfo.CodecProfileLevel.AVCProfileMain
                            100 -> MediaCodecInfo.CodecProfileLevel.AVCProfileHigh
                            else -> return@runCatching false
                        }
                        setInteger(MediaFormat.KEY_PROFILE, profile)
                        val level = when (value.takeLast(2).toIntOrNull(16)) {
                            10 -> MediaCodecInfo.CodecProfileLevel.AVCLevel1
                            11 -> if ((value.substring(2, 4).toIntOrNull(16) ?: 0) and 16 != 0)
                                MediaCodecInfo.CodecProfileLevel.AVCLevel1b else MediaCodecInfo.CodecProfileLevel.AVCLevel11
                            12 -> MediaCodecInfo.CodecProfileLevel.AVCLevel12
                            13 -> MediaCodecInfo.CodecProfileLevel.AVCLevel13
                            20 -> MediaCodecInfo.CodecProfileLevel.AVCLevel2
                            21 -> MediaCodecInfo.CodecProfileLevel.AVCLevel21
                            22 -> MediaCodecInfo.CodecProfileLevel.AVCLevel22
                            30 -> MediaCodecInfo.CodecProfileLevel.AVCLevel3
                            31 -> MediaCodecInfo.CodecProfileLevel.AVCLevel31
                            32 -> MediaCodecInfo.CodecProfileLevel.AVCLevel32
                            40 -> MediaCodecInfo.CodecProfileLevel.AVCLevel4
                            41 -> MediaCodecInfo.CodecProfileLevel.AVCLevel41
                            42 -> MediaCodecInfo.CodecProfileLevel.AVCLevel42
                            50 -> MediaCodecInfo.CodecProfileLevel.AVCLevel5
                            51 -> MediaCodecInfo.CodecProfileLevel.AVCLevel51
                            52 -> MediaCodecInfo.CodecProfileLevel.AVCLevel52
                            else -> return@runCatching false
                        }
                        setInteger(MediaFormat.KEY_LEVEL, level)
                    }
                })
        }.getOrDefault(false) }
    }
}
