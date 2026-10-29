package org.vrpassthroughplayer.plugin

import java.net.URI
import java.net.URLDecoder
import java.net.URLEncoder
import java.util.Locale

/** Emby/Jellyfin's authenticated video endpoints, scoped to the page's own server.
 * Keep tokens in the private media snapshot; the public snapshot only has a boolean. */
object WebBrowserServerMedia {
    fun original(source: String, page: String): String? = runCatching {
        require(source.length in 1..16384 && page.length in 1..8192)
        val uri = URI(source); val frame = URI(page)
        fun port(value: URI) = if (value.port >= 0) value.port else if (value.scheme == "https") 443 else 80
        require(uri.scheme in setOf("http", "https") && uri.rawUserInfo == null && uri.fragment == null)
        require(frame.rawUserInfo == null && uri.scheme == frame.scheme && !uri.host.isNullOrBlank() &&
            uri.host.equals(frame.host, true) && port(uri) == port(frame))
        // Emby 4.8+ web direct play requests /videos/{id}/original.{container}; older Emby and
        // Jellyfin use stream[.container]; transcodes use master/main.m3u8.
        val match = Regex("(?i)^(.*/videos/)([a-z0-9-]{1,64})/(?:(original(?:\\.[a-z0-9]{1,8})?)|stream(?:\\.[a-z0-9]+)?|(?:master|main)\\.m3u8)$").matchEntire(uri.rawPath) ?: return null
        val args = uri.rawQuery.orEmpty().split('&').filter(String::isNotEmpty).associate {
            URLDecoder.decode(it.substringBefore('='), "UTF-8").lowercase(Locale.ROOT) to URLDecoder.decode(it.substringAfter('=', ""), "UTF-8")
        }
        val tokenName = if (args.containsKey("api_key")) "api_key" else "ApiKey"
        val token = args[tokenName.lowercase(Locale.ROOT)] ?: return null
        val media = args["mediasourceid"] ?: return null
        require(token.length in 1..4096 && media.length in 1..256 && (token + media).none { it < ' ' || it == '\u007f' })
        require(args["livestreamid"].isNullOrEmpty()) // A live stream is not an original seekable file.
        val query = listOf("Static" to "true", "MediaSourceId" to media, tokenName to token).joinToString("&") {
            it.first + "=" + URLEncoder.encode(it.second, "UTF-8")
        }
        val file = match.groupValues[3].ifEmpty { "stream" }
        "${uri.scheme}://${uri.rawAuthority}${match.groupValues[1]}${match.groupValues[2]}/$file?$query"
    }.getOrNull()
}
