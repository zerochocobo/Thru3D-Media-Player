package org.vrpassthroughplayer.plugin

import java.net.URI
import java.net.URLDecoder
import org.json.JSONObject

/** The Beta route is independent of generic sniffing and the legacy extractor. */
object WebBrowserDouyin {
    private const val METADATA_LIMIT = 96 * 1024
    // User paused this feature on 2026-11-03 after the featured-entry regression.
    // Reopen only after the user updates their version and authorizes more research.
    private const val USER_BETA_AVAILABLE = false

    fun metadata(item: JSONObject, currentPage: String, enabled: Boolean): JSONObject? {
        if (!enabled || item.optBoolean("protected")) return null
        val data = item.optJSONObject("douyin") ?: return null
        val expected = pageId(currentPage) ?: return null
        val frame = data.optString("page")
        return data.takeIf { it.toString().length <= METADATA_LIMIT && frame == item.optString("frame") &&
            pageId(frame) == expected && it.optString("id") == expected }
    }

    fun metadataDiagnostics(item: JSONObject, currentPage: String, enabled: Boolean, accepted: Boolean): JSONObject {
        val data = item.optJSONObject("douyin")
        val expected = pageId(currentPage)
        val frame = data?.optString("page").orEmpty()
        val size = data?.toString()?.length ?: 0
        fun flag(value: Boolean) = if (value) 1 else 0
        return JSONObject().put("reported",flag(data != null)).put("js_ready",flag(item.optBoolean("douyin_ready")))
            .put("enabled",flag(enabled)).put("protected",flag(item.optBoolean("protected")))
            .put("chars",size).put("size_ok",flag(data != null && size <= METADATA_LIMIT))
            .put("exact_page",flag(data != null && frame == currentPage))
            .put("same_video_page",flag(expected != null && pageId(frame) == expected))
            .put("frame_ok",flag(data != null && frame == item.optString("frame")))
            .put("id_ok",flag(expected != null && data?.optString("id") == expected)).put("accepted",flag(accepted))
    }

    /** Temporarily unavailable in ordinary builds and diagnostic overrides alike. */
    fun enabled(value: String, captureEnabled: Boolean = true): Boolean = USER_BETA_AVAILABLE && captureEnabled && document(value)

    fun document(value: String): Boolean = runCatching {
        val u = URI(value)
        u.scheme == "https" && u.host == "www.douyin.com" && u.port == -1 && u.rawUserInfo == null
    }.getOrDefault(false)

    fun pageId(value: String): String? = runCatching {
        require(document(value))
        val u = URI(value)
        val path = Regex("/video/([1-9][0-9]{14,19})/?").matchEntire(u.path)?.groupValues?.get(1)
        val modal = u.rawQuery.orEmpty().split('&').map {
            URLDecoder.decode(it.substringBefore('='), "UTF-8") to URLDecoder.decode(it.substringAfter('=', ""), "UTF-8")
        }.filter { it.first == "modal_id" }.map { it.second }
        require(modal.size <= 1 && (path == null || modal.isEmpty() || modal.single() == path))
        (path ?: modal.singleOrNull()?.takeIf { u.path in setOf("/", "/recommend", "/discover", "/search/") })
            ?.takeIf { Regex("[1-9][0-9]{14,19}").matches(it) }
    }.getOrNull()

    fun sourceId(value: String): String? = runCatching {
        val u = URI(value)
        require(value.length in 1..8192 && u.scheme == "https" && !u.host.isNullOrEmpty() && u.rawUserInfo == null && u.fragment == null)
        val ids = u.rawQuery.orEmpty().split('&').map {
            URLDecoder.decode(it.substringBefore('='), "UTF-8") to URLDecoder.decode(it.substringAfter('=', ""), "UTF-8")
        }.filter { it.first == "__vid" }.map { it.second }
        ids.singleOrNull()?.takeIf { Regex("[1-9][0-9]{14,19}").matches(it) }
    }.getOrNull()

    fun matches(declared: String, observed: String, contentId: String = ""): Boolean = runCatching {
        fun uri(value: String) = URI(value).also {
            require(value.length in 1..8192 && it.scheme == "https" && !it.host.isNullOrEmpty() && it.rawUserInfo == null && it.fragment == null)
        }
        val a = uri(declared); val b = uri(observed)
        fun query(u: URI) = u.rawQuery.orEmpty().split('&').filter(String::isNotEmpty).map {
            URLDecoder.decode(it.substringBefore('='), "UTF-8") to URLDecoder.decode(it.substringAfter('=', ""), "UTF-8")
        }
        val original = query(a)
        val keys = original.map { it.first }.toSet()
        val ids = query(b).filter { it.first == "__vid" }
        val bound = Regex("[1-9][0-9]{14,19}").matches(contentId) && ids.size == 1 && ids.single().second == contentId
        fun objectPath(uri: URI) = Regex("/(?:[a-fA-F0-9]{32}|[a-fA-F0-9]{64})/[a-fA-F0-9]{8,16}(/video/tos/cn/tos-cn-[a-zA-Z0-9-]{1,96}/[A-Za-z0-9_-]{8,240}(?:/[A-Za-z0-9_-]{8,240})?/?)")
            .matchEntire(uri.rawPath)?.groupValues?.get(1)
        val assetBound = Regex("[1-9][0-9]{14,19}").matches(contentId) && (ids.isEmpty() || bound) &&
            objectPath(a) != null && objectPath(a) == objectPath(b)
        val ignored = if (assetBound) setOf("cquery", "l", "dy_q", "btag") else if (bound) setOf("cquery", "l") else emptySet()
        fun stable(list: List<Pair<String, String>>) = list.filter { it.first !in ignored }
        val order = compareBy<Pair<String, String>> { it.first }.thenBy { it.second }
        // CDN aliases follow the trusted document when object/content identity
        // and the remaining query agree. Replay the observed request unchanged.
        (a.rawAuthority == b.rawAuthority || assetBound || bound) && (a.rawPath == b.rawPath || assetBound) && stable(original).sortedWith(order) == stable(query(b).filter {
            val key = it.first
            key in keys || key !in setOf("temp", "__vid", "testst")
        }).sortedWith(order)
    }.getOrDefault(false)
}
