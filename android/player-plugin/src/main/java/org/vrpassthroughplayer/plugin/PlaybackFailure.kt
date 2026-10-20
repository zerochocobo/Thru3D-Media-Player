package org.vrpassthroughplayer.plugin

import org.json.JSONObject
import java.io.FileNotFoundException
import java.io.IOException
import java.io.InterruptedIOException
import java.net.ConnectException
import java.net.SocketTimeoutException
import java.net.UnknownHostException
import javax.net.ssl.SSLException

/** A media failure, independent of the pipeline event code. Never carries an address or response body. */
internal data class PlaybackFailure(
    val reason: String = "unknown",
    val stage: String = "opening",
    val detail: String = "",
    val httpStatus: Int = 0,
    val mpvCode: Int = 0,
    val sourceCode: String = "",
    val exceptionType: String = "",
) {
    fun json(): JSONObject = JSONObject().put("reason", reason).put("stage", stage)
        .put("detail", safeDetail(detail)).put("http_status", httpStatus).put("mpv_code", mpvCode)
        .put("source_code", safeDetail(sourceCode)).put("exception_type", exceptionType)

    companion object {
        // Redact entire addresses, including local proxy tokens and non-HTTP credentials.
        private val address = Regex("(?i)[a-z][a-z0-9+.-]*://[^\\s<>\"']+")
        fun safeDetail(value: String): String {
            if (value.contains(Regex("(?i)<(?:!doctype|html|body)|^\\s*[\\[{]"))) return "Server response omitted"
            return address.replace(CloudDiagnostics.sanitize(value), "[address redacted]")
                .lineSequence().take(3).joinToString(" ").take(360)
        }

        fun http(status: Int, stage: String = "reading"): PlaybackFailure = PlaybackFailure(
            when (status) {
                401, 403 -> "access_denied"
                404 -> "not_found"
                410 -> "link_expired"
                416 -> "invalid_range"
                else -> "http_error"
            }, stage, "Upstream HTTP $status", httpStatus = status)

        fun from(error: Throwable, stage: String = "opening"): PlaybackFailure {
            val chain = generateSequence(error) { it.cause?.takeIf { next -> next !== it } }.take(8).toList()
            chain.filterIsInstance<PlaybackFailureException>().firstOrNull()?.let { return it.failure }
            val typed = chain.firstOrNull { it is SocketTimeoutException || it is SSLException || it is UnknownHostException ||
                it is ConnectException || it is SecurityException || it is FileNotFoundException }
                ?: chain.firstOrNull { it is CloudFailure || it is MediaServerFailure } ?: error
            val cloud = chain.filterIsInstance<CloudFailure>().firstOrNull()
            val server = chain.filterIsInstance<MediaServerFailure>().firstOrNull()
            val reason = when {
                server != null && server.httpStatus in 400..599 -> http(server.httpStatus).reason
                typed is SocketTimeoutException -> "network_timeout"
                typed is SSLException -> "tls_failed"
                typed is UnknownHostException -> "host_not_found"
                typed is ConnectException -> "connection_failed"
                typed is SecurityException -> "access_denied"
                typed is FileNotFoundException && stage in setOf("opening", "resolving", "reading", "parsing") -> "not_found"
                cloud?.reason == "cloud_login_required" -> "login_required"
                cloud != null && cloud.httpStatus in 400..599 -> http(cloud.httpStatus).reason
                cloud?.reason == "cloud_file_missing" -> "source_missing"
                cloud?.reason == "cloud_file_changed" -> "file_changed"
                server?.code == "Server does not support seeking" -> "range_unsupported"
                server?.code == "Invalid byte range" -> "invalid_range"
                server?.code == "Invalid media response" -> "not_media"
                server?.code == "TLS certificate verification failed" -> "tls_failed"
                server?.code == "Network read timed out" -> "network_timeout"
                server?.code == "Stream interrupted" -> "stream_interrupted"
                else -> "unknown"
            }
            val detail = if (typed is org.json.JSONException) "Invalid server response"
                else if (typed !== cloud && typed !== server) typed.message.orEmpty()
                else cloud?.detail?.ifBlank { cloud.message.orEmpty() } ?: typed.message.orEmpty()
            return PlaybackFailure(reason, stage, detail, server?.httpStatus ?: cloud?.httpStatus ?: 0,
                sourceCode = cloud?.reason ?: server?.code.orEmpty(), exceptionType = typed.javaClass.simpleName)
        }

        fun native(status: JSONObject): PlaybackFailure {
            val code = status.optInt("mpv_code")
            val reason = status.optString("failure_reason").ifBlank { if (status.optBoolean("render_failed")) "video_output_failed" else when (code) {
                -14 -> "audio_output_failed"
                -15 -> "video_output_failed"
                -16 -> "nothing_to_play"
                -17 -> "unknown_format"
                else -> "unknown"
            } }
            val stage = status.optString("failure_stage").ifBlank { when (reason) {
                "audio_output_failed", "video_output_failed" -> "output"
                "nothing_to_play", "unknown_format" -> "parsing"
                else -> "opening"
            } }
            return PlaybackFailure(reason, stage, listOf(status.optString("error"), status.optString("render_error"))
                .filter(String::isNotBlank).joinToString("; "), mpvCode = code)
        }

        /** Consult only the current video's stream, and keep native errors even when upstream is clearer. */
        fun report(code: String, error: Throwable, stage: String, upstream: PlaybackFailure? = null): JSONObject {
            val failure = from(error, stage)
            // RVM errors belong to the effect, even while the media reader is starting.
            // A stale proxy failure must not replace a GPU initialization failure.
            val original = if (code == "MPV_RVM_FAILED") {
                val gpu = failure.detail.contains("MNN OpenCL backend unavailable") ||
                    failure.detail.contains("MNN OpenCL session creation failed")
                failure.copy(reason = if (gpu) "ai_gpu_unavailable" else "ai_processing_failed",
                    stage = if (gpu) "ai_initialization" else "ai_processing")
            } else failure
            val selected = if (upstream != null && (original.reason == "unknown" ||
                    original.reason == "unknown_format" && upstream.reason != "unknown")) upstream else original
            return selected.copy(mpvCode = original.mpvCode).json().put("code", code)
                .put("message", safeDetail(original.detail)).put("native_detail", if (selected !== original || original.mpvCode != 0) safeDetail(original.detail) else "")
        }

        fun cancelled(error: Throwable): Boolean = error is InterruptedIOException && error !is SocketTimeoutException ||
            error is java.util.concurrent.CancellationException || (error is PlaybackFailureException && error.failure.reason == "cancelled")
    }
}

internal class PlaybackFailureException(val failure: PlaybackFailure, cause: Throwable? = null) : IOException(failure.detail, cause)
