package org.vrpassthroughplayer.plugin

import java.net.URI

/** Public video identities only: profiles, searches, login redirects and access tokens are not history keys. */
internal object WebVideoInternationalPages {
    fun parse(uri: URI, query: Map<String, String>): WebVideoPage? {
        val host = uri.host.lowercase(java.util.Locale.ROOT)
        val path = uri.path.orEmpty()
        fun page(site: String, id: String, url: String): WebVideoPage {
            require(id.length in 1..512) { "Choose an individual video" }
            return WebVideoPage(site, id, url)
        }
        fun match(pattern: String) = Regex(pattern).matchEntire(path)
        if (host in setOf("tiktok.com", "www.tiktok.com", "m.tiktok.com", "vm.tiktok.com", "vt.tiktok.com")) {
            val video = match("/@([A-Za-z0-9_.-]+)/video/([0-9]{8,24})/?")
            if (video != null) return page("tiktok", video.groupValues[2], "https://www.tiktok.com/@${video.groupValues[1]}/video/${video.groupValues[2]}")
            val code = if (host in setOf("vm.tiktok.com", "vt.tiktok.com")) match("/([A-Za-z0-9_-]{4,64})/?")?.groupValues?.get(1)
                else match("/t/([A-Za-z0-9_-]{4,64})/?")?.groupValues?.get(1)
            require(code != null) { "Choose a TikTok video" }
            return page("tiktok", "share:$code", if (host.startsWith("v")) "https://$host/$code/" else "https://www.tiktok.com/t/$code/")
        }
        if (host in setOf("instagram.com", "www.instagram.com", "m.instagram.com")) {
            val m = match("/(p|reels?|tv)/([A-Za-z0-9_-]{5,64})/?") ?: error("Choose an Instagram video")
            val kind = if (m.groupValues[1] == "reels") "reel" else m.groupValues[1]
            return page("instagram", m.groupValues[2], "https://www.instagram.com/$kind/${m.groupValues[2]}/")
        }
        if (host in setOf("facebook.com", "www.facebook.com", "m.facebook.com", "web.facebook.com", "fb.watch")) {
            if (host == "fb.watch") {
                val code = match("/([A-Za-z0-9_-]{4,64})/?")?.groupValues?.get(1) ?: error("Choose a Facebook video")
                return page("facebook", "share:$code", "https://fb.watch/$code/")
            }
            val id = match("/(?:reel/|(?:[^/]+/)?videos/(?:[^/]+/)?)([0-9]{5,32})/?")?.groupValues?.get(1)
                ?: query["v"]?.takeIf { path.trimEnd('/') in setOf("/watch", "/video.php") && it.matches(Regex("[0-9]{5,32}")) }
                ?: error("Choose a Facebook video")
            return page("facebook", id, "https://www.facebook.com/watch/?v=$id")
        }
        if (host in setOf("x.com", "www.x.com", "twitter.com", "www.twitter.com", "mobile.twitter.com")) {
            val m = match("/(?:(?:i/web|[^/]+)/status|statuses)/([0-9]{5,24})(?:/video/([0-9]{1,2}))?/?") ?: error("Choose a post with video")
            val id = m.groupValues[1]; val index = m.groupValues[2]
            require(index.isEmpty() || index.toInt() in 1..99)
            return page("twitter", id + if (index.isEmpty()) "" else ":$index", "https://x.com/i/status/$id" + if (index.isEmpty()) "" else "/video/$index")
        }
        if (host in setOf("reddit.com", "www.reddit.com", "old.reddit.com", "new.reddit.com", "np.reddit.com", "m.reddit.com", "redd.it")) {
            val id = (if (host == "redd.it") match("/([A-Za-z0-9]{4,16})/?")
                else match("/(?:(?:r|user)/[A-Za-z0-9_-]+/)?comments/([A-Za-z0-9]{4,16})(?:/[^/]*)?/?"))?.groupValues?.get(1)
                ?: error("Choose a Reddit video post")
            return page("reddit", id, "https://www.reddit.com/comments/$id/")
        }
        if (host in setOf("streamable.com", "www.streamable.com")) {
            val id = match("/(?:e/)?([A-Za-z0-9]{3,32})/?")?.groupValues?.get(1) ?: error("Choose a Streamable video")
            return page("streamable", id, "https://streamable.com/$id")
        }
        if (host in setOf("ted.com", "www.ted.com", "embed.ted.com")) {
            val id = match("/talks/([a-z0-9_-]+)(?:/lang/[a-zA-Z-]+)?/?")?.groupValues?.get(1) ?: error("Choose a TED talk")
            return page("ted", id, "https://www.ted.com/talks/$id")
        }
        if (host in setOf("archive.org", "www.archive.org")) {
            require(match("/details/[A-Za-z0-9_.-]+(?:/[^/]+)?/?") != null && !path.contains("..")) { "Choose an archive video" }
            return page("archive", path.removePrefix("/details/").trimEnd('/'), "https://archive.org${uri.rawPath.trimEnd('/')}")
        }
        if (host in setOf("rumble.com", "www.rumble.com")) {
            val embed = match("/embed/(v[A-Za-z0-9]+)/?")?.groupValues?.get(1)
            if (embed != null) return page("rumble", embed, "https://rumble.com/embed/$embed/")
            val id = match("/(v(?!ideos)[A-Za-z0-9]+)(?:-[A-Za-z0-9_.-]+)?(?:\\.html)?")?.groupValues?.get(1) ?: error("Choose a Rumble video")
            return page("rumble", id, "https://rumble.com$path")
        }
        if (host in setOf("odysee.com", "www.odysee.com")) {
            require(match("/(?:@[A-Za-z0-9_.-]+(?::[a-fA-F0-9]+)?/)?[A-Za-z0-9_.-]+:[a-fA-F0-9]+/?") != null && !path.contains("..")) { "Choose an Odysee video" }
            return page("odysee", path.trim('/'), "https://odysee.com${path.trimEnd('/')}")
        }
        if (host in setOf("nicovideo.jp", "www.nicovideo.jp", "sp.nicovideo.jp", "nico.ms")) {
            val id = (if (host == "nico.ms") match("/((?:sm|so|nm)?[0-9]+)/?") else match("/watch/((?:sm|so|nm)?[0-9]+)/?"))?.groupValues?.get(1)
                ?: error("Choose a Niconico video")
            return page("niconico", id, "https://www.nicovideo.jp/watch/$id")
        }
        if (host in setOf("tv.naver.com", "m.tv.naver.com", "tvcast.naver.com")) {
            val id = match("/(?:v|embed)/([0-9]+)/?")?.groupValues?.get(1) ?: error("Choose a Naver TV video")
            return page("naver", id, "https://tv.naver.com/v/$id")
        }
        if (host in setOf("tv.kakao.com", "play-tv.kakao.com")) {
            val id = match("/(?:channel/[0-9]+|embed/player)/cliplink/([0-9]+)/?")?.groupValues?.get(1) ?: error("Choose a Kakao TV video")
            return page("kakao", id, "https://tv.kakao.com/embed/player/cliplink/$id")
        }
        return null
    }
}
