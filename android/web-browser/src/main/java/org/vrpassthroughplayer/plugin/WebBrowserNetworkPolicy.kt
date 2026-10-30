package org.vrpassthroughplayer.plugin

import org.json.JSONObject
import java.net.URI
import java.util.Locale

/** Entry visibility/defaults only; the existing resolver and handoff routes are unchanged. */
internal class WebBrowserNetworkPolicy(saved: String, private val save: (String) -> Unit) {
    private var choices = runCatching { JSONObject(saved) }.getOrDefault(JSONObject())
    init { if (choices.length() > 1000) choices = JSONObject() }
    companion object {
        // Match the existing featured-site NATIVE_PLAYBACK badges, not all yt-dlp-supported
        // sites. The cross-catalog test checks names and featured URLs against Godot's list.
        internal val NATIVE_PLAYBACK_HOSTS = mapOf(
            "Bilibili" to setOf("bilibili.com", "b23.tv"),
            "YouTube" to setOf("youtube.com", "youtu.be"),
            "Weibo" to setOf("weibo.com", "weibo.cn"),
            "Tencent Video" to setOf("v.qq.com"),
            "Mango TV" to setOf("mgtv.com"),
            "Youku" to setOf("youku.com"),
            "Twitch" to setOf("twitch.tv"),
            "TikTok" to setOf("tiktok.com"),
            "Instagram Reels" to setOf("instagram.com"),
            "TED" to setOf("ted.com"),
            "Niconico" to setOf("nicovideo.jp", "nico.ms"),
        )
        private val nativeHosts = NATIVE_PLAYBACK_HOSTS.values.flatten().toSet()
        fun available(url: String): Boolean {
            val origin = origin(url) ?: return false
            val host = URI(origin).host.removeSuffix(".")
            return nativeHosts.none { host == it || host.endsWith(".$it") }
        }
        fun origin(value: String): String? = runCatching {
            val uri = URI(value)
            require(uri.scheme in setOf("http", "https") && uri.rawUserInfo == null && !uri.host.isNullOrEmpty())
            val port = uri.port.takeIf { it >= 0 && !(uri.scheme == "https" && it == 443 || uri.scheme == "http" && it == 80) }
            "${uri.scheme}://${uri.host.lowercase(Locale.ROOT)}${port?.let { ":$it" }.orEmpty()}"
        }.getOrNull()
        private fun key(origin: String) = java.security.MessageDigest.getInstance("SHA-256").digest(origin.toByteArray())
            .joinToString("") { "%02x".format(it) }
    }
    fun enabled(url: String): Boolean {
        if (!available(url)) return false
        val origin = origin(url) ?: return false; val key = key(origin)
        return if (choices.has(key)) choices.optBoolean(key) else true
    }
    /** Internal adapter policy is separate from the generic sniffing entry. */
    fun bilibiliEnabled(url: String): Boolean {
        val uri = runCatching { URI(url) }.getOrNull() ?: return false
        if (uri.scheme != "https" || uri.host != "www.bilibili.com" || uri.port != -1 || uri.rawUserInfo != null ||
            !Regex("/(?:video/(?:BV[A-Za-z0-9]+|av[0-9]+)|bangumi/play/(?:ep|ss)[1-9][0-9]{0,19})/?").matches(uri.path.orEmpty())) return false
        val origin = origin(url) ?: return false
        return choices.optBoolean(key(origin), true)
    }
    fun set(url: String, enabled: Boolean) {
        if (!available(url)) return
        val origin = origin(url) ?: return
        val next = JSONObject(choices.toString()); val key = key(origin)
        require(next.has(key) || next.length() < 1000)
        next.put(key, enabled); save(next.toString()); choices = next
    }
}
