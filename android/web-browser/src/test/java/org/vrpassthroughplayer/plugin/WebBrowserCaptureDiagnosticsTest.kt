package org.vrpassthroughplayer.plugin

import org.json.JSONObject
import org.junit.Assert.*
import org.junit.Test

class WebBrowserCaptureDiagnosticsTest {
    @Test fun rejectedIqiyiDeclarationReasonsNeverExportTheDeclaration() {
        for(reason in listOf("unsupported_declaration","unsupported_container","missing_playlist","oversize_playlist","non_hls_playlist")) {
            val raw=JSONObject().put("status",reason).put("capture_ready",false).put("binding_ready",false)
                .put("playlist","PRIVATE_DECLARATION").put("ff","PRIVATE_FORMAT")
            val result=WebBrowserCaptureDiagnostics.project("iqiyi",JSONObject().put("iqiyi_diagnostics",raw))
            assertEquals(reason,result.getString("status"));assertFalse(result.getBoolean("capture_ready"))
            assertFalse(result.getBoolean("binding_ready"));assertEquals(3,result.length())
            raw.put("status",reason+"_PRIVATE")
            assertEquals("unknown",WebBrowserCaptureDiagnostics.project("iqiyi",JSONObject().put("iqiyi_diagnostics",raw)).getString("status"))
        }
    }
    @Test fun onlyKnownReasonsAndBoundedNumbersCanLeaveThePrivateMediaReport() {
        val raw=JSONObject().put("status","https://private.test/token").put("public_id","private-token")
            .put("expected_width",99999).put("expected_height","1280").put("expected_duration",5.5)
            .put("decoded_duration",999999).put("advertisement","private-cookie")
            .put("url","https://private.test/media").put("authorization","private-cookie")
        val result=WebBrowserCaptureDiagnostics.project("tiktok",JSONObject().put("tiktok_diagnostics",raw))
        assertEquals("{\"status\":\"unknown\"}",result.toString())
        assertEquals(0,WebBrowserCaptureDiagnostics.project("other",JSONObject()).length())
    }
    @Test fun readinessFailureKeepsOnlyItsPublicIdentityAndNumericEvidence() {
        val tiktok=JSONObject().put("status","decoded_shape").put("public_id","6742501081818877190")
            .put("expected_width",720).put("expected_height",1280).put("expected_duration",6).put("decoded_duration",5.783)
            .put("advertisement",false).put("media_url","secret")
        val a=WebBrowserCaptureDiagnostics.project("tiktok",JSONObject().put("tiktok_diagnostics",tiktok))
        assertEquals("decoded_shape",a.getString("status"));assertEquals(5.783,a.getDouble("decoded_duration"),0.0)
        assertFalse(a.getBoolean("advertisement"));assertFalse(a.has("media_url"))
        val iqiyi=JSONObject().put("status","bound").put("capture_ready",true).put("binding_ready",false)
            .put("timeline_matches",false).put("drm_type",1).put("dispatcher_count",9).put("playlist","secret")
        val b=WebBrowserCaptureDiagnostics.project("iqiyi",JSONObject().put("iqiyi_diagnostics",iqiyi))
        assertTrue(b.getBoolean("capture_ready"));assertFalse(b.getBoolean("binding_ready"))
        assertFalse(b.getBoolean("timeline_matches"));assertEquals(9,b.getInt("dispatcher_count"));assertFalse(b.has("playlist"))
    }
}
