package org.vrpassthroughplayer.plugin

import java.net.URI
import java.util.Locale

/** Explicitly paired first-party login domains. No registrable-domain guessing. */
object WebVideoSessionScope {
    val groups: List<List<String>> = listOf(
        listOf("youtube.com"), listOf("bilibili.com"),
        listOf("douyin.com", "iesdouyin.com"), listOf("weibo.com", "weibo.cn"),
        listOf("iqiyi.com"), listOf("mgtv.com"), listOf("qq.com"), listOf("youku.com"),
        listOf("vimeo.com"), listOf("dailymotion.com", "dai.ly"), listOf("twitch.tv"),
        listOf("tubitv.com"), listOf("redbull.com", "redbull.tv"), listOf("astalavr.com"),
        listOf("tiktok.com"), listOf("instagram.com"), listOf("facebook.com", "fb.watch"),
        listOf("twitter.com", "x.com"), listOf("reddit.com", "redd.it"), listOf("streamable.com"),
        listOf("ted.com"), listOf("archive.org"), listOf("rumble.com"), listOf("odysee.com"),
        listOf("nicovideo.jp", "nico.ms"), listOf("naver.com"), listOf("kakao.com")
    )
    fun domains(url: String): List<String> {
        val uri = runCatching { URI(url) }.getOrNull() ?: return emptyList()
        if (uri.scheme !in setOf("http", "https") || uri.rawUserInfo != null) return emptyList()
        val host = uri.host?.lowercase(Locale.ROOT) ?: return emptyList()
        return groups.firstOrNull { group -> group.any { host == it || host.endsWith(".$it") } } ?: emptyList()
    }
}
