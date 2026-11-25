package org.vrpassthroughplayer.plugin

import org.json.JSONArray
import org.json.JSONObject
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

class MpvSourceDiagnosticsTest {
    @Test fun schemesAreCoarseLabelsOnly() {
        assertEquals("smb", MpvSourceDiagnostics.scheme("smb://nas/share/private/Film.mkv"))
        assertEquals("dlna", MpvSourceDiagnostics.scheme("DLNA://server/item"))
        assertEquals("medialib", MpvSourceDiagnostics.scheme("medialib://server/scene/private"))
        assertEquals("other", MpvSourceDiagnostics.scheme("private-host:8080/x"))
        assertEquals("other", MpvSourceDiagnostics.scheme("/sdcard/private.mp4"))
    }

    @Test fun closeStageFollowsTheCloseOrder() {
        // A source still in its own open task never reached the native close.
        assertEquals("source_preparing", MpvSourceDiagnostics.closeStage(true, true, true, "core_terminate"))
        // A replaced session whose frames are still held keeps the source from being reaped at all.
        assertEquals("session_attached", MpvSourceDiagnostics.closeStage(false, true, true, "core_terminate"))
        assertEquals("core_terminate", MpvSourceDiagnostics.closeStage(false, false, true, "core_terminate"))
        assertEquals("native", MpvSourceDiagnostics.closeStage(false, false, true, ""))
        assertEquals("native", MpvSourceDiagnostics.closeStage(false, false, true, null))
        // Native closed; the layer copy or fan-out still owns the Surface.
        assertEquals("layer_producer", MpvSourceDiagnostics.closeStage(false, false, false, null))
    }

    @Test fun onlyAWaitWithoutAFrameIsAnAbandonedOpen() {
        assertTrue(MpvSourceDiagnostics.abandoned(false, 3000, "replaced"))
        assertTrue(MpvSourceDiagnostics.abandoned(false, 40000, "failed"))
        assertFalse(MpvSourceDiagnostics.abandoned(false, 2999, "replaced")) // Browsing past a file.
        assertFalse(MpvSourceDiagnostics.abandoned(true, 40000, "replaced"))
        assertFalse(MpvSourceDiagnostics.abandoned(false, 40000, "shutdown"))
    }

    @Test fun reportsCarryStartupMarksAndOnlyNamedNativeFields() {
        val report = MpvSourceDiagnostics.source("close_stuck", "smb://nas/private.mkv", "preparing", true, true, false,
            mapOf("native_created_ms" to 812.6, "worker_started_ms" to 1.2, "source_resolved_ms" to 305.9))
        assertEquals("close_stuck", report.getString("kind"))
        assertEquals("smb", report.getString("scheme"))
        assertEquals(setOf("worker_started_ms", "source_resolved_ms", "native_created_ms"),
            report.getJSONObject("startup").keys().asSequence().toSet())
        assertEquals(812L, report.getJSONObject("startup").getLong("native_created_ms"))
        assertFalse(report.toString().contains("private"))

        val wait = JSONObject().put("stage", "core_terminate").put("closing_ms", 51000).put("decoder", "hardware")
            .put("mediacodec_started_ms", 500).put("decoder_observed_ms", 630).put("layer_software_fallback", false)
            .put("recent_modules", JSONArray(listOf("vd", "ao/aaudio"))).put("last_log_ms", 50500)
            .put("path", "/private/Film.mkv")
            .put("control_call", "snapshot").put("control_call_ms", 17000)
            .put("core_recent_modules", JSONArray(listOf("af", "ao/aaudio"))).put("core_last_log_ms", 16900)
            .put("core_decoder", "unknown").put("core_decoder_observed_ms", -1).put("core_mediacodec_started_ms", 480)
        val native = MpvSourceDiagnostics.native(wait)!!
        assertEquals(setOf("stage", "closing_ms", "decoder", "recent_modules", "last_log_ms", "mediacodec_started_ms",
            "decoder_observed_ms", "layer_software_fallback", "control_call", "control_call_ms", "core_recent_modules",
            "core_last_log_ms", "core_decoder", "core_decoder_observed_ms", "core_mediacodec_started_ms"),
            native.keys().asSequence().toSet())
        assertEquals("snapshot", native.getString("control_call"))
        assertEquals("ao/aaudio", native.getJSONArray("core_recent_modules").getString(1))
        assertEquals("ao/aaudio", native.getJSONArray("recent_modules").getString(1))
        assertNull(MpvSourceDiagnostics.native(null))
    }
}
