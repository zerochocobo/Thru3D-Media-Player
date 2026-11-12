package org.vrpassthroughplayer.plugin

import org.json.JSONObject
import org.junit.Assert.*
import org.junit.Test

class AirplayDiscoveryDiagnosticsTest {
    @Test fun loaderFailuresKeepUsefulCategoryWithoutPrivatePathsOrSecrets() {
        val diagnostics = AirplayDiscoveryDiagnostics()
        val failure = UnsatisfiedLinkError("dlopen failed: cannot locate symbol private_symbol in /private/pairing.key PIN=1234")
        diagnostics.record("native_load_failed", 2, "unavailable", 0, false, 0, failure = failure)
        val exported = DiagnosticLogs.redact(diagnostics.snapshot())
        assertTrue(exported.contains("missing_symbol"))
        assertTrue(exported.contains("UnsatisfiedLinkError"))
        for (secret in listOf("private_symbol", "pairing.key", "1234", "/private/")) assertFalse(exported.contains(secret))
    }

    @Test fun failedRegistrationSurvivesCleanupInExportWithItsOwnGeneration() {
        val diagnostics = AirplayDiscoveryDiagnostics()
        diagnostics.record("_airplay._tcp._registration_failed", 2, "failed", 45123, true, 1, code = 3)
        diagnostics.record("stopped", 3, "failed", 0, false, 0)
        val events = JSONObject(diagnostics.snapshot()).getJSONArray("events")
        assertEquals(3, events.getJSONObject(0).getInt("code"))
        assertEquals(2L, events.getJSONObject(0).getLong("generation"))
        assertEquals(45123, events.getJSONObject(0).getInt("port"))
        assertFalse(events.getJSONObject(1).getBoolean("native_running"))
    }

    @Test fun repeatedTogglesHaveBoundedEvidenceAndSnapshotsDoNotChange() {
        val diagnostics = AirplayDiscoveryDiagnostics()
        assertEquals(0, JSONObject(diagnostics.snapshot()).getJSONArray("events").length())
        repeat(100) { diagnostics.record("stopped", it.toLong(), "off", 0, false, 0) }
        val saved = diagnostics.snapshot()
        val events = JSONObject(saved).getJSONArray("events")
        assertEquals(32, events.length())
        assertEquals(68L, events.getJSONObject(0).getLong("generation"))
        diagnostics.record("native_start_begin", 100, "starting", 0, false, 0)
        assertEquals(99L, JSONObject(saved).getJSONArray("events").getJSONObject(31).getLong("generation"))
    }
}
