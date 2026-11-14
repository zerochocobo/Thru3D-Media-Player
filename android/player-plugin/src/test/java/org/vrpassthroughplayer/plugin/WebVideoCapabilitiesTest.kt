package org.vrpassthroughplayer.plugin

import android.media.MediaCodecInfo
import org.junit.Assert.*
import org.junit.Test

class WebVideoCapabilitiesTest {
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
