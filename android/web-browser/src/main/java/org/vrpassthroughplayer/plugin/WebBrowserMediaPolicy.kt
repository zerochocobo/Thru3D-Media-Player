package org.vrpassthroughplayer.plugin

import java.net.URI
import java.util.Locale
import org.json.JSONObject

/** Website-owned EME playback. Keys and protected media never cross the native handoff. */
internal object WebBrowserMediaPolicy {
    fun selectedCandidate(candidates: List<JSONObject>, selection: String): JSONObject? =
        candidates.singleOrNull { selection.isNotEmpty() && selection.length <= 512 &&
            it.optString("capture_identity") == selection && !it.optBoolean("protected") &&
            (it.optBoolean("weibo_enabled") && it.optBoolean("weibo_ready") && WebBrowserWeibo.metadata(it, it.optString("frame")) != null ||
                it.optBoolean("bilibili_enabled") && it.optBoolean("bilibili_ready") && it.optJSONObject("bilibili")?.let { data ->
                    data.optString("page") == it.optString("frame") && Regex("[1-9][0-9]{0,19}").matches(data.optString("cid"))
                } == true || it.optBoolean("tencent_enabled") && it.optBoolean("tencent_ready") && WebBrowserTencent.metadata(it,it.optString("frame")) != null ||
                it.optBoolean("mango_enabled") && it.optBoolean("mango_ready") && WebBrowserMango.metadata(it,it.optString("frame")) != null ||
                it.optBoolean("niconico_enabled") && it.optBoolean("niconico_ready") && WebBrowserNiconico.metadata(it,it.optString("frame")) != null ||
                it.optBoolean("twitch_enabled") && it.optBoolean("twitch_ready") && WebBrowserTwitch.metadata(it,it.optString("frame")) != null ||
                it.optBoolean("tiktok_enabled") && it.optBoolean("tiktok_ready") && WebBrowserTikTok.metadata(it,it.optString("frame")) != null ||
                it.optBoolean("instagram_enabled") && it.optBoolean("instagram_ready") && WebBrowserInstagram.metadata(it,it.optString("frame")) != null ||
                it.optBoolean("ted_enabled") && it.optBoolean("ted_ready") && WebBrowserTed.metadata(it,it.optString("frame")) != null ||
                it.optBoolean("redbull_enabled") && it.optBoolean("redbull_ready") && WebBrowserRedBull.metadata(it,it.optString("frame")) != null ||
                it.optBoolean("streamable_enabled") && it.optBoolean("streamable_ready") && WebBrowserStreamable.metadata(it,it.optString("frame")) != null ||
                it.optBoolean("archive_enabled") && it.optBoolean("archive_ready") && WebBrowserArchive.metadata(it,it.optString("frame")) != null ||
                it.optBoolean("odysee_enabled") && it.optBoolean("odysee_ready") && WebBrowserOdysee.metadata(it,it.optString("frame")) != null ||
                it.optBoolean("dailymotion_enabled") && it.optBoolean("dailymotion_ready") && WebBrowserDailymotion.metadata(it,it.optString("dailymotion_owner")) != null ||
                it.optBoolean("youku_enabled") && it.optBoolean("youku_ready") && WebBrowserYouku.metadata(it,it.optString("frame")) != null ||
                it.optBoolean("iqiyi_enabled") && it.optBoolean("iqiyi_ready") && WebBrowserIqiyi.metadata(it,it.optString("frame")) != null ||
                it.optBoolean("douyin_enabled") && it.optBoolean("douyin_ready") && WebBrowserDouyin.metadata(it,it.optString("frame"),true) != null) }

    /** Prefer the adapter's current-part binding over a playing sidebar preview. */
    fun extractionCandidate(candidates: List<JSONObject>): JSONObject? = candidates.maxWithOrNull(
        compareBy<JSONObject> { !it.optBoolean("protected") &&
            (it.optBoolean("bilibili_enabled") && it.optJSONObject("bilibili") != null || it.optBoolean("douyin_enabled") && it.optJSONObject("douyin") != null ||
                it.optBoolean("tencent_enabled") && it.optJSONObject("tencent") != null || it.optBoolean("mango_enabled") && it.optJSONObject("mango") != null ||
                it.optBoolean("niconico_enabled") && it.optJSONObject("niconico") != null || it.optBoolean("twitch_enabled") && it.optJSONObject("twitch") != null || it.optBoolean("tiktok_enabled") && it.optJSONObject("tiktok") != null || it.optBoolean("instagram_enabled") && it.optJSONObject("instagram") != null || it.optBoolean("ted_enabled") && it.optJSONObject("ted") != null || it.optBoolean("redbull_enabled") && it.optJSONObject("redbull") != null || it.optBoolean("streamable_enabled") && it.optJSONObject("streamable") != null || it.optBoolean("archive_enabled") && it.optJSONObject("archive") != null || it.optBoolean("odysee_enabled") && it.optJSONObject("odysee") != null || it.optBoolean("dailymotion_enabled") && it.optJSONObject("dailymotion") != null || it.optBoolean("youku_enabled") && it.optJSONObject("youku") != null || it.optBoolean("iqiyi_enabled") && it.optJSONObject("iqiyi") != null) }
            .thenBy { it.optBoolean("fullscreen") }.thenBy { it.optBoolean("playing") }
            .thenBy { it.optLong("width") * it.optLong("height") })
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
