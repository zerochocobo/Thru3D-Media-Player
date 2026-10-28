package org.vrpassthroughplayer.plugin

import java.net.URI
import java.util.Locale

/** Website-owned EME playback. Keys and protected media never cross the native handoff. */
internal object WebBrowserMediaPolicy {
    private val sites = listOf(
        listOf("netflix.com"), listOf("primevideo.com", "amazon.com"), listOf("disneyplus.com"), listOf("max.com", "hbomax.com"),
        listOf("hulu.com"), listOf("paramountplus.com"), listOf("apple.com"), listOf("plex.tv"),
        listOf("tubitv.com"), listOf("spotify.com"), listOf("youtube.com"), listOf("bilibili.com"),
        listOf("iqiyi.com"), listOf("mgtv.com"), listOf("v.qq.com"), listOf("youku.com"),
        listOf("twitch.tv"), listOf("redbull.com", "redbull.tv"), listOf("imax.com")
    )
    private fun host(url: String): String? = runCatching {
        val uri = URI(url)
        if (uri.scheme != "https" || uri.rawUserInfo != null || uri.port !in setOf(-1, 443)) null else uri.host?.lowercase(Locale.ROOT)
    }.getOrNull()
    fun permitsKeys(page: String, requester: String, thirdParty: String?): Boolean {
        val top = host(page) ?: return false
        val group = sites.firstOrNull { it.any { domain -> top == domain || top.endsWith(".$domain") } } ?: return false
        return listOfNotNull(requester, thirdParty?.takeIf(String::isNotEmpty)).all { url ->
            val target = host(url) ?: return@all false
            group.any { target == it || target.endsWith(".$it") }
        }
    }

    /** Earlier app builds denied Netflix automatically; Gecko persists that decision. */
    fun resetsLegacyDenial(page: String, requester: String, thirdParty: String?): Boolean {
        val top = host(page) ?: return false
        return (top == "netflix.com" || top.endsWith(".netflix.com")) && permitsKeys(page, requester, thirdParty)
    }
}
