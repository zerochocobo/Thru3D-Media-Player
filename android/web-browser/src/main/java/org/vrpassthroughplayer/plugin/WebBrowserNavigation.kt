package org.vrpassthroughplayer.plugin

import java.net.URI
import java.util.Locale

/** Ordinary site content must not consume the live sessions reserved for real login popups. */
internal object WebBrowserNavigation {
    private val contentHosts = setOf("bilibili.com", "www.bilibili.com", "m.bilibili.com",
        "space.bilibili.com", "t.bilibili.com", "search.bilibili.com", "account.bilibili.com")
    private val videoSites = listOf(
        setOf("iqiyi.com", "www.iqiyi.com", "m.iqiyi.com"),
        setOf("youku.com", "www.youku.com", "v.youku.com", "m.youku.com", "so.youku.com"),
        setOf("v.qq.com", "m.v.qq.com"),
        setOf("mgtv.com", "www.mgtv.com", "w.mgtv.com"),
        setOf("youtube.com", "www.youtube.com", "m.youtube.com"))

    private fun contentUri(value: String): URI? = runCatching {
        if (!WebBrowserAddress.navigable(value)) return null
        val uri = URI(value)
        if ((uri.host?.lowercase(Locale.ROOT) !in contentHosts && videoSites.none { uri.host?.lowercase(Locale.ROOT) in it }) ||
            uri.port !in setOf(-1, if (uri.scheme == "https") 443 else 80)) null else uri
    }.getOrNull()

    fun reusePage(page: String, trigger: String?, destination: String, newWindow: Boolean,
        userGesture: Boolean, directNavigation: Boolean, redirect: Boolean): Boolean {
        if (!newWindow || !userGesture || directNavigation || redirect) return false
        val source = contentUri(page) ?: return false
        val initiator = contentUri(trigger ?: return false) ?: return false
        val target = contentUri(destination) ?: return false
        val group = (videoSites + listOf(contentHosts)).firstOrNull { source.host.lowercase(Locale.ROOT) in it } ?: return false
        if (initiator.host.lowercase(Locale.ROOT) !in group || target.host.lowercase(Locale.ROOT) !in group) return false
        // Keep authorization callbacks and unrecognized endpoints on Gecko's popup path.
        if (WebBrowserAddress.recordable(destination) == null || !target.rawFragment.isNullOrEmpty()) return false
        val path = target.rawPath.orEmpty().ifEmpty { "/" }
        if (group !== contentHosts) {
            // These hosts serve only browsing/playback pages; their sign-in lives on separate
            // passport/account hosts. Card links change format often (Youku /video?vid=…),
            // so allow any same-site path except an explicit sign-in endpoint.
            return !Regex("(?i)(?:login|logout|passport|oauth|signin|signup|register)").containsMatchIn(path)
        }
        return when (target.host.lowercase(Locale.ROOT)) {
            "bilibili.com", "www.bilibili.com", "m.bilibili.com" -> path == "/" ||
                path == "/history" || path == "/history/" || path == "/account/history" ||
                listOf("/video/", "/bangumi/play/", "/bangumi/media/", "/list/", "/medialist/play/").any(path::startsWith)
            "space.bilibili.com" -> Regex("/[0-9]+(?:/.*)?").matches(path)
            "t.bilibili.com" -> path == "/" || Regex("/[0-9]+/?").matches(path)
            "search.bilibili.com" -> path in setOf("/", "/all", "/video", "/bangumi", "/pgc", "/upuser")
            "account.bilibili.com" -> path in setOf("/account/home", "/account/big")
            else -> false
        }
    }
}
