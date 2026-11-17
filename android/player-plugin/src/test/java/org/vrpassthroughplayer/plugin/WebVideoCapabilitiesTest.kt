package org.vrpassthroughplayer.plugin

import android.media.MediaCodecInfo
import org.junit.Assert.*
import org.junit.Test
import org.junit.After
import java.net.URI

class WebVideoCapabilitiesTest {
    @After fun clearTrail() { CrashTrail.detach() }
    private fun track(codec: String = "av01.0.16M.10", width: Int = 7680, height: Int = 3840,
        projection: String = "") = WebVideoTrack("test", URI("https://media.test/video?token=private"),
        mapOf("Cookie" to "private-cookie"), "mp4", codec, "none", width, height, 30.0, projectionHint = projection)

    private fun decoder(outcome: WebVideoCapabilities.Check, hardware: Boolean = true,
        mime: String = "video/av01") = object : WebVideoCapabilities.Decoder {
        override val hardware = hardware
        override val types = setOf(mime)
        override fun check(track: WebVideoTrack, mime: String, profile: Int?, level: Int?): WebVideoCapabilities.Check {
            if (outcome == WebVideoCapabilities.Check.QUERY_ERROR) throw IllegalStateException("private signed URL")
            return outcome
        }
    }

    @Test fun missingHardwareIsDifferentFromSoftwareOnlyOrOtherMime() {
        val sw = decoder(WebVideoCapabilities.Check.SUPPORTED, hardware = false)
        val hevc = decoder(WebVideoCapabilities.Check.SUPPORTED, mime = "video/hevc")
        val filter = WebVideoCapabilities(3840, inventory = { listOf(sw, hevc) })
        val report = filter.inspect(track())
        assertEquals("no_hardware_decoder", report.reason)
        assertEquals(0, report.hardware); assertEquals(1, report.software)
        assertFalse(report.accepted)
        assertTrue(filter.accepts(track("hev1.1.6.L180.90")))
    }

    @Test fun eachDriverRejectionAndMixedFailuresKeepTheirOwnCounters() {
        val reasons = mapOf(WebVideoCapabilities.Check.SIZE to "size_unsupported",
            WebVideoCapabilities.Check.RATE to "rate_unsupported",
            WebVideoCapabilities.Check.FORMAT to "format_profile_unsupported",
            WebVideoCapabilities.Check.NO_VIDEO_CAPS to "video_caps_missing",
            WebVideoCapabilities.Check.QUERY_ERROR to "decoder_query_error")
        for ((check, reason) in reasons) {
            val report = WebVideoCapabilities(3840, inventory = { listOf(decoder(check)) }).inspect(track())
            assertEquals(reason, report.reason); assertEquals(1, report.checks[check]); assertFalse(report.accepted)
        }
        val report = WebVideoCapabilities(3840, inventory = { reasons.keys.map { decoder(it) } }).inspect(track())
        assertEquals("mixed_decoder_rejection", report.reason); assertEquals(5, report.hardware)
        assertEquals(5, report.checks.size)
        assertEquals("inventory_query_error", WebVideoCapabilities(3840, inventory = {
            throw IllegalStateException("private inventory failure")
        }).inspect(track()).reason)
    }

    @Test fun policyReasonsAreDistinctAndDoNotQueryAndroid() {
        val filter = WebVideoCapabilities(3840, inventory = { error("Must not query") })
        assertEquals("dimension_policy", filter.inspect(track(width = 8192)).reason)
        assertEquals("av1_sdr_policy", filter.inspect(track("av01.0.16M.12")).reason)
        assertEquals("vp9_profile_policy", filter.inspect(track("vp09.02.10.10")).reason)
        assertEquals("avc_profile_policy", filter.inspect(track("avc1.FF0033")).reason)
        assertEquals("avc_level_policy", filter.inspect(track("avc1.6400FF")).reason)
        assertEquals("codec_policy", filter.inspect(track("unrecognized")).reason)
        assertTrue(filter.accepts(track("unknown", width = 0, height = 0)))
        assertEquals("immersive_metadata", filter.inspect(track("unknown", width = 0, height = 0, projection = "180")).reason)
    }

    @Test fun supportedCandidateAfterRejectedOneStillPassesAndLogsNoFailure() {
        var reports = 0
        val filter = WebVideoCapabilities(3840, rejected = { reports++ }, inventory = {
            listOf(decoder(WebVideoCapabilities.Check.FORMAT), decoder(WebVideoCapabilities.Check.SUPPORTED))
        })
        assertTrue(filter.accepts(track())); assertEquals(0, reports)
        assertFalse(filter.accepts(track(width = 8192))); assertEquals(1, reports)
    }

    @Test fun capabilityLogSurvivesExportWithoutSecretsOrTruncation() {
        val report = WebVideoCapabilities(3840, inventory = {
            listOf(decoder(WebVideoCapabilities.Check.QUERY_ERROR))
        }).inspect(track())
        val details = report.details(Int.MAX_VALUE)
        for (detail in details) {
            assertTrue(("[WebVideoResolver] web_beta.capability " + detail).toByteArray().size <= 182)
            CrashTrail.mark("web_beta.capability", detail)
        }
        val exported = DiagnosticLogs.webBetaSection()
        assertTrue(exported.contains("reason=decoder_query_error"))
        assertTrue(exported.contains("caps=0 err=1"))
        assertFalse(exported.contains("private")); assertFalse(exported.contains("media.test"))
    }

    @Test fun bilibili8kMain10SdrReachesTheHardwareProfileCheck() {
        assertEquals(MediaCodecInfo.CodecProfileLevel.AV1ProfileMain10,
            WebVideoCapabilities.av1SdrProfile("av01.0.01M.10.0.110.01.01.01.0"))
        assertEquals(MediaCodecInfo.CodecProfileLevel.AV1ProfileMain10,
            WebVideoCapabilities.av1SdrProfile("av01.0.16m.10"))
        assertEquals(MediaCodecInfo.CodecProfileLevel.AV1ProfileMain8,
            WebVideoCapabilities.av1SdrProfile("av01.0.05M.08"))
        assertEquals(MediaCodecInfo.CodecProfileLevel.AV1ProfileMain10,
            WebVideoCapabilities.av1SdrProfile("av01.0.16M.10.0.112.01.01.01.1"))
    }

    @Test fun hdrAndUnprovenOrInvalidAv1FormatsRemainRejected() {
        for (codec in listOf(
            "av01.0.16M.10.0.110.09.16.09.0", // HDR10 PQ
            "av01.0.16M.10.0.110.09.18.09.0", // HLG
            "av01.0.16M.08.0.110.09.16.09.0",
            "av01.0.16M.10.0.110.02.02.02.0", // unspecified color
            "av01.0.16M.10.0.110", // incomplete suffix
            "av01.0.16M.10.0.110.01.01.01.0.extra",
            "av01.0.16M.12", "av01.1.16M.10", "av01.2.16M.10",
            "av01.0.24M.10", "av01.0.01H.10", "av01.0.16X.10",
            "av01.0.16M.10.1.110.01.01.01.0",
            "av01.0.16M.10.0.000.01.01.01.0", "av01", "")) {
            assertNull(codec, WebVideoCapabilities.av1SdrProfile(codec))
        }
    }
}
