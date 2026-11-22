package org.vrpassthroughplayer.plugin

import org.mozilla.geckoview.WebRequestError
import java.util.Base64

/**
 * Why a page did not open, for the toolbar status and the page area (otherwise a halted load leaves
 * it blank). Reasons are stable keys; Godot and [page] show their English catalog labels translated.
 * Certificate failures stay refused: the page only names the reason and offers a plain reload.
 */
internal object WebBrowserLoadError {
    private val reasons = mapOf(
        WebRequestError.ERROR_UNKNOWN_HOST to "dns",
        WebRequestError.ERROR_OFFLINE to "offline",
        WebRequestError.ERROR_NET_TIMEOUT to "timeout",
        WebRequestError.ERROR_CONNECTION_REFUSED to "refused", WebRequestError.ERROR_PORT_BLOCKED to "refused",
        WebRequestError.ERROR_NET_INTERRUPT to "interrupted", WebRequestError.ERROR_NET_RESET to "interrupted",
        WebRequestError.ERROR_SECURITY_BAD_CERT to "certificate", WebRequestError.ERROR_BAD_HSTS_CERT to "certificate",
        WebRequestError.ERROR_SECURITY_SSL to "secure", WebRequestError.ERROR_HTTPS_ONLY to "secure",
        WebRequestError.ERROR_PROXY_CONNECTION_REFUSED to "proxy", WebRequestError.ERROR_UNKNOWN_PROXY_HOST to "proxy",
        WebRequestError.ERROR_REDIRECT_LOOP to "redirect",
        WebRequestError.ERROR_UNSAFE_CONTENT_TYPE to "content", WebRequestError.ERROR_CORRUPTED_CONTENT to "content",
        WebRequestError.ERROR_INVALID_CONTENT_ENCODING to "content", WebRequestError.ERROR_CONTENT_CRASHED to "content",
        WebRequestError.ERROR_MALFORMED_URI to "address", WebRequestError.ERROR_UNKNOWN_PROTOCOL to "address",
        WebRequestError.ERROR_UNKNOWN_SOCKET_TYPE to "address", WebRequestError.ERROR_DATA_URI_TOO_LONG to "address",
        WebRequestError.ERROR_FILE_NOT_FOUND to "address", WebRequestError.ERROR_FILE_ACCESS_DENIED to "address",
        WebRequestError.ERROR_SAFEBROWSING_MALWARE_URI to "blocked", WebRequestError.ERROR_SAFEBROWSING_UNWANTED_URI to "blocked",
        WebRequestError.ERROR_SAFEBROWSING_HARMFUL_URI to "blocked", WebRequestError.ERROR_SAFEBROWSING_PHISHING_URI to "blocked",
        WebRequestError.ERROR_HARMFULADDON_URI to "blocked", WebRequestError.ERROR_LOCAL_NETWORK_ACCESS_DENIED to "blocked")
    /** Same keys as web_browser_panel.gd's LOAD_ERRORS. */
    val labels = mapOf("dns" to "Server not found", "offline" to "No network connection", "timeout" to "Connection timed out",
        "refused" to "Connection refused", "interrupted" to "Connection interrupted", "certificate" to "Untrusted certificate",
        "secure" to "Secure connection failed", "proxy" to "Proxy unavailable", "redirect" to "Too many redirects",
        "content" to "Page content error", "address" to "Unsupported address", "blocked" to "Page blocked")

    fun reason(code: Int): String = reasons[code] ?: "unknown"
    fun label(reason: String): String = labels[reason] ?: "Unable to load page"

    /** The top document's HTTP error class, or "" below 400 (sites usually draw their own error page). */
    fun httpLabel(status: Int): String = when {
        status == 404 || status == 410 -> "Page not found"
        status == 401 || status == 407 -> "Sign-in required"
        status == 403 -> "Access denied"
        status == 429 -> "Too many requests"
        status in 500..599 -> "Server error"
        status in 400..499 -> "Request error"
        else -> ""
    }

    private fun escape(text: String) = text.replace("&", "&amp;").replace("<", "&lt;").replace(">", "&gt;").replace("\"", "&quot;")

    /** A dark page (never mistaken for a white one) naming the reason; reload retries the failed address. */
    fun html(title: String, host: String, detail: String, retry: String): String =
        "<!doctype html><html><head><meta charset=\"utf-8\"><meta name=\"viewport\" content=\"width=device-width,initial-scale=1\">" +
        "<style>html,body{height:100%;margin:0}body{display:flex;align-items:center;justify-content:center;background:#1b1d22;" +
        "color:#e8eaed;font:18px system-ui,sans-serif}main{text-align:center;padding:24px;max-width:80%}" +
        "h1{font-size:30px;font-weight:600;margin:0 0 10px}p{margin:6px 0;color:#9aa0a6;word-break:break-all}" +
        "button{margin-top:26px;font:inherit;padding:12px 34px;border:0;border-radius:24px;background:#8ab4f8;color:#111}</style></head>" +
        "<body><main><h1>${escape(title)}</h1><p>${escape(host)}</p><p style=\"font-size:13px\">${escape(detail)}</p>" +
        "<button onclick=\"location.reload()\">${escape(retry)}</button></main></body></html>"

    fun page(title: String, host: String, detail: String, retry: String): String =
        "data:text/html;charset=utf-8;base64," + Base64.getEncoder().encodeToString(html(title, host, detail, retry).toByteArray(Charsets.UTF_8))
}
