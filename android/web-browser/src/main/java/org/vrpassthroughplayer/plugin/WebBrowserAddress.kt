package org.vrpassthroughplayer.plugin

import java.net.URI
import java.net.URLDecoder

/** Navigation policy for the user-facing browser, separate from supported video extractors. */
internal object WebBrowserAddress {
    fun normalize(input: String): String? {
        val text = input.trim()
        if (text.isEmpty() || text.length > 4096 || text.any { it.isISOControl() }) return null
        val value = if (text.contains("://")) text else "https://$text"
        return runCatching {
            val uri = URI(value)
            if (uri.scheme.lowercase() !in setOf("http", "https") || uri.host.isNullOrBlank() ||
                uri.rawUserInfo != null || uri.port < -1 || uri.port > 65535) return null
            uri.toASCIIString().takeIf { it.length <= 4096 }
        }.getOrNull()
    }

    fun navigable(value: String): Boolean = value == "about:blank" || normalize(value) == value

    /** OAuth return values and URL credentials are never written into bookmarks/history. */
    fun recordable(value: String): String? {
        val clean = normalize(value) ?: return null
        val uri = URI(clean)
        val sensitive = setOf("code", "state", "token", "access_token", "id_token", "refresh_token", "password",
            "passwd", "session", "sessionid", "authorization", "credential", "ticket", "nonce", "auth")
        val keys = uri.rawQuery.orEmpty().split('&').map {
            runCatching { URLDecoder.decode(it.substringBefore('='), "UTF-8").lowercase() }.getOrDefault("")
        }
        if (keys.any { it in sensitive }) return null
        return clean.substringBefore('#')
    }
}
