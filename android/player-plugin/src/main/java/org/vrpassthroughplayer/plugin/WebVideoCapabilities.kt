package org.vrpassthroughplayer.plugin

import android.media.MediaCodecInfo
import android.media.MediaCodecList
import android.media.MediaFormat

/** A conservative first-pass filter, not a sustained-performance claim. Decode is verified on device. */
internal class WebVideoCapabilities(private val maxHeight: Int = 1080,
    private val rejected: ((Report) -> Unit)? = null,
    private val inventory: () -> List<Decoder> = { androidDecoders() }) {
    // No URLs, titles, codec names, credentials or exception messages enter the report.
    internal enum class Check { SUPPORTED, NO_VIDEO_CAPS, SIZE, RATE, FORMAT, QUERY_ERROR }
    internal interface Decoder {
        val hardware: Boolean
        val types: Set<String>
        fun check(track: WebVideoTrack, mime: String, profile: Int?, level: Int?): Check
    }
    internal data class Report(val accepted: Boolean, val reason: String, val mime: String,
        val width: Int, val height: Int, val fps: Double, val limit: Int, val profile: Int?, val level: Int?,
        val hardware: Int = 0, val software: Int = 0, val checks: Map<Check, Int> = emptyMap()) {
        // Two short records fit CrashTrail's 182-byte payload including thread/stage prefixes.
        fun details(id: Int): List<String> = listOf(
            "id=$id reason=$reason mime=$mime hw=$hardware sw=$software",
            "id=$id ${width}x${height} fps=$fps cap=$limit p=${profile ?: 0} l=${level ?: 0} " +
                "size=${checks[Check.SIZE] ?: 0} rate=${checks[Check.RATE] ?: 0} fmt=${checks[Check.FORMAT] ?: 0} " +
                "caps=${checks[Check.NO_VIDEO_CAPS] ?: 0} err=${checks[Check.QUERY_ERROR] ?: 0}")
    }
    private val codecs by lazy { inventory() }
    fun accepts(track: WebVideoTrack): Boolean {
        val result = inspect(track)
        if (!result.accepted) rejected?.invoke(result)
        return result.accepted
    }
    internal fun inspect(track: WebVideoTrack): Report {
        val limit = if (track.projectionHint.isNotEmpty()) maxOf(maxHeight, 2160) else maxHeight
        var mime = "unknown"
        var profile: Int? = null
        var level: Int? = null
        fun report(reason: String, accepted: Boolean = false) = Report(accepted, reason, mime,
            track.width, track.height, track.fps.takeIf { it > 0 } ?: 30.0, limit, profile, level)
        if (minOf(track.width, track.height) > limit || maxOf(track.width, track.height) > limit * 2)
            return report("dimension_policy")
        // Preserve the ordinary player's probe path for metadata-free, non-immersive streams.
        if (track.videoCodec == "unknown" || track.width == 0 || track.height == 0)
            return report(if (track.projectionHint.isEmpty()) "deferred_probe" else "immersive_metadata", track.projectionHint.isEmpty())
        mime = when {
            track.videoCodec.startsWith("avc1") || track.videoCodec == "h264" -> "video/avc"
            track.videoCodec.startsWith("vp09") || track.videoCodec == "vp9" -> "video/x-vnd.on2.vp9"
            track.videoCodec.startsWith("av01") -> "video/av01"
            track.videoCodec.startsWith("hev1") || track.videoCodec.startsWith("hvc1") || track.videoCodec == "hevc" -> "video/hevc"
            else -> return report("codec_policy")
        }
        if (mime == "video/x-vnd.on2.vp9" && track.videoCodec.startsWith("vp09.") && track.videoCodec.split('.').getOrNull(1) != "00")
            return report("vp9_profile_policy")
        if (mime == "video/av01") profile = av1SdrProfile(track.videoCodec) ?: return report("av1_sdr_policy")
        if (mime == "video/avc" && track.videoCodec.startsWith("avc1.")) {
            val value = track.videoCodec.substringAfter('.')
            profile = when (value.take(2).toIntOrNull(16)) {
                66 -> MediaCodecInfo.CodecProfileLevel.AVCProfileBaseline
                77 -> MediaCodecInfo.CodecProfileLevel.AVCProfileMain
                100 -> MediaCodecInfo.CodecProfileLevel.AVCProfileHigh
                else -> return report("avc_profile_policy")
            }
            level = when (value.takeLast(2).toIntOrNull(16)) {
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
                else -> return report("avc_level_policy")
            }
        }
        val candidates = try { codecs.filter { mime in it.types } } catch (_: Exception) {
            return report("inventory_query_error")
        }
        val hardware = candidates.filter { it.hardware }
        val base = report("no_hardware_decoder").copy(hardware = hardware.size, software = candidates.size - hardware.size)
        if (hardware.isEmpty()) return base
        val checks = mutableMapOf<Check, Int>()
        for (decoder in hardware) {
            val check = try { decoder.check(track, mime, profile, level) } catch (_: Exception) { Check.QUERY_ERROR }
            checks[check] = (checks[check] ?: 0) + 1
            if (check == Check.SUPPORTED) return base.copy(accepted = true, reason = "supported", checks = checks)
        }
        val reason = if (checks.size > 1) "mixed_decoder_rejection" else when (checks.keys.single()) {
            Check.SIZE -> "size_unsupported"
            Check.RATE -> "rate_unsupported"
            Check.FORMAT -> "format_profile_unsupported"
            Check.NO_VIDEO_CAPS -> "video_caps_missing"
            else -> "decoder_query_error"
        }
        return base.copy(reason = reason, checks = checks)
    }

    companion object {
        private fun androidDecoders(): List<Decoder> =
            MediaCodecList(MediaCodecList.REGULAR_CODECS).codecInfos.filter { !it.isEncoder }.map { info ->
                object : Decoder {
                    override val hardware = info.isHardwareAccelerated
                    override val types = info.supportedTypes.toSet()
                    override fun check(track: WebVideoTrack, mime: String, profile: Int?, level: Int?): Check {
                        val caps = info.getCapabilitiesForType(mime)
                        val video = caps.videoCapabilities ?: return Check.NO_VIDEO_CAPS
                        val rate = track.fps.takeIf { it > 0 } ?: 30.0
                        if (!video.isSizeSupported(track.width, track.height)) return Check.SIZE
                        if (!video.areSizeAndRateSupported(track.width, track.height, rate)) return Check.RATE
                        val format = MediaFormat.createVideoFormat(mime, track.width, track.height).apply {
                            setFloat(MediaFormat.KEY_FRAME_RATE, rate.toFloat())
                            if (profile != null) setInteger(MediaFormat.KEY_PROFILE, profile)
                            if (level != null) setInteger(MediaFormat.KEY_LEVEL, level)
                        }
                        return if (caps.isFormatSupported(format)) Check.SUPPORTED else Check.FORMAT
                    }
                }
            }

        // AV1 ISOBMFF section 5 defines the omitted suffix as BT.709 4:2:0 SDR.
        // An explicit suffix must prove that same color space. PQ/HLG, unspecified
        // colors, other profiles and 12-bit stay outside this output policy.
        internal fun av1SdrProfile(codec: String): Int? {
            val match = Regex("av01\\.0\\.([0-1][0-9]|2[0-3])([mh])\\.(08|10)(?:\\.0\\.11[0-2]\\.01\\.01\\.01\\.[01])?",
                RegexOption.IGNORE_CASE).matchEntire(codec) ?: return null
            if (match.groupValues[2].equals("h", true) && match.groupValues[1].toInt() < 8) return null
            return if (match.groupValues[3] == "10") MediaCodecInfo.CodecProfileLevel.AV1ProfileMain10
                else MediaCodecInfo.CodecProfileLevel.AV1ProfileMain8
        }
    }
}
