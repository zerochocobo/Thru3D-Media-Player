package org.vrpassthroughplayer.plugin

import org.json.JSONObject

/** Local QA uses the production validators; a bridge cannot change adapter or media. */
internal object FixtureMediaBinding {
    fun adapter(page: String): String? = when {
        WebBrowserMango.enabled(page) -> "mango"
        WebBrowserTwitch.enabled(page) -> "twitch"
        WebBrowserTed.enabled(page) -> "ted"
        else -> null
    }

    fun metadata(item: JSONObject, page: String, kind: String? = adapter(page)): JSONObject? {
        if (kind == null || kind != adapter(page)) return null
        return when (kind) {
            "mango" -> WebBrowserMango.metadata(item, page)
            "twitch" -> WebBrowserTwitch.metadata(item, page)
            "ted" -> WebBrowserTed.metadata(item, page)
            else -> null
        }
    }

    fun same(original: JSONObject, current: JSONObject, page: String, kind: String): Boolean =
        metadata(current, page, kind) != null &&
            listOf("id", "frame", "source", "ted_source", "network_epoch", "width", "height").all {
                current.opt(it) == original.opt(it)
            } && current.optJSONObject(kind)?.optString("revision") == original.optJSONObject(kind)?.optString("revision")

    /** Returning to the same MSE player can select a different ABR resolution.
     * Native capture remains strict; this identity is only used after Native has closed. */
    fun sameReturned(original: JSONObject, current: JSONObject, page: String, kind: String): Boolean {
        if(kind!="ted")return same(original,current,page,kind)
        val data=metadata(current,page,kind) ?: return false
        val saved=original.optJSONObject(kind) ?: return false
        return listOf("id","frame","source","ted_source","network_epoch","blob").all { current.opt(it)==original.opt(it) } &&
            listOf("id","page","talk_id","player_id","root","expected_duration").all { data.opt(it)==saved.opt(it) } &&
            kotlin.math.abs(current.optDouble("duration")-original.optDouble("duration"))<=.001
    }

    /** A seek may temporarily remove typed metadata, never the original DOM/source epoch.
     * This only keeps the return pending; capture and successful return still require same(). */
    fun waitingForSeek(original: JSONObject, current: JSONObject, page: String, kind: String): Boolean =
        kind in setOf("twitch", "ted") && adapter(page) == kind && original.optString("frame") == page &&
            !current.optBoolean("protected") && original.optBoolean("blob") == current.optBoolean("blob") &&
            listOf("id", "frame", "source", "network_epoch").all { current.opt(it) == original.opt(it) } &&
            (kind=="ted" || listOf("width","height").all { current.opt(it)==original.opt(it) }) &&
            current.optJSONObject(kind) == null && !current.optBoolean("${kind}_ready") &&
            (kind != "ted" || current.optString("ted_source") in setOf("", original.optString("ted_source")))
}
