package org.vrpassthroughplayer.plugin

import org.json.JSONObject
import org.junit.Assert.*
import org.junit.Test

class WebBrowserMangoDiagnosticsTest {
    @Test fun onlyBoundedPublicFieldsCrossTheUiStatusBoundary() {
        val raw = JSONObject().put("status", "https://private.test/token").put("id", "secret-token")
            .put("duration", 9999999).put("declared_dispatches", 1000000).put("declared_files", -1)
            .put("manifests", 10000).put("bound_hls", 10000).put("cookie", "private-credential")
            .put("url", "https://private.test/token").put("fileHash", "private-hash")
        val result = WebBrowserMango.captureDiagnostics(JSONObject().put("mango_capture", raw))
        assertEquals("unknown", result.getString("status"))
        assertEquals("", result.getString("id"))
        assertEquals(0.0, result.getDouble("duration"), 0.0)
        assertEquals(128, result.getInt("declared_dispatches"))
        assertEquals(0, result.getInt("declared_files"))
        assertEquals(8, result.getInt("manifests"))
        assertEquals(6, result.getInt("bound_hls"))
        assertFalse(result.toString().contains("private"))
    }
}
