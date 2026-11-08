package org.vrpassthroughplayer.plugin

import org.json.JSONArray
import org.json.JSONObject
import org.junit.Assert.*
import org.junit.Test

class WebBrowserTikTokTest {
    private val page = "https://www.tiktok.com/@test/video/6742501081818877190"
    private val source = "https://related-file.test/current?exact=selector"
    private fun media() = JSONObject().put("frame", page).put("source", "").put("blob", true)
        .put("tiktok_source", "blob:https://www.tiktok.com/owned").put("width", 540).put("height", 960)
        .put("duration", 27.533333).put("capture_identity", "selected").put("tiktok_enabled", true).put("tiktok_ready", true)
        .put("tiktok", JSONObject().put("id", "6742501081818877190").put("page", page).put("source", source)
            .put("revision", "ab12").put("width", 540).put("height", 960).put("duration", 27.533333).put("expected_duration", 27))
        .put("network", JSONArray().put(JSONObject().put("kind", "file").put("url", source).put("headers", JSONObject())))

    @Test fun onlyTheExplicitCurrentFileAndSelectionAreAccepted() {
        val item = media().put("playing", false)
        assertNotNull(WebBrowserTikTok.metadata(item, page))
        assertSame(item, WebBrowserMediaPolicy.selectedCandidate(listOf(item), "selected"))
        assertNull(WebBrowserMediaPolicy.selectedCandidate(listOf(item, media()), "selected"))
        assertNull(WebBrowserMediaPolicy.selectedCandidate(listOf(item), "other"))
        assertNull(WebBrowserMediaPolicy.selectedCandidate(listOf(item.put("tiktok_ready", false)), "selected"))
    }
    @Test fun wrongOwnerSourceProtectionAndDurationFailClosed() {
        for (change in listOf<(JSONObject) -> Unit>(
            { it.put("protected", true) }, { it.put("tiktok_source", "blob:https://other.test/file") },
            { it.put("network", JSONArray()) }, { it.put("frame", page + "?other") },
            { it.put("duration", 28.1) }, { it.put("width", 320) },
            { it.getJSONObject("tiktok").put("id", "6742501081818877191") },
            { it.getJSONObject("tiktok").put("expected_duration", 27.5) },
            { it.getJSONObject("tiktok").put("source", source + "&different=1") }
        )) { val item = media(); change(item); assertNull(WebBrowserTikTok.metadata(item, page)) }
    }
    @Test fun onlyMainSiteDetailPagesHaveAPlayableIdentity() {
        assertEquals("6742501081818877190", WebBrowserTikTok.page(page + "?from=page"))
        assertTrue(WebBrowserTikTok.document("https://www.tiktok.com/foryou"))
        for (bad in listOf("http://www.tiktok.com/@test/video/6742501081818877190", page + "#different",
            page.replace("www.tiktok.com", "www.tiktok.com.evil"), page.replace("/video/", "/photo/"),
            "https://www.tiktok.com/foryou", page.replace("/video/", "/video%2F"))) assertNull(WebBrowserTikTok.page(bad))
    }
}
