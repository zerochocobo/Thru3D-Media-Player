package org.vrpassthroughplayer.plugin

import org.json.JSONObject

/** Keep fallback lazy: a verified browser representation never initializes the extractor. */
internal object WebVideoResolution {
    fun select(page: WebVideoPage, capture: () -> JSONObject?, extract: () -> JSONObject,
        accepts: (WebVideoTrack) -> Boolean, check: () -> Unit = {}, legacyFallback: () -> JSONObject? = { null }): Pair<JSONObject, WebVideoDescriptor> {
        val captured = try {
            capture()?.let { it to WebVideoFormats.select(page, it, accepts) }
        } catch (_: Exception) { null }
        check()
        if (captured != null) return captured
        val info = extract()
        check()
        val canonical = runCatching { WebVideoPage.parse(info.optString("webpage_url")) }.getOrNull()?.takeIf { it.site == page.site } ?: page
        return try { info to WebVideoFormats.select(canonical, info, accepts) } catch (error: Exception) {
            check()
            val fallback = legacyFallback() ?: throw error
            fallback to WebVideoFormats.select(page, fallback, accepts)
        }
    }
}
