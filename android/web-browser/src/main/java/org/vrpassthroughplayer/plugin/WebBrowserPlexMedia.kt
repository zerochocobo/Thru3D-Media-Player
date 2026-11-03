package org.vrpassthroughplayer.plugin

import java.net.URI
import java.net.URLDecoder
import java.util.Locale

/** Plex library identity and exact-request credentials; no storage or account discovery. */
object WebBrowserPlexMedia {
    class Source(val identity: String, val original: URI?, val metadata: URI?, val item: String,
        val mediaIndex: Int, val partIndex: Int, val offset: Double, val headers: Map<String, String>, val base: String)

    fun source(value: String, page: String, headers: Map<String, String> = emptyMap()): Source? = runCatching {
        require(value.length in 1..16384 && page.length in 1..8192)
        val uri = URI(value); val frame = URI(page)
        fun port(u: URI) = if (u.port >= 0) u.port else if (u.scheme == "https") 443 else 80
        require(uri.scheme in setOf("http", "https") && uri.rawUserInfo == null && frame.rawUserInfo == null && uri.fragment == null &&
            !uri.host.isNullOrBlank() && uri.scheme == frame.scheme && uri.host.equals(frame.host, true) && port(uri) == port(frame))
        require(uri.rawPath == uri.path && uri.path.split('/').none { it == "." || it == ".." })
        val direct = Regex("(?i)^(.*)/library/parts/([0-9]{1,20})/([0-9]{1,20})/file(?:\\.[a-z0-9]{1,8})?$").matchEntire(uri.path)
        val transcode = Regex("(?i)^(.*)/video/:/transcode/universal/start\\.(?:mpd|m3u8|mkv)$").matchEntire(uri.path)
        require(direct != null || transcode != null)
        val args = LinkedHashMap<String, String>()
        for (arg in uri.rawQuery.orEmpty().split('&').filter(String::isNotEmpty)) {
            val key = URLDecoder.decode(arg.substringBefore('='), "UTF-8").lowercase(Locale.ROOT)
            require(!args.containsKey(key)); args[key] = URLDecoder.decode(arg.substringAfter('=', ""), "UTF-8")
        }
        val sent = headers.entries.associate { it.key.lowercase(Locale.ROOT) to it.value }
        val queryToken = args["x-plex-token"]; val headerToken = sent["x-plex-token"]
        require(queryToken == null || headerToken == null || queryToken == headerToken)
        val token = queryToken ?: headerToken ?: return null
        require(token.length in 1..4096 && token.all { it in '!'..'~' })
        val auth = linkedMapOf("X-Plex-Token" to token)
        (args["x-plex-client-identifier"] ?: sent["x-plex-client-identifier"])?.takeIf {
            it.length in 1..256 && it.all { c -> c in '!'..'~' }
        }?.let { auth["X-Plex-Client-Identifier"] = it }
        val prefix = (direct ?: transcode)!!.groupValues[1]
        val base = "${uri.scheme}://${uri.rawAuthority}$prefix"
        if (direct != null) return Source("plex-part:${direct.groupValues[2]}:${direct.groupValues[3]}",
            URI(base + uri.path.removePrefix(prefix)), null, direct.groupValues[2], 0, 0, 0.0, auth, base)
        val path = args["path"].orEmpty()
        require(Regex("/library/metadata/[0-9]{1,20}").matches(path))
        fun index(name: String): Int {
            val raw = args[name] ?: "-1"
            require(Regex("-1|[0-9]{1,3}").matches(raw))
            return raw.toInt().also { require(it in -1..127) }
        }
        val media = index("mediaindex"); val part = index("partindex")
        val offset = if (args["copyts"] == "0") (args["offset"] ?: "0").toDouble() else 0.0
        require(offset.isFinite() && offset in 0.0..1e7)
        val item = path.substringAfterLast('/')
        Source("plex:$item:$media:$part", null, URI(base + path), item, media, part, offset, auth, base)
    }.getOrNull()
}
