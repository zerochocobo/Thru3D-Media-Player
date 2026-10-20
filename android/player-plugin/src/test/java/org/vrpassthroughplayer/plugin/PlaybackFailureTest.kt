package org.vrpassthroughplayer.plugin

import org.json.JSONObject
import org.junit.Assert.*
import org.junit.Test
import java.io.IOException
import java.net.SocketTimeoutException

class PlaybackFailureTest {
    @Test fun rvmGpuFailureNamesTheEffectAndKeepsItsNativeCause() {
        val detail = "MNN OpenCL backend unavailable; refusing CPU execution; command_queue (-35)"
        val report = PlaybackFailure.report("MPV_RVM_FAILED", IllegalStateException(detail), "reading", PlaybackFailure.http(403))
        assertEquals("ai_gpu_unavailable", report.getString("reason"))
        assertEquals("ai_initialization", report.getString("stage"))
        assertEquals("IllegalStateException", report.getString("exception_type"))
        assertEquals(0, report.getInt("http_status"))
        assertEquals(detail, report.getString("detail"))
        val session = PlaybackFailure.report("MPV_RVM_FAILED", IllegalStateException("MNN OpenCL session creation failed"), "reading")
        assertEquals("ai_gpu_unavailable", session.getString("reason"))
        val inference = PlaybackFailure.report("MPV_RVM_FAILED", IllegalStateException("MNN RVM inference failed"), "reading")
        assertEquals("ai_processing_failed", inference.getString("reason"))
        assertEquals("ai_processing", inference.getString("stage"))
        assertEquals("unknown", PlaybackFailure.report("MPV_LOCAL_SOURCE_FAILED", IllegalStateException(detail), "reading").getString("reason"))
    }

    @Test fun genericLoadFailureKeepsNativeCodeWithoutInventingPermissions() {
        val native = PlaybackFailure.native(JSONObject().put("mpv_code", -13).put("error", "MPV playback: loading failed"))
        val report = PlaybackFailure.report("MPV_FRAME_PIPELINE_FAILED", PlaybackFailureException(native), "output")
        assertEquals("unknown", report.getString("reason"))
        assertEquals(-13, report.getInt("mpv_code"))
        assertTrue(report.getString("detail").contains("loading failed"))
    }

    @Test fun proxyFailureAddsUpstreamCauseAndRetainsNativeFailure() {
        val native = PlaybackFailure.native(JSONObject().put("mpv_code", -17).put("error", "MPV playback: unrecognized file format"))
        val report = PlaybackFailure.report("MPV_FRAME_PIPELINE_FAILED", PlaybackFailureException(native), "output", PlaybackFailure.http(403))
        assertEquals("access_denied", report.getString("reason"))
        assertEquals("reading", report.getString("stage"))
        assertEquals(403, report.getInt("http_status"))
        assertEquals(-17, report.getInt("mpv_code"))
        assertTrue(report.getString("native_detail").contains("unrecognized file format"))
        val output = PlaybackFailure.native(JSONObject().put("mpv_code", -15).put("error", "Video output initialization failed"))
        assertEquals("video_output_failed", PlaybackFailure.report("pipeline", PlaybackFailureException(output), "output", PlaybackFailure.http(403)).getString("reason"))
        val preflight = PlaybackFailure.report("MPV_LOCAL_SOURCE_FAILED", IOException("Media preflight could not read the source"), "parsing", PlaybackFailure.http(403))
        assertEquals("Media preflight could not read the source", preflight.getString("native_detail"))
    }

    @Test fun providerReasonAndNestedTransportCauseSurviveWrappers() {
        val login = CloudFailure("cloud_login_required", "Cloud API HTTP 401", httpStatus = 401)
        val report = PlaybackFailure.report("MPV_LOCAL_SOURCE_FAILED", IOException("wrapper", login), "resolving")
        assertEquals("login_required", report.getString("reason"))
        assertEquals("cloud_login_required", report.getString("source_code"))
        assertEquals(401, report.getInt("http_status"))
        val timeout = CloudFailure(cause = SocketTimeoutException("Read timed out"))
        assertEquals("network_timeout", PlaybackFailure.from(timeout, "resolving").reason)
        assertEquals("SocketTimeoutException", PlaybackFailure.from(timeout).exceptionType)
        val shortcut = StrmFailure("STRM_TARGET_UNAVAILABLE", login)
        assertEquals("login_required", PlaybackFailure.report(shortcut.code, shortcut, "resolving").getString("reason"))
        assertEquals("source_missing", PlaybackFailure.from(CloudFailure("cloud_file_missing")).reason)
    }

    @Test fun detailsNeverContainSignedAddressesCredentialsOrResponseBodies() {
        val detail = "Open https://user:pass@example.com/video?token=hiddenToken smb://user:pass@nas/private\nCookie: cookieSecret\nAuthorization: Bearer authSecret\npassword=plainSecret"
        val report = PlaybackFailure.report("source", IOException(detail), "resolving").toString()
        for (secret in listOf("hiddenToken", "cookieSecret", "authSecret", "plainSecret", "user:pass", "@nas/private")) assertFalse(secret, report.contains(secret))
        assertFalse(PlaybackFailure.safeDetail("<html><body>private server response</body></html>").contains("private"))
        assertFalse(PlaybackFailure.safeDetail("{\"token\":\"private\"}").contains("private"))
        assertTrue(PlaybackFailure.safeDetail("x".repeat(5000)).length <= 360)
    }
}
