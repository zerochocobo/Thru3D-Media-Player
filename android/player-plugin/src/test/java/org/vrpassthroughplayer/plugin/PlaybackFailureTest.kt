package org.vrpassthroughplayer.plugin

import org.json.JSONObject
import org.junit.Assert.*
import org.junit.Test
import java.io.IOException
import java.net.SocketTimeoutException

class PlaybackFailureTest {
    @Test fun decoderLimitNamesTheVideoAndDeviceNumbers() {
        val details = JSONObject().put("video_stream", JSONObject().put("codec", "av1").put("width", "7680").put("height", "7680").put("fps", "59.940060"))
        val stream = DecoderCapacity.stream(details)!!
        assertEquals(DecoderCapacity.Stream("av1", 7680, 7680, 59.94006), stream)
        assertEquals(59.94, stream.json().getDouble("fps"), 0.0)
        assertNull(DecoderCapacity.stream(JSONObject().put("video_stream", JSONObject().put("codec", "av1").put("width", "").put("height", "7680"))))
        val decoder = JSONObject().put("decoder", "c2.qti.av1.decoder").put("exceeded", true).put("max_height_at_width", 4608)
        val timeout = PlaybackFailure("output_timeout", "output", mpvCode = 0)
        val named = PlaybackFailure.withCapacity(timeout, stream.json(), decoder)
        assertEquals("decoder_capacity_exceeded", named.reason)
        assertEquals("decoding", named.stage)
        val report = named.json()
        assertEquals(7680, report.getJSONObject("video").getInt("height"))
        assertEquals(4608, report.getJSONObject("decoder").getInt("max_height_at_width"))
        // The player's own size limit and unrelated failures keep their cause; the numbers still travel.
        val own = PlaybackFailure.withCapacity(PlaybackFailure("resolution_unsupported", "decoding"), stream.json(), decoder)
        assertEquals("resolution_unsupported", own.reason)
        assertTrue(own.json().has("decoder"))
        val network = PlaybackFailure.withCapacity(PlaybackFailure("network_timeout", "reading"), stream.json(), decoder)
        assertEquals("network_timeout", network.reason)
        val fits = PlaybackFailure.withCapacity(timeout, stream.json(), JSONObject().put("exceeded", false))
        assertEquals("output_timeout", fits.reason)
    }
    @Test fun rateOutsideAdvertisedRangePreservesTheObservedOutputFailure() {
        val video = DecoderCapacity.Stream("hevc", 8192, 4096, 59.94).json()
        val decoder = JSONObject().put("exceeded", true).put("size_supported", true).put("rate_supported", false)
        for (reason in listOf("output_timeout", "video_output_failed")) {
            val failure = PlaybackFailure.withCapacity(PlaybackFailure(reason, "output"), video, decoder)
            val report = PlaybackFailure.report("MPV_FRAME_PIPELINE_FAILED", PlaybackFailureException(failure), "reading")
            assertEquals(reason, report.getString("reason"))
            assertEquals("output", report.getString("stage"))
            assertEquals(59.94, report.getJSONObject("video").getDouble("fps"), 0.0)
            assertFalse(report.getJSONObject("decoder").getBoolean("rate_supported"))
        }
    }

    @Test fun outputTimeoutKeepsOnlyAvailableCacheMeasurements() {
        val details = JSONObject().put("cache_duration", "0.25").put("cache_speed", "0").put("paused_for_cache", "yes")
            .put("url", "https://secret.example/private")
        val status = JSONObject().put("failure_reason", "output_timeout").put("failure_stage", "output").put("details", details)
        val wait = PlaybackFailure.native(status).json().getJSONObject("output_wait")
        assertEquals(setOf("cache_seconds", "cache_bytes_per_second", "paused_for_cache"), wait.keys().asSequence().toSet())
        assertEquals(0.25, wait.getDouble("cache_seconds"), 0.0)
        assertEquals(0L, wait.getLong("cache_bytes_per_second"))
        assertTrue(wait.getBoolean("paused_for_cache"))
        assertFalse(PlaybackFailure.native(status.put("failure_reason", "unknown")).json().has("output_wait"))
        details.put("cache_duration", "nan").put("cache_speed", "").put("paused_for_cache", "")
        assertFalse(PlaybackFailure.native(status.put("failure_reason", "output_timeout")).json().has("output_wait"))
    }

    @Test fun providerTransportFailureIsNotAMissingFile() {
        val uri = "content://com.android.externalstorage.documents/tree/1234-ABCD%3A/document/1234-ABCD%3Amovie.mp4"
        assertEquals("storage_provider_failed", PlaybackFailure.from(StorageProviderUnavailable(), "reading").reason)
        val error = java.io.FileNotFoundException("Failed opening content provider: $uri")
        val report = PlaybackFailure.report("MPV_LOCAL_SOURCE_FAILED", error, "reading")
        assertEquals("storage_provider_failed", report.getString("reason"))
        assertEquals("reading", report.getString("stage"))
        assertFalse(report.toString().contains("1234-ABCD"))
        assertEquals("not_found", PlaybackFailure.from(java.io.FileNotFoundException("missing"), "reading").reason)
        assertEquals("access_denied", PlaybackFailure.from(SecurityException("denied"), "reading").reason)
    }
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
        for (detailGpu in listOf("MNN Vulkan backend unavailable; refusing CPU execution",
            "MNN GPU session creation failed", "AI GPU unavailable: OpenCL and Vulkan initialization failed")) {
            val unavailable = PlaybackFailure.report("MPV_RVM_FAILED", IllegalStateException(detailGpu), "reading")
            assertEquals("ai_gpu_unavailable", unavailable.getString("reason"))
            assertEquals("ai_initialization", unavailable.getString("stage"))
        }
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
        assertEquals(0, report.getInt("http_status"))
        assertTrue(report.getString("detail").contains("loading failed"))
    }

    @Test fun primaryHttpOpenStatusSurvivesTheFramePipelineReport() {
        val status = JSONObject().put("mpv_code", -13).put("failure_reason", "unknown")
            .put("failure_stage", "opening").put("error", "MPV playback: loading failed")
        for ((httpStatus, reason) in listOf(503 to "http_error", 403 to "access_denied", 404 to "not_found")) {
            val native = PlaybackFailure.native(status.put("http_status", httpStatus))
            val report = PlaybackFailure.report("MPV_FRAME_PIPELINE_FAILED", PlaybackFailureException(native), "output")
            assertEquals(reason, report.getString("reason"))
            assertEquals("opening", report.getString("stage"))
            assertEquals(httpStatus, report.getInt("http_status"))
            assertEquals(-13, report.getInt("mpv_code"))
            assertEquals("MPV playback: loading failed", report.getString("native_detail"))
        }
        assertEquals(0, PlaybackFailure.native(status.put("http_status", 200)).httpStatus)
        assertEquals(0, PlaybackFailure.native(status.put("http_status", 503).put("mpv_code", -17)).httpStatus)
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

        val gateway = PlaybackFailure.native(JSONObject().put("mpv_code", -13).put("http_status", 502)
            .put("error", "MPV playback: loading failed"))
        assertEquals(502, PlaybackFailure.report("pipeline", PlaybackFailureException(gateway), "output").getInt("http_status"))
    }

    @Test fun loopbackProxyStatusYieldsToTheLeaseDiagnosis() {
        // LocalStreamServer answers 404 for a revoked token, 416 for an unknown size and 502 for upstream reads.
        for (proxyStatus in listOf(404, 416, 502)) {
            val native = PlaybackFailureException(PlaybackFailure.native(JSONObject().put("mpv_code", -13)
                .put("http_status", proxyStatus).put("error", "MPV playback: loading failed")))
            val upstream = PlaybackFailure.report("pipeline", native, "output", PlaybackFailure.http(503))
            assertEquals("http_error", upstream.getString("reason"))
            assertEquals(503, upstream.getInt("http_status"))
            assertEquals(-13, upstream.getInt("mpv_code"))
            assertEquals("MPV playback: loading failed", upstream.getString("native_detail"))
            val unexplained = PlaybackFailure.report("pipeline", native, "output",
                PlaybackFailure(stage = "reading", detail = "Stream reset"))
            assertEquals("unknown", unexplained.getString("reason"))
            assertEquals(0, unexplained.getInt("http_status"))
            assertEquals(-13, unexplained.getInt("mpv_code"))
        }
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
        assertEquals("location_expired", PlaybackFailure.from(CloudFailure("cloud_location_expired")).reason)
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
