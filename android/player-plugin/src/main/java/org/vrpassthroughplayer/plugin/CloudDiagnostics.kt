package org.vrpassthroughplayer.plugin

import org.json.JSONObject
import java.net.URI

/** Error DTOs contain bounded, redacted diagnostics, never a response body or stack trace. */
internal object CloudDiagnostics {
    private val header = Regex("(?im)(cookie|set-cookie|authorization)\\s*[:=][^\\r\\n]*")
    private val secret = Regex("(?i)(\"?(?:access_token|refresh_token|token|password|passwd|client_secret|secret|cookie|authorization|sign|signature|UID|CID|SEID|KID)\"?\\s*[:=]\\s*)(?:\"[^\"\\r\\n]*\"|'[^'\\r\\n]*'|[^\\s,;}&]+)")
    private val url = Regex("(?i)https?://[^\\s<>\"']+")
    fun sanitize(value: String): String {
        val headers = header.replace(value) { "${it.groupValues[1]}: [redacted]" }
        val secrets = secret.replace(headers) { "${it.groupValues[1]}[redacted]" }
        return url.replace(secrets) {
            val host = runCatching { URI(it.value).host }.getOrNull()
            if (host.isNullOrBlank()) "[URL redacted]" else "https://$host/[redacted]"
        }.map { if (it.isISOControl() && it != '\n' && it != '\t') ' ' else it }.joinToString("").trim().let {
            if (it.length > 4096) it.take(4096) + "…" else it
        }
    }
    fun failure(stage: String, error: Exception): CloudFailure {
        if (error is CloudFailure) return error
        // JSON exceptions may quote the entire payload. Only their type is diagnostic.
        val message = if (error is org.json.JSONException) "Invalid cloud response" else error.message.orEmpty()
        // A bare Kotlin require failure is otherwise indistinguishable from a transport error.
        // Retain one application source location, never a full stack or filesystem path.
        val location = if (error is IllegalArgumentException) error.stackTrace.firstOrNull {
            it.className.startsWith("org.vrpassthroughplayer.plugin.")
        }?.let { " @ ${it.className.substringAfterLast('.')}.${it.methodName}:${it.lineNumber}" }.orEmpty() else ""
        return CloudFailure(detail = "$stage: ${error.javaClass.simpleName}: $message$location", cause = error)
    }
    fun checkCore(result: JSONObject, route: String): JSONObject {
        if (result.optInt("code") == 200) return result
        if (route == "/remove115" && result.opt("delete_started") == false)
            throw CloudDeleteRejected(if (result.optString("delete_reason") == "changed")
                "Cloud file changed. Refresh the folder" else "File deletion failed")
        val message = result.optString("message")
        if (message in setOf("Search expired. Search again", "Search scope unavailable", "Search result limit reached", "Folder too large to search", "Invalid search"))
            throw IllegalStateException(message)
        val detail = result.optString("error_detail").ifBlank { message }
        if (result.optString("error_reason") in setOf("cloud_page_expired", "cloud_location_expired"))
            throw CloudFailure(result.getString("error_reason"), detail)
        throw CloudFailure(detail = "OpenList $route · code ${result.optInt("code")}\n$detail")
    }
    fun providerFailure(json: JSONObject): CloudFailure {
        val codes = listOf("errno", "errNo", "code").mapNotNull { key ->
            json.opt(key)?.takeIf { it.toString().matches(Regex("-?[0-9]+")) }?.toString()
        }
        val code = codes.firstOrNull { it != "0" } ?: codes.firstOrNull().orEmpty()
        val message = listOf("error", "errmsg", "msg", "message").firstNotNullOfOrNull { key ->
            (json.opt(key) as? String)?.takeIf { it.isNotBlank() }
        }.orEmpty()
        val reason = if (code in setOf("99", "911", "990001", "40101032")) "cloud_login_required" else "cloud_unavailable"
        return CloudFailure(reason, "115 code: ${code.ifEmpty { "unknown" }}, message: $message")
    }
    fun response(error: Exception, stage: String): JSONObject {
        val failure = failure(stage, error)
        return JSONObject().put("state", "error").put("error", failure.message)
            .put("error_reason", failure.reason).put("error_detail", failure.detail)
    }
}
